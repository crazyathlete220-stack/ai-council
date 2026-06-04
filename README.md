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

## GitHub Issue Bridge

The GitHub bridge lets a smartphone-created Issue with the `vps-job` label become a VPS job. It requires `gh` to be installed and authenticated on the VPS, but this repository does not create or store GitHub tokens or secrets.

The bridge imports Issues only from GitHub usernames listed in the VPS-side allowlist file. Create that file outside the repository before enabling timer-based imports:

```bash
sudo install -d -m 0755 /etc/ai-council
printf '%s\n' '<GITHUB_USERNAME>' | sudo tee /etc/ai-council/github-bridge-allowlist >/dev/null
sudo chmod 0644 /etc/ai-council/github-bridge-allowlist
```

If the allowlist file is missing or empty, the bridge refuses imports and writes rejection evidence under `/var/log/ai-council/github-bridge/rejected-issues.log`.

For smartphone requests, start from [docs/mobile-vps-jobs.md](docs/mobile-vps-jobs.md) and use the `VPS Free Request` Issue form for natural-language requests. Use `VPS Job Casual` for known short Japanese requests, or `VPS Job Mobile` when you want direct `JOB_TYPE` fields.

For VPS operations, start from [docs/vps-github-bridge.md](docs/vps-github-bridge.md).

Manual bridge commands on the VPS:

```bash
sudo bash scripts/import_github_jobs.sh
sudo bash scripts/run_job_once.sh
sudo bash scripts/report_job_result.sh
sudo bash scripts/post_job_result_to_github.sh
```

Timer-based bridge processing remains manual until reviewed:

```bash
sudo systemctl enable --now ai-council-github-bridge.timer
sudo systemctl status ai-council-github-bridge.timer
```

## Phase 5 AI Worker

Phase 5 starts moving AI-side planning and checking work toward the VPS. It begins with `ai_plan`, which creates a plan report only, and `ai_check`, which runs bounded verification only. These jobs do not edit files, push branches, create PRs, or move an AI model onto the VPS.

Start from [docs/vps-ai-worker.md](docs/vps-ai-worker.md). For ChatGPT-created requests, use the `VPS AI Plan` Issue form or include:

```text
JOB_TYPE=ai_plan
REPO_NAME=ai-council
```

To ask the VPS for a safe check while the PC is closed, use the `VPS AI Check` Issue form or include:

```text
JOB_TYPE=ai_check
REPO_NAME=ai-council
```

For a free-form request, use the `VPS Free Request` Issue form. If the bridge cannot classify the text as a known check or summary request, it routes the request to `ai_plan` and creates planning evidence only.

## Phase 8 AI CLI Runner

Phase 8 starts moving the actual AI work session to the VPS. It adds `ai_exec`, which can run an already-authenticated Codex CLI as the `ai-council` operator user inside a registered VPS workspace.

Start from [docs/vps-ai-cli-runner.md](docs/vps-ai-cli-runner.md). The setup entry point on the VPS is:

```bash
sudo bash scripts/setup_ai_cli_runner.sh ai-council
bash scripts/ai_cli_status.sh ai-council
```

For smartphone requests that should actually run the VPS AI CLI, use the `VPS AI Exec` Issue form or include:

```text
JOB_TYPE=ai_exec
REPO_NAME=ai-council
```

`ai_exec` may edit files in the VPS workspace, but it does not run `git push`, create PRs, or create secrets. It is not an AI model host; the VPS runs the CLI and workspace operations.

Default `ai_exec` guardrails limit GitHub Issue input to 12000 bytes, stop the CLI after 900 seconds, block concurrent runs, and rate-limit back-to-back runs for 300 seconds. These limits can be changed with VPS-side environment variables only; do not store secrets in repository files.

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
sudo cat /var/log/ai-council/ai-worker/latest-plan.md
sudo cat /var/log/ai-council/ai-worker/latest-check.md
sudo cat /var/log/ai-council/ai-cli/latest-exec.md
sudo journalctl -u ai-council-healthcheck.service -n 100 --no-pager
sudo journalctl -u ai-council-healthcheck.timer -n 100 --no-pager
sudo journalctl -u ai-council-job-runner.service -n 100 --no-pager
sudo journalctl -u ai-council-github-bridge.service -n 100 --no-pager
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
- GitHub bridge: `docs/vps-github-bridge.md`
- Mobile VPS jobs: `docs/mobile-vps-jobs.md`
- VPS AI worker: `docs/vps-ai-worker.md`
- VPS AI CLI runner: `docs/vps-ai-cli-runner.md`
- GitHub bridge state: `/var/lib/ai-council/github-bridge/`
