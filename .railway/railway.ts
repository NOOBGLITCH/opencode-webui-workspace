import { defineRailway, preserve, project, service, volume } from "railway/iac";

// Persistent workspace for the OpenCode WebUI service.
// Mount path must match WORKDIR in the Dockerfile (/home/opencode/workspace).
// 5 GB is a starting size for projects + session data; adjust or live-resize later.
const workspace = volume("workspace", {
  sizeMB: 5120,
});

const opencode = service("opencode", {
  // No `source`: keep whatever repo/image is already connected in the dashboard.
  // No `start`: the image ENTRYPOINT (opencode web --port 4096) is the command.
  // No healthcheck: with OPENCODE_SERVER_PASSWORD set, `/` requires basic auth,
  // so a probe would fail and Railway would restart-loop the service.
  env: {
    OPENCODE_SERVER_USERNAME: "opencode",
    // Secret stays out of source; set it once in the dashboard (or `railway variable set`).
    OPENCODE_SERVER_PASSWORD: preserve(),
    // Volumes mount as root. The image runs as the non-root `opencode` user,
    // so run as UID 0 or every workspace write fails with permission denied.
    // https://docs.railway.com/volumes#permissions
    RAILWAY_RUN_UID: "0",
  },
  volumeMounts: {
    "/home/opencode/workspace": workspace,
  },
});

export default defineRailway(() => {
  return project("opencode-webui-workspace", {
    resources: [opencode, workspace],
  });
});
