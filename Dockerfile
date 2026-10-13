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
    echo "opencode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/opencode && \
    chmod 0440 /etc/sudoers.d/opencode
COPY opencode.json /home/opencode/.config/opencode/opencode.json
RUN chown -R opencode:opencode /home/opencode

# Node.js LTS + Wrangler (global npm installs land in /usr/local -> all users).
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g wrangler && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/* /root/.npm

# Bun, system-wide via BUN_INSTALL (installer default ~/.bun would strand it in /root).
RUN curl -fsSL https://bun.sh/install | bash && \
    ln -s /opt/bun/bin/bun /usr/local/bin/bun

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
# glab asset URLs come from the release API itself, so a rename upstream can't
# silently 404 the build the way a hardcoded URL pattern would.
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  BINARCH=amd64 ;; \
      aarch64) BINARCH=arm64 ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    GLAB_JSON="$(curl -fsSL 'https://gitlab.com/api/v4/projects/34675721/releases/permalink/latest')"; \
    GLAB_TAG="$(echo "$GLAB_JSON" | jq -r '.tag_name')"; \
    GLAB_URL="$(echo "$GLAB_JSON" | jq -r --arg a "linux_${BINARCH}.tar.gz" '[.assets.links[] | select(.name | endswith($a)) | .direct_asset_url // .url][0]')"; \
    if [ -z "$GLAB_URL" ] || [ "$GLAB_URL" = "null" ]; then echo "no glab tarball found for linux_${BINARCH} in ${GLAB_TAG}" >&2; exit 1; fi; \
    echo "Installing glab ${GLAB_TAG}"; \
    curl -fsSL -o /tmp/glab.tgz "$GLAB_URL"; \
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
RUN curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path && \
    install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode && \
    install -m 0755 /root/.opencode/bin/opencode2 /usr/local/bin/opencode2 && \
    rm -rf /root/.opencode

RUN chown -R opencode:opencode /home/opencode

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
