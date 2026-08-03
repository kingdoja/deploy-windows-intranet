---
name: deploy-windows-intranet
description: Audit, adapt, install, and operate configuration-driven blue-green deployments for Node.js, Next.js, and Vite applications on Windows 11 or Windows Server using Caddy and WinSW, with persistent SQLite/media storage, backup/restore validation, and optional hostname routing through a shared intranet gateway. Use when Codex needs to turn a Windows web project into a long-running intranet service, migrate an edge/Cloudflare app to local Node storage, add near-zero-downtime releases and rollback, coexist with multiple sites on one host, generate a deployment Runbook, or diagnose a package built from this skill.
---

# Deploy Windows Intranet

Build a project-owned deployment package that remains runnable without Codex. Use the Skill to inspect and adapt; use generated PowerShell scripts for deterministic operations; generate a project Runbook for humans.

## Scope

Support Windows 11/Windows Server projects with:

- Node.js API and worker processes
- Next.js SSR/full-stack or optional Vite/static frontend output
- Caddy as the stable intranet HTTP entry point
- WinSW-managed Windows services
- Blue/green releases on one host
- Health-gated traffic switching, rollback, memory guard, and optional application-consistent backup
- Optional host-based routing through a separately owned shared Caddy gateway

Do not present this as machine-level high availability. One host still has power, disk, operating-system, and network failure modes. Do not force this template onto Linux, containers, IIS-only applications, or applications without a reliable health endpoint and graceful shutdown contract.

## Workflow

1. Read repository instructions. If `.codegraph/` exists, use CodeGraph before searching or reading application code.
2. Run `scripts/audit-project.ps1 -ProjectRoot <path>` for a read-only inventory.
3. Read [references/deployment-contract.md](references/deployment-contract.md). Inspect application entry points, health handlers, persistent storage, shutdown behavior, build/test commands, and database migrations. For Next.js, edge bindings, D1/KV, or SQLite, also read [references/nextjs-node-sqlite.md](references/nextjs-node-sqlite.md).
4. If the project already has a schema v1 package, run `scripts/migrate-schema-v1-to-v2.ps1 -ProjectRoot <path>` as a dry run. Review the result, then rerun with `-Apply`; never replace an existing package with scaffold `-Force` as a migration shortcut.
5. For a new package, run `scripts/scaffold-project.ps1 -ProjectRoot <path> -AppName <name>` to create project-owned files. Never overwrite an existing deployment directory without an explicit user request and `-Force`.
6. Edit `deploy/windows/deployment.config.json` to match the inspected project. Keep secrets out of the file; reference machine-level environment variables with `%VARIABLE_NAME%`. Inventory occupied stable and Caddy admin ports; assign a unique `caddyAdminPort` whenever another Caddy runs on the host.
7. Adapt project-specific backup or data migration hooks. Require application-consistent database backup. Do not substitute a raw file copy for a live SQLite database backup.
8. Run `scripts/validate-project.ps1 -ProjectRoot <path>`. Fix every error before installation.
9. Run the generated `preflight.ps1`. Report host changes that installation will make: downloads, service registration, scheduled tasks, firewall rules, power settings, and production directories. Resolve both listener-port and Caddy-admin-port conflicts.
10. Execute `install.ps1` only when the user asked to deploy or install on that host. Installation is a privileged, state-changing action.
11. Validate using [references/acceptance-checklist.md](references/acceptance-checklist.md). Run the scheduled backup as its real account and perform an isolated restore drill. Generate and customize the project Runbook; record real URLs, service names, backup destinations, owners, and recovery steps.
12. When multiple sites share one host, read [references/shared-gateway.md](references/shared-gateway.md). Prefer a corporate DNS hostname through one shared gateway over a `/name` subpath. Dry-run `configure-shared-gateway.ps1`; modify the separately owned gateway only with explicit authorization, preserve its route import in its own source, and verify an existing site after reload.

## Operating Rules

- Keep generated deployment files in the business repository so Git records changes.
- Keep application data, logs, secrets, tools, releases, and active-slot state outside the source checkout.
- Keep each per-application Caddy admin endpoint on a unique loopback port; port 2019 is not globally reusable on one host.
- Run tests and build before creating a release directory.
- Force every API slot to loopback, start the inactive slot, wait for every readiness endpoint, switch frontend and API routing in one Caddy reload, then drain the old slot.
- Serialize installation, deployment, and rollback with the generated host-wide operation lock.
- Preserve both the active slot and the previous rollback target on any pre-switch failure.
- Treat `switched-with-drain-warning`, `postCutoverWarning`, and `reconciliationWarning` as incidents requiring operator action even though traffic already switched.
- Run `scripts/test-skill.ps1` after changing this Skill or its generated PowerShell assets.
- Require expand/contract database migrations across at least the current and previous application versions.
- Treat `-SkipTests`, disabled backups, broad firewall ranges, dirty releases, and missing restore drills as explicit risks, never invisible defaults.
- Treat external wildcard-DNS aliases as temporary fallbacks, not replacements for managed internal DNS.
- Never install from placeholder service entries. Validate every configured entry point and build artifact first.

## Resources

- `scripts/audit-project.ps1`: inspect a project without modifying it.
- `scripts/scaffold-project.ps1`: copy the project-owned deployment template and Runbook.
- `scripts/migrate-schema-v1-to-v2.ps1`: dry-run or apply a recoverable schema v1 package migration without installing host services.
- `scripts/validate-project.ps1`: validate configuration, referenced files, and the generated package.
- `scripts/test-skill.ps1`: run isolated regression tests without installing services or changing host settings.
- `assets/windows-blue-green/`: files copied into the target project.
- Generated `configure-shared-gateway.ps1`: dry-run or install one hostname route fragment without taking ownership of the shared gateway's full configuration.
- [references/deployment-contract.md](references/deployment-contract.md): configuration schema and application contracts.
- [references/acceptance-checklist.md](references/acceptance-checklist.md): installation and release acceptance gates.
- [references/nextjs-node-sqlite.md](references/nextjs-node-sqlite.md): adapt Next.js, edge bindings, SQLite, local media, cookies, and data migration.
- [references/shared-gateway.md](references/shared-gateway.md): safely host multiple named sites behind one shared port-80/443 Caddy.
