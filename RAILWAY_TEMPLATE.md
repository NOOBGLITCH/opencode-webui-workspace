# Deploy and Host OpenCode WebUI Workspace on Railway

Self-hosted OpenCode coding environment with a full dev toolchain, served as a
password-protected web UI with projects persisted on an attached volume.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/opencode-webui-wor-1)

No image to build, no VPS to manage. The template provisions the service, the
workspace volume, and prompts for the server password on deploy.

## About Hosting

The service builds this repo's `Dockerfile` (Ubuntu 26.04: Python 3.14,
Node 24 LTS, Bun, Go, Rust, uv, glab, gh, Wrangler) and runs
`opencode serve` on port 4096. Workspace repos, session data, and projects
persist on the attached volume mounted at `/home/opencode/workspace`.
Railway auto-detects the `Dockerfile`; the service domain targets port 4096.

## Why Deploy

- Code with an AI agent from any browser, nothing installed locally.
- Full toolchain on day one: Python, Node, Bun, Go, Rust, GitHub/GitLab CLIs.
- Password-protected, and your workspace survives restarts and redeploys.

## Common Use Cases

- Remote development sessions from a laptop, tablet, or phone browser.
- A persistent sandbox for agent-driven coding tasks.
- Trying OpenCode without touching your local machine.

## Dependencies for OpenCode WebUI Workspace

| Key | Description |
| --- | ----------- |
| `OPENCODE_SERVER_USERNAME` | Server login username (default `opencode`) |
| `OPENCODE_SERVER_PASSWORD` | Server login password (required) |
| `RAILWAY_RUN_UID` | Must stay `0`: volumes mount as root, the image runs non-root |

### Deployment Dependencies

- Attached Railway volume mounted at `/home/opencode/workspace` (projects, sessions, agent state).
- Outbound HTTPS to package registries and your model provider; no inbound ports besides the web UI.
- After deploy: open the service domain and log in with your username and password.

Source: https://github.com/NOOBGLITCH/opencode-webui-workspace
