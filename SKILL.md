---
name: deploy-windows-intranet
description: Audit, scaffold, adapt, validate, install, and operate configuration-driven blue-green deployments for Node.js and Vite applications on Windows 11 or Windows Server using Caddy and WinSW. Use when Codex needs to turn a Windows intranet web project into a long-running service, reuse the FrameLab-style deployment on another project, add near-zero-downtime releases and rollback, generate a deployment Runbook, or diagnose an existing deployment package built from this skill.
---

# Deploy Windows Intranet

Build a project-owned deployment package that remains runnable without Codex. Use the Skill to inspect and adapt; use generated PowerShell scripts for deterministic operations; generate a project Runbook for humans.

## Scope

Support Windows 11/Windows Server projects with:

- Node.js API and worker processes
- Optional Vite or other static frontend output
- Caddy as the stable intranet HTTP entry point
- WinSW-managed Windows services
- Blue/green releases on one host
- Health-gated traffic switching, rollback, memory guard, and optional application-consistent backup

Do not present this as machine-level high availability. One host still has power, disk, operating-system, and network failure modes. Do not force this template onto Linux, containers, IIS-only applications, or applications without a reliable health endpoint and graceful shutdown contract.

## Workflow

1. Read repository instructions. If `.codegraph/` exists, use CodeGraph before searching or reading application code.
2. Run `scripts/audit-project.ps1 -ProjectRoot <path>` for a read-only inventory.
3. Read [references/deployment-contract.md](references/deployment-contract.md). Inspect application entry points, health handlers, persistent storage, shutdown behavior, build/test commands, and database migrations.
4. Run `scripts/scaffold-project.ps1 -ProjectRoot <path> -AppName <name>` to create project-owned files. Never overwrite an existing deployment directory without an explicit user request and `-Force`.
5. Edit `deploy/windows/deployment.config.json` to match the inspected project. Keep secrets out of the file; reference machine-level environment variables with `%VARIABLE_NAME%`.
6. Adapt project-specific backup or data migration hooks. Require application-consistent database backup. Do not substitute a raw file copy for a live SQLite database backup.
7. Run `scripts/validate-project.ps1 -ProjectRoot <path>`. Fix every error before installation.
8. Run the generated `preflight.ps1`. Report host changes that installation will make: downloads, service registration, scheduled tasks, firewall rules, power settings, and production directories.
9. Execute `install.ps1` only when the user asked to deploy or install on that host. Installation is a privileged, state-changing action.
10. Validate using [references/acceptance-checklist.md](references/acceptance-checklist.md). Generate and customize the project Runbook; record real URLs, service names, backup destinations, owners, and recovery steps.

## Operating Rules

- Keep generated deployment files in the business repository so Git records changes.
- Keep application data, logs, secrets, tools, releases, and active-slot state outside the source checkout.
- Run tests and build before creating a release directory.
- Start the inactive slot, wait for every API health endpoint, switch Caddy atomically, then drain the old slot.
- Preserve the active slot on any pre-switch failure.
- Require expand/contract database migrations across at least the current and previous application versions.
- Treat `-SkipTests`, disabled backups, broad firewall ranges, dirty releases, and missing restore drills as explicit risks, never invisible defaults.
- Never install from placeholder service entries. Validate every configured entry point and build artifact first.

## Resources

- `scripts/audit-project.ps1`: inspect a project without modifying it.
- `scripts/scaffold-project.ps1`: copy the project-owned deployment template and Runbook.
- `scripts/validate-project.ps1`: validate configuration, referenced files, and the generated package.
- `assets/windows-blue-green/`: files copied into the target project.
- [references/deployment-contract.md](references/deployment-contract.md): configuration schema and application contracts.
- [references/acceptance-checklist.md](references/acceptance-checklist.md): installation and release acceptance gates.

