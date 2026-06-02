# AI Council VPS Healthcheck

AI Council VPS Healthcheck is the foundation for moving AI meeting-room monitoring, evidence collection, repository checks, and queued VPS work away from Tanabe-san's editing PC.

This repository provides documentation, local healthcheck scripts, workspace check scripts, a safe job inbox package, systemd units, and validation. GitHub credentials, SSH private keys, API keys, and password setup stay out of this repository.

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

Workspace confirmation is based on `sudo bash scripts/run_repo_check.sh <REPO_NAME>` generating `/var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md` on the VPS.

## Phase 3 Operator And Job Inbox

Phase 3 adds a VPS job inbox so AI-side work can be queued and processed on the VPS one job at a time. Smartphone entry is handled through GitHub Issues using `.github/ISSUE_TEMPLATE/vps-job.md`; the Issue request can then be converted into a local VPS job file.

Start from [docs/vps-ai-operator.md](docs/vps-ai-operator.md), then use [docs/vps-job-inbox.md](docs/vps-job-inbox.md) for the queue and runner commands.

Initial operator commands on the VPS:

```bash
sudo bash scripts/setup_operator_user.sh
bash scripts/job_status.sh
bash scripts/create_job.sh repo_check <REPO_NAME>
sudo bash scripts/run_job_once.sh
sudo bash scripts/report_job_result.sh
```

Timer-based processing remains manual until reviewed:

```bash
sudo systemctl enable --now ai-council-job-runner.timer
sudo systemctl status ai-council-job-runner.timer
```

Operator confirmation is based on `/var/log/ai-council/jobs/latest-job-report.md` being generated on the VPS. GitHub-to-VPS automatic bridging and GitHub result posting remain unconfirmed until credentials and the bridge are configured outside this repository.

## Verification Commands

```bash
bash -n scripts/*.sh
sudo /opt/ai-council/scripts/healthcheck.sh
sudo /opt/ai-council/scripts/report_status.sh
systemctl status ai-council-healthcheck.timer
systemctl list-timers ai-council-healthcheck.timer
bash scripts/job_status.sh
sudo bash scripts/run_job_once.sh
```

## Log Commands

```bash
sudo cat /var/log/ai-council/latest-report.md
sudo cat /var/log/ai-council/jobs/latest-job-report.md
sudo journalctl -u ai-council-healthcheck.service -n 100 --no-pager
sudo journalctl -u ai-council-healthcheck.timer -n 100 --no-pager
sudo journalctl -u ai-council-job-runner.service -n 100 --no-pager
```

## Where To Look When It Stops

- Timer state: `systemctl status ai-council-healthcheck.timer`
- Last service run: `systemctl status ai-council-healthcheck.service`
- Journal logs: `journalctl -u ai-council-healthcheck.service -n 100 --no-pager`
- Latest report: `/var/log/ai-council/latest-report.md`
- Installed scripts: `/opt/ai-council/scripts/`
- Workspace setup: `docs/vps-phase2-workspace-setup.md`
- Workspace reports: `/var/log/ai-council/workspaces/`
- Operator setup: `docs/vps-ai-operator.md`
- Job inbox: `/var/lib/ai-council/jobs/`
- Job reports: `/var/log/ai-council/jobs/`
