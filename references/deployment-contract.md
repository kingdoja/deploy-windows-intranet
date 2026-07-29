# Windows Intranet Deployment Contract

## Supported Architecture

Use one stable Caddy listener and two release slots. Each slot owns a Windows service for every configured API and worker. Only one slot receives traffic and runs workers. Releases are immutable directories; persistent data lives under the production root.

The template prevents deployment-caused interruptions. It does not survive loss of the physical host.

## Required Application Contracts

Before installation, establish all of these contracts:

1. Each API exposes an unauthenticated loopback health endpoint that returns HTTP 2xx only when ready. JSON fields `ok: false` or `ready: false` are treated as unhealthy.
2. Each process exits on a normal Windows service stop. Workers stop accepting new jobs and finish, release, or safely lease out active work within `stopTimeoutSeconds`.
3. Persistent paths are selected through configuration or environment variables and do not depend on the release directory.
4. Database migrations remain compatible with the current and previous release. Use expand, migrate/backfill, switch, then contract in a later release.
5. Static asset filenames are content-hashed. The publisher copies assets before atomically replacing `index.html`.
6. Live database backup uses an application-aware command. For SQLite, use the SQLite backup API or an application backup endpoint, not an uncoordinated file copy.

## Configuration

Place `deployment.config.json` beside the generated PowerShell scripts. Keep it in source control. Use schema version `1`.

Top-level fields:

- `appName`: Human-facing name.
- `servicePrefix`: ASCII letters and digits used in Windows service, task, and firewall names.
- `productionRoot`: Absolute application-owned directory. Never use a drive root, user profile, source checkout, or shared parent directory.
- `listenPort`: Stable Caddy listener, normally `80`.
- `publicOrigins`: Browser origins accepted by the application. The deployment engine exposes them through the configured origin environment variable.
- `firewallRemoteAddresses`: Windows firewall remote addresses such as `LocalSubnet` or an approved corporate CIDR. Avoid broad ranges without IT approval.
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

Available string tokens in environment values are `{ProductionRoot}`, `{Slot}`, `{Port}`, and `{ReleasePath}`. Reference machine-level secret variables as `%VARIABLE_NAME%`; do not store their values in JSON.

## Project-Specific Adaptation

Inspect and customize these areas for every project:

- API and worker entry points
- Route ownership and route ordering
- Port environment variable names
- Test/build/install commands and copied release files
- Persistent-root and allowed-origin environment variables
- Worker stop timeout and memory limits
- Backup command, retention, off-host destination, and restore procedure
- Database migration and rollback compatibility
- Internal DNS, certificate, firewall CIDR, DHCP reservation, and service owner

Do not add platform variants to this configuration. Create separate templates or Skills for Linux, Docker, Kubernetes, IIS, Java services, or Python services.

