# Windows Intranet Deployment Contract

- [Supported Architecture](#supported-architecture)
- [Required Application Contracts](#required-application-contracts)
- [Configuration](#configuration)
- [Command Objects](#command-objects)
- [Service Objects](#service-objects)
- [Schema v1 Migration](#schema-v1-migration)
- [Configuration Reconciliation](#configuration-reconciliation)
- [Project-Specific Adaptation](#project-specific-adaptation)

## Supported Architecture

Use one stable Caddy listener and two release slots. Each slot owns a Windows service for every configured API and worker. Only one slot receives traffic and runs workers. Releases are immutable directories; persistent data lives under the production root.

The template prevents deployment-caused interruptions. It does not survive loss of the physical host.

## Required Application Contracts

Before installation, establish all of these contracts:

1. Each API honors its configured `bindAddressEnvironment`, binds only to `127.0.0.1`, and exposes an unauthenticated loopback health endpoint that returns HTTP 2xx only when ready. JSON fields `ok: false` or `ready: false` are treated as unhealthy.
2. Each process exits on a normal Windows service stop. Workers stop accepting new jobs and finish, release, or safely lease out active work within `stopTimeoutSeconds`.
3. Persistent paths are selected through configuration or environment variables and do not depend on the release directory.
4. Database migrations remain compatible with the current and previous release. Use expand, migrate/backfill, switch, then contract in a later release.
5. Static asset filenames are content-hashed. Caddy serves static output from the immutable active release so one configuration reload switches frontend and API routing together.
6. Live database backup uses an application-aware command. For SQLite, use the SQLite backup API or an application backup endpoint, not an uncoordinated file copy.

## Configuration

Place `deployment.config.json` beside the generated PowerShell scripts. Keep it in source control. Use schema version `2`; migrate version 1 configs by adding `bindAddressEnvironment` to every API service.

Top-level fields:

- `appName`: Human-facing name.
- `servicePrefix`: ASCII letters and digits used in Windows service, task, and firewall names.
- `productionRoot`: Absolute application-owned directory whose final directory name equals `servicePrefix`. Never use a drive root, user profile, source checkout, or shared parent directory.
- `listenPort`: Stable Caddy listener, normally `80`.
- `publicOrigins`: HTTP browser origins accepted by the application. Do not include credentials, paths, queries, or fragments. This template does not configure TLS; add a reviewed TLS variant before using HTTPS origins.
- `firewallRemoteAddresses`: Windows firewall remote addresses such as `LocalSubnet`, specific addresses, or approved non-global corporate CIDRs. Global ranges such as `0.0.0.0/0`, `::/0`, and `Any` are rejected.
- `tools`: Pinned Caddy and WinSW versions with SHA-256 hashes.
- `release`: Deterministic test, build, dependency-install, and copy settings.
- `staticSite`: Enable static publishing and name the build output directory.
- `commonEnvironment`: Non-secret environment values shared by all services.
- `productionRootEnvironment`: Optional environment variable containing `productionRoot`.
- `allowedOriginsEnvironment`: Optional environment variable containing the comma-separated origins.
- `services`: API and worker definitions.
- `memoryGuard`: Sustained memory threshold policy.
- `backup`: Optional application-consistent scheduled backup command.
- `power`: Whether installation disables AC sleep and hibernation.

## Command Objects

Represent commands as an executable plus an argument array:

```json
{
  "executable": "npm.cmd",
  "arguments": ["run", "build"]
}
```

Commands are invoked directly rather than through `Invoke-Expression`. Do not put shell operators, redirections, or embedded secrets in arguments.

## Service Objects

API service example:

```json
{
  "name": "api",
  "displayName": "API",
  "type": "api",
  "entry": "server\\api.js",
  "portEnvironment": "PORT",
  "bindAddressEnvironment": "HOST",
  "bluePort": 18100,
  "greenPort": 28100,
  "healthPath": "/api/health",
  "routePaths": ["/api/*", "/uploads/*"],
  "stopTimeoutSeconds": 60,
  "memoryLimitMb": 1536,
  "environment": {}
}
```

Worker objects omit ports, health paths, and routes. Give every service a unique lowercase `name`. Entry paths must be relative and must not traverse outside a release.

The deployment engine sets every API's `bindAddressEnvironment` to `127.0.0.1` and verifies the actual listening address after readiness succeeds. Confirm that the selected application framework honors that variable; a process listening on a wildcard or non-loopback address is rejected before cutover.

Available string tokens in environment values are `{ProductionRoot}`, `{Slot}`, `{Port}`, and `{ReleasePath}`. Reference machine-level secret variables as `%VARIABLE_NAME%`; do not store their values in JSON.

Keep `servicePrefix` stable after first installation. Define secret references as system-level environment variables because services and scheduled backups run as `LocalSystem`. The installer preserves `%VARIABLE_NAME%` in WinSW XML instead of resolving it to plaintext during installation.

## Schema v1 Migration

Run `scripts/migrate-schema-v1-to-v2.ps1 -ProjectRoot <path>` first without `-Apply`. The dry run builds and validates a v2 candidate, reports runtime files that differ from the current Skill, and makes no project changes.

Use `-Apply` only from a clean Git worktree. The migration creates a ZIP backup, adds `bindAddressEnvironment` to every API, updates `schemaVersion`, synchronizes the v2 runtime scripts, and validates the result. A failed post-write validation restores the original project files automatically. It never runs installation or changes Windows services, firewall rules, scheduled tasks, or power settings.

Before migration, update and deploy the application so each API already honors the selected bind-address variable and listens on loopback. After migration, review the Git diff, run `preflight.ps1`, and run `install.ps1` rather than `deploy.ps1` so WinSW service environments and production-side helper scripts are refreshed.

## Configuration Reconciliation

Run `install.ps1` after adding, removing, or renaming services, changing service environment, toggling Memory Guard, or changing backup task configuration. After the new slot has switched successfully, installation disables, stops, and uninstalls services no longer present in configuration. It also removes a disabled backup task. Failed cleanup is recorded as `state/reconciliation-warning.json` and remains visible in `status.ps1`.

Normal code-only releases may use `deploy.ps1`. A failed pre-switch release restores the previous inactive-slot junction so the last reliable rollback target remains available. After traffic switches, an old-slot stop failure produces `switched-with-drain-warning` and `state/post-cutover-warning.json`; it does not claim that the cutover itself failed.

Installation, deployment, and rollback share a host-wide mutex keyed by the canonical production root. Do not bypass the lock. Installation applies firewall and power changes only after the release has switched successfully.

## Project-Specific Adaptation

Inspect and customize these areas for every project:

- API and worker entry points
- Route ownership and route ordering
- Port and bind-address environment variable names
- Test/build/install commands and copied release files
- Persistent-root and allowed-origin environment variables
- Worker stop timeout and memory limits
- Backup command, retention, off-host destination, and restore procedure
- Database migration and rollback compatibility
- Internal DNS, certificate, firewall CIDR, DHCP reservation, and service owner

Do not add platform variants to this configuration. Create separate templates or Skills for Linux, Docker, Kubernetes, IIS, Java services, or Python services.
