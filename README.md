# AI Council VPS Healthcheck

AI Council VPS Healthcheck is the Phase 0 foundation for moving AI meeting-room monitoring, evidence collection, and recovery checks from Tanabe-san's editing PC to a VPS.

This repository currently provides documentation, local healthcheck scripts, systemd units, and validation for Phase 0 only. GitHub posting, secrets setup, and VPS execution are intentionally out of scope for this phase.

VPS operation is not confirmed until `/var/log/ai-council/latest-report.md` has been generated on the VPS.

## What Runs On The VPS

- `scripts/healthcheck.sh` collects basic host, OS, disk, memory, command, and directory status.
- `scripts/report_status.sh` writes the latest report to `/var/log/ai-council/latest-report.md`.
- `systemd/ai-council-healthcheck.timer` runs the report once per day.
- `systemd/ai-council-healthcheck.service` can also be started manually.

## Initial Setup

Phase 0 assumes that this repository's files already exist on the VPS. The method for placing the repository on the VPS, such as a future `git clone` or file copy flow, is not implemented in Phase 0.

The initial setup entry point is the directory that contains this `README.md` and `scripts/bootstrap_vps.sh`. After Tanabe-san reviews the PR and the repository contents are present on the VPS, run these commands manually from that directory:

```bash
test -f README.md
test -f scripts/bootstrap_vps.sh
sudo bash scripts/bootstrap_vps.sh
```

The bootstrap script installs minimum packages, creates `/opt/ai-council` and `/var/log/ai-council`, copies the repository files into `/opt/ai-council`, installs the systemd service and timer, and prints the next confirmation commands.

## Phase 2 Workspace

Phase 2 prepares the VPS as an AI work area for repository checks. The workload moved away from the PC is build, test, lint, status checks, and log generation. It is not an AI model migration.

Start from [docs/vps-phase2-workspace-setup.md](docs/vps-phase2-workspace-setup.md), then use [docs/vps-workspace-operations.md](docs/vps-workspace-operations.md) as the operations guide.

Workspace confirmation is based on `scripts/run_repo_check.sh <REPO_NAME>` generating `/var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md` on the VPS.

## Verification Commands

```bash
bash -n scripts/*.sh
sudo /opt/ai-council/scripts/healthcheck.sh
sudo /opt/ai-council/scripts/report_status.sh
systemctl status ai-council-healthcheck.timer
systemctl list-timers ai-council-healthcheck.timer
```

## Log Commands

```bash
sudo cat /var/log/ai-council/latest-report.md
sudo journalctl -u ai-council-healthcheck.service -n 100 --no-pager
sudo journalctl -u ai-council-healthcheck.timer -n 100 --no-pager
```

## Where To Look When It Stops

- Timer state: `systemctl status ai-council-healthcheck.timer`
- Last service run: `systemctl status ai-council-healthcheck.service`
- Journal logs: `journalctl -u ai-council-healthcheck.service -n 100 --no-pager`
- Latest report: `/var/log/ai-council/latest-report.md`
- Installed scripts: `/opt/ai-council/scripts/`
- Workspace setup: `docs/vps-phase2-workspace-setup.md`
- Workspace reports: `/var/log/ai-council/workspaces/`
