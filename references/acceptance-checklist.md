# Acceptance Checklist

## Before Installation

- Schema v1 packages were migrated with a clean Git worktree, the ZIP backup path was recorded, and the migration diff was reviewed.
- Repository instructions and current worktree state are understood.
- Every configured test, build, entry, include, and static-output path exists.
- Every API health endpoint reflects dependency readiness, not merely process liveness.
- Every API honors `bindAddressEnvironment` and listens only on `127.0.0.1`; wildcard and LAN-facing slot listeners are rejected.
- Workers have a verified graceful-stop or lease-recovery strategy.
- Persistent data and secret locations are outside releases.
- Database migrations support both active and rollback versions.
- Internal IP reservation, DNS, firewall CIDR, and service ownership are agreed with IT.
- Backup is application-consistent and has an off-host destination, or the missing control is explicitly accepted.
- `preflight.ps1` reports no blocking errors.
- Every occupied configured port is owned by the expected WinSW service process tree; a production directory alone is not sufficient.
- Every Caddy process has a unique loopback administration port; an existing listener on 2019 is not assumed to belong to this application.

## First Installation

- Caddy and WinSW downloads match pinned hashes.
- Only the intended firewall port and remote addresses are created.
- Firewall and power settings remain unchanged if the initial release fails before cutover.
- All generated Windows services have expected executable, working directory, environment, startup type, and recovery settings.
- The first release passes health checks through loopback and through the stable intranet URL.
- When using a shared gateway, the route fragment survives a deployment of the gateway-owning project and an existing hostname remains healthy after reload.
- Static pages and APIs return expected responses from a second intranet machine.
- Reboot restores Caddy, the active APIs, workers, and memory guard.

## Release and Rollback

- A new release starts in the inactive slot while the stable URL remains healthy.
- Failed tests, build, dependency installation, or health checks do not alter the active slot.
- One Caddy reload switches APIs and the immutable static frontend only after all new APIs are ready.
- Old workers drain or safely release work before their timeout.
- Rollback restores the previous frontend and APIs without changing persistent data.
- A forced inactive-slot API crash is automatically recovered without affecting the stable URL.
- A failed candidate release restores the previous inactive-slot release and remains immediately rollback-capable.
- Removing or renaming a configured service through `install.ps1` stops and uninstalls the obsolete service after cutover.
- Memory Guard process-tree accounting is covered by `scripts/test-skill.ps1` and produces no `$PID` automatic-variable errors.
- `status.ps1` reports no unresolved post-cutover or reconciliation warning.
- A concurrent install, deploy, or rollback attempt is rejected by the deployment operation lock.

## Backup and Recovery

- Scheduled backup runs under its configured service account.
- The scheduled task is triggered once during acceptance and finishes with result code 0.
- Backup output includes databases, uploaded media, configuration required for recovery, and a manifest.
- Backup copies leave the host or disk on an approved schedule.
- A restore drill is performed into an isolated directory and the restored application passes health and data checks.
- Retention and failed-backup notification are documented.

## Handoff

- The generated Runbook contains real URLs, paths, commands, owners, maintenance windows, backup destination, and escalation contacts.
- Operators can run status, deploy, rollback, backup, and restore without Codex.
- Known single-host risks and postponed controls are recorded.
