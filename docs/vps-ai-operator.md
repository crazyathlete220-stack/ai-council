# VPS AI Operator

## Purpose

Phase 3 adds a safe operator layer so the VPS can accept queued workspace jobs and produce evidence without making Tanabe-san's PC run every check.

This is not an AI model migration. The VPS is the workbench that receives approved jobs, runs repository checks, and records logs. The AI model remains outside the VPS.

## Entry

The intended instruction entry points are:

- GitHub Issues from a PC or smartphone
- GitHub PR comments that request a VPS workspace check
- manual job files placed under `/var/lib/ai-council/jobs/queue`
- future bridge code that converts GitHub requests into local job files

Use `.github/ISSUE_TEMPLATE/vps-job.md` for mobile-friendly requests.

## Read

The operator layer reads:

- queued jobs under `/var/lib/ai-council/jobs/queue`
- workspace registry files under `/etc/ai-council/workspaces.d`
- installed scripts under `/opt/ai-council/scripts`
- repo files under `/opt/ai-workspaces/<REPO_NAME>`

It does not read GitHub tokens, SSH private keys, API keys, or password files from this repository.

## Execute

The first supported job types are:

- `repo_check`: run `sudo bash /opt/ai-council/scripts/run_repo_check.sh <REPO_NAME>`
- `workspace_summary`: run `sudo bash /opt/ai-council/scripts/report_workspaces.sh`
- `ai_plan`: run `sudo bash /opt/ai-council/scripts/run_ai_plan.sh <REPO_NAME>`
- `ai_check`: run `sudo bash /opt/ai-council/scripts/run_ai_check.sh <REPO_NAME>`

The runner processes one queued job at a time:

```bash
sudo bash scripts/run_job_once.sh
```

For timer-based processing after review:

```bash
sudo systemctl enable --now ai-council-job-runner.timer
sudo systemctl list-timers ai-council-job-runner.timer
```

## Evidence

Job evidence is written under:

```text
/var/log/ai-council/jobs/
```

Primary files:

- `/var/log/ai-council/jobs/latest-job-report.md`
- `/var/log/ai-council/jobs/latest-summary.md`
- `/var/log/ai-council/jobs/<JOB_ID>-<timestamp>.log`

Repo evidence still lives under:

```text
/var/log/ai-council/workspaces/<REPO_NAME>/
```

## Recovery

If a job does not run:

```bash
bash scripts/job_status.sh
sudo ls -la /var/lib/ai-council/jobs/queue
sudo ls -la /var/lib/ai-council/jobs/active
sudo journalctl -u ai-council-job-runner.service -n 100 --no-pager
```

If a job fails:

```bash
sudo cat /var/log/ai-council/jobs/latest-job-report.md
sudo ls -la /var/lib/ai-council/jobs/failed
sudo cat /var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md
```

Rerun only after recording the failed job ID and latest log path in the Issue or PR.

## Human-Visible Confirmation

Do not claim the operator layer is working until a job has moved through the VPS queue and `/var/log/ai-council/jobs/latest-job-report.md` exists on the VPS.

Use this confirmation block:

```md
## VPS operator report

## Result
- JOB_RUNNER_STATUS:
- REPO_CHECK_STATUS:
- WORKSPACE_SUMMARY_STATUS:

## Evidence
- latest-job-report.md:
- workspace latest-report.md:
- latest-summary.md:

## Unconfirmed
- GitHub-to-VPS automatic bridge:
- GitHub result posting:
- secrets configuration:
- AI model migration:
```
