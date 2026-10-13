FROM ubuntu:26.04

# All toolchains below are installed to system-wide locations (/usr/local, /opt)
# because the container runs as the non-root `opencode` user, which cannot read /root.
# (Installing CLIs into /root is the classic "build passes, container fails" trap:
# a root-time verification step would never catch it.)
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    BUN_INSTALL=/opt/bun
ENV PATH="/usr/local/cargo/bin:/opt/bun/bin:/usr/local/go/bin:${PATH}"

# Base packages + distro Python in one layer.
# Ubuntu 26.04 ships Python 3.13+, so the deadsnakes PPA is no longer needed;
# python-is-python3 provides the `python` alias the canonical way.
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    ca-certificates \
    curl \
    wget \
    git \
    build-essential \
    unzip \
    zip \
    jq \
    htop \
    tmux \
    openssh-client \
    rclone \
    magic-wormhole \
    python3 \
    python3-venv \
    python3-dev \
    python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# Non-root user first, so everything below can be owned correctly from the start.
# Config lives in the global config dir, NOT the workspace: docker-compose mounts
# ./workspace over /home/opencode/workspace, which would shadow any file baked in there.
RUN useradd -m -s /bin/bash opencode && \
    mkdir -p /home/opencode/workspace /home/opencode/.config/opencode && \
    chown opencode:opencode /home/opencode/workspace /home/opencode/.config /home/opencode/.config/opencode && \
    echo "opencode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/opencode && \
    chmod 0440 /etc/sudoers.d/opencode

# Node.js LTS + Wrangler (global npm installs land in /usr/local -> all users).
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g --no-audit --no-fund wrangler && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/* /root/.npm

# Bun, system-wide via BUN_INSTALL (installer default ~/.bun would strand it in
# /root). /opt/bun/bin is already on PATH via ENV, so no symlink needed.
RUN curl -fsSL https://bun.sh/install | bash

# uv + uvx, system-wide via UV_INSTALL_DIR.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Go, always latest stable, multi-arch (go.dev/VERSION?m=text yields e.g. "go1.25.3").
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  GOARCH=amd64 ;; \
      aarch64) GOARCH=arm64 ;; \
      riscv64) GOARCH=riscv64 ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n 1)"; \
    echo "Installing ${GO_VERSION} for linux/${GOARCH}"; \
    curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/${GO_VERSION}.linux-${GOARCH}.tar.gz"; \
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz

# Rust, system-wide via CARGO_HOME/RUSTUP_HOME; minimal profile keeps it lean.
# Note: `rustup update` later needs root (toolchain dir is root-owned by design).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable && \
    chmod -R a+rX /usr/local/cargo /usr/local/rustup

# glab (GitLab CLI) + gh (GitHub CLI), always latest release, multi-arch.
# The glab tag comes from the API redirect URL, not the response body:
# release notes have intermittently shipped bytes that break JSON parsers,
# and the tag is all we need -- the asset URL pattern below is verified
# against direct_asset_url, and curl -f fails the build loudly if it drifts.
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  BINARCH=amd64 ;; \
      aarch64) BINARCH=arm64 ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    GLAB_TAG="$(curl -fsSL -o /dev/null -w '%{url_effective}' 'https://gitlab.com/api/v4/projects/34675721/releases/permalink/latest' | grep -o '[^/]*$')"; \
    case "$GLAB_TAG" in v*) ;; *) echo "bad glab tag from redirect: ${GLAB_TAG}" >&2; exit 1 ;; esac; \
    GLAB_VER="${GLAB_TAG#v}"; \
    echo "Installing glab ${GLAB_TAG}"; \
    curl -fsSL -o /tmp/glab.tgz "https://gitlab.com/gitlab-org/cli/-/releases/${GLAB_TAG}/downloads/glab_${GLAB_VER}_linux_${BINARCH}.tar.gz"; \
    rm -rf /tmp/glab-extract && mkdir -p /tmp/glab-extract && tar -xzf /tmp/glab.tgz -C /tmp/glab-extract; \
    install -m 0755 "$(find /tmp/glab-extract -name glab -type f | head -n 1)" /usr/local/bin/glab; \
    rm -rf /tmp/glab.tgz /tmp/glab-extract; \
    GH_TAG="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name')"; \
    GH_VER="${GH_TAG#v}"; \
    echo "Installing gh ${GH_TAG}"; \
    curl -fsSL -o /tmp/gh.tgz "https://github.com/cli/cli/releases/download/${GH_TAG}/gh_${GH_VER}_linux_${BINARCH}.tar.gz"; \
    rm -rf /tmp/gh-extract && mkdir -p /tmp/gh-extract && tar -xzf /tmp/gh.tgz -C /tmp/gh-extract; \
    install -m 0755 "/tmp/gh-extract/gh_${GH_VER}_linux_${BINARCH}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz /tmp/gh-extract

# OpenCode via the v2 installer. INSTALL_DIR is hardcoded to $HOME/.opencode/bin,
# so promote the binaries to /usr/local/bin (the opencode2 shim is relocatable:
# it execs `$(dirname $0)/opencode`, so it survives the move).
# OpenCode CLI, straight from the npm registry. The official installer resolves
# its version through opencode.ai, which persistently 503s builder egress --
# the registry holds the same packages with none of the flakiness.
# (Baseline target mirrors upstream: pre-AVX2 x86_64 only; ARM needs none.)
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  OCARCH=x64 ;; \
      aarch64) OCARCH=arm64 ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    OCTARGET="linux-${OCARCH}"; \
    if [ "$OCARCH" = "x64" ]; then grep -qwi avx2 /proc/cpuinfo 2>/dev/null || OCTARGET="${OCTARGET}-baseline"; fi; \
    OC_VER=""; OCSCOPE=""; \
    for s in opencode opencode-ai; do \
      OC_META="$(curl -fsSL "https://registry.npmjs.org/@${s}%2fcli-${OCTARGET}/latest" || true)"; \
      OC_VER="$(echo "$OC_META" | jq -r '.version // empty' 2>/dev/null || true)"; \
      OC_URL="$(echo "$OC_META" | jq -r '.dist.tarball // empty' 2>/dev/null || true)"; \
      if [ -n "$OC_VER" ] && [ -n "$OC_URL" ]; then OCSCOPE="$s"; break; fi; \
      OC_VER=""; OC_URL=""; \
    done; \
    [ -n "${OC_VER:-}" ] || { echo "could not resolve opencode version for ${OCTARGET}" >&2; exit 1; }; \
    echo "Installing opencode ${OC_VER} (${OCTARGET}, @${OCSCOPE})"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o /tmp/opencode.tgz "$OC_URL"; \
    rm -rf /tmp/oc-extract && mkdir -p /tmp/oc-extract && tar -xzf /tmp/opencode.tgz -C /tmp/oc-extract; \
    install -m 0755 /tmp/oc-extract/package/bin/opencode /usr/local/bin/opencode; \
    printf '#!/bin/sh\nexec "$(dirname "$0")/opencode" "$@"\n' > /usr/local/bin/opencode2; \
    chmod 0755 /usr/local/bin/opencode2; \
    rm -rf /tmp/opencode.tgz /tmp/oc-extract

# Config copied late so edits don't invalidate the heavy toolchain layers above.
# --chown sets ownership with no extra layer and no full-tree chown walk.
COPY --chown=opencode:opencode opencode.json /home/opencode/.config/opencode/opencode.json

USER opencode
WORKDIR /home/opencode/workspace

# Verification runs as the runtime user -- this is the regression guard.
# If a tool is ever installed somewhere `opencode` can't reach again,
# the build fails here instead of shipping a broken image.
RUN set -eu; \
    echo "=== python ===" && python --version && python3 --version; \
    echo "=== node ===" && node --version; \
    echo "=== npm ===" && npm --version; \
    echo "=== wrangler ===" && wrangler --version; \
    echo "=== bun ===" && bun --version; \
    echo "=== uv ===" && uv --version && uvx --version; \
    echo "=== go ===" && go version; \
    echo "=== rust ===" && rustc --version && cargo --version; \
    echo "=== opencode ===" && opencode --version; \
    echo "=== glab ===" && glab --version; \
    echo "=== gh ===" && gh --version; \
    echo "=== rclone ===" && rclone version | head -n 1

ENTRYPOINT ["opencode"]
CMD ["web", "--port", "4096", "--hostname", "0.0.0.0"]
