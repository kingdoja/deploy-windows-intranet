# {{APP_NAME}} Windows Intranet Deployment Runbook

> Replace every `TODO` before production installation. This document is the human operating procedure; the scripts remain the executable source of truth.

## Service Ownership

- Application: `{{APP_NAME}}`
- Windows service prefix: `{{SERVICE_PREFIX}}`
- Business owner: TODO
- Technical owner: TODO
- IT/network contact: TODO
- Maintenance window: TODO
- Stable URL: TODO
- Server hostname and asset ID: TODO
- Production root: `C:\ProgramData\{{SERVICE_PREFIX}}`

## Architecture and Limits

Caddy listens on the stable intranet port. Blue and green API/worker services point at immutable releases. A release starts in the inactive slot, passes loopback health checks, then receives traffic through an atomic Caddy reload. The old slot stops after the switch.

This is single-host resilience against failed releases and process crashes. It does not survive host, disk, power, operating-system, switch, or site failure.

## Prerequisites

- Run Windows 11 Pro or Windows Server on an always-on wired host.
- Reserve the server IP through DHCP and configure internal DNS.
- Approve the firewall CIDR and, when available, issue an internal TLS certificate.
- Install supported Node.js and npm versions system-wide.
- Keep secrets in system-level environment variables available to `LocalSystem`; reference them as `%VARIABLE_NAME%` and do not put secret values in `deployment.config.json`.
- Confirm API readiness endpoints, worker graceful shutdown, persistent storage, and backward-compatible database migrations.
- Define an application-consistent backup and isolated restore procedure.

## First Installation

From elevated PowerShell in the repository:

```powershell
.\deploy\windows\preflight.ps1
.\deploy\windows\install.ps1
```

Expected host changes:

- Download pinned Caddy and WinSW binaries and verify SHA-256 hashes.
- Create the configured production directories.
- Register blue/green API and worker services, Caddy, and optionally the memory guard.
- Create one restricted inbound firewall rule.
- Optionally disable AC sleep and hibernation.
- Optionally register an application-consistent daily backup task.
- Build and deploy the first release unless `-SkipInitialDeploy` is specified.

## Routine Release

Commit the intended source changes, then run from elevated PowerShell:

```powershell
.\deploy\windows\deploy.ps1
.\deploy\windows\status.ps1
```

Do not use `-SkipTests` or `-AllowDirty` in normal operation. Record the reason and approver whenever an emergency release uses either switch.

When adding, removing, or renaming a service, changing service environment, toggling Memory Guard, or changing the backup task, run `install.ps1` instead of `deploy.ps1`. Installation deploys the new slot first, then reconciles obsolete services and tasks.

Post-release checks:

- Stable page and APIs respond from a second intranet computer.
- The reported active release matches the expected Git commit.
- New workers accept work and old workers are stopped.
- Error logs and memory-guard events remain normal.
- `postCutoverWarning` and `reconciliationWarning` are both null in `status.ps1` output.

`Completion status: switched-with-drain-warning` means traffic is already on the new version but the old slot is still running. Do not rerun deployment blindly; inspect `status.ps1`, stop the recorded old services, and clear the incident only after verifying they are stopped.

## Rollback

Confirm that the previous code remains compatible with the current database and persistent files, then run:

```powershell
.\deploy\windows\rollback.ps1
.\deploy\windows\status.ps1
```

Rollback switches code and static assets. It does not reverse destructive database migrations.

## Backup and Restore

- Backup schedule and task name: TODO
- Local backup path: TODO
- Off-host/NAS destination: TODO
- Retention: TODO
- Failure notification: TODO
- Restore drill owner and frequency: TODO

Manual backup:

```powershell
.\deploy\windows\backup.ps1
```

Document the application-specific isolated restore commands here: TODO.

## Diagnostics

```powershell
.\deploy\windows\status.ps1
Get-Service '{{SERVICE_PREFIX}}*'
Get-Content 'C:\ProgramData\{{SERVICE_PREFIX}}\logs\memory-guard.jsonl' -Tail 20
```

Log locations, event sources, monitoring URL, and escalation rules: TODO.

## Reboot and Disaster Recovery

After first installation and material service changes, perform a controlled reboot test. Confirm Caddy, active APIs, workers, memory guard, stable URL, and scheduled backup state.

For host loss, provision a replacement host, restore secrets and application-consistent data, run installation from a reviewed release, restore data into an isolated location, validate it, and only then update DNS or the reserved IP. Record exact project-specific recovery commands here: TODO.
