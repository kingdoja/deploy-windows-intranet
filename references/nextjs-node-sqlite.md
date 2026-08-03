# Next.js, Node.js, and SQLite Adaptation

Use this reference when a project is Next.js, targets an edge runtime, or stores data in Cloudflare D1/KV but must run as a Windows intranet service.

## Runtime decision

- Prefer standard Next.js on Node.js for a single-host intranet deployment.
- Inventory edge-only imports and bindings such as `cloudflare:workers`, D1, KV, R2, and platform authentication before changing the build command.
- Preserve the original cloud deployment path only when the user wants it; make the Windows runtime explicit rather than silently changing both targets.

## Node production contract

- Build with `next build` and start with a Node entry that runs migrations, then starts Next with the configured `HOST` and `PORT`.
- Use `next start` for a normal build. If `output: "standalone"` is enabled, start `.next/standalone/server.js` and copy the required `public` and static assets; do not mix the two modes.
- Set `staticSite.enabled` to `false` and route `/*` to the API service for SSR/full-stack Next.js.
- Include `.next`, `public`, the production entry, migrations, `package.json`, and the lockfile in each release. Install production dependencies inside the immutable release.
- Remove remote font downloads from production builds or vendor the fonts locally so an external outage cannot break a release.

## Persistent storage

- Put the SQLite database and uploaded media below a persistent data root such as `{ProductionRoot}\data`, never inside `.next`, a release, or the source checkout.
- Enable WAL, a busy timeout, foreign keys, and an appropriate synchronous mode. Keep migrations idempotent and compatible with the active and previous application versions.
- Replace D1/KV calls through a narrow adapter rather than scattering Node filesystem and SQLite logic through route handlers.
- Inspect remote row counts and object keys before migration. Export D1 and KV data, import into an isolated database, compare counts, and only then install the first local release.

## HTTP and authentication

- Plain HTTP intranet cookies cannot use `Secure`; make that flag environment-controlled. Enable it when the shared gateway terminates reviewed HTTPS.
- Keep admin secrets in machine-scoped variables referenced as `%VARIABLE_NAME%`. Define them before installation. A later machine-variable rotation may require a host reboot because Windows services can inherit a cached service-control-manager environment; test the new credential before declaring rotation complete.
- Do not weaken a password merely for deployment convenience. If the user explicitly chooses a weak intranet password, report the risk.

## Readiness, backup, and restore

- Make `/api/health` exercise SQLite and the media root, not just return process liveness.
- Use SQLite's online backup API or another application-aware backup command, then copy media and a manifest. A raw live database file copy is not sufficient.
- Run the scheduled task once under its real service account and require result code 0.
- Restore the newest backup into an isolated data root, start the application on a temporary loopback port, and verify health plus representative row/object counts.
