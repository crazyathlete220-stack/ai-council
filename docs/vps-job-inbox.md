# VPS Job Inbox

## Purpose

The job inbox gives the VPS a small, auditable queue for repository checks and workspace reports. It lets AI-side work be delegated to the VPS while keeping each execution visible and recoverable.

This inbox is also the bridge point for smartphone instructions. A request can start as a GitHub Issue, then be converted into a local VPS job file.

## Directories

```text
/var/lib/ai-council/jobs/queue
/var/lib/ai-council/jobs/active
/var/lib/ai-council/jobs/done
/var/lib/ai-council/jobs/failed
/var/log/ai-council/jobs
```

Meanings:

- `queue`: jobs waiting to run
- `active`: the single job currently being processed
- `done`: completed job files
- `failed`: failed job files
- `/var/log/ai-council/jobs`: job logs and summaries

## Setup

Run from this repository directory on the VPS:

```bash
sudo bash scripts/setup_operator_user.sh
bash scripts/job_status.sh
```

After `scripts/bootstrap_vps.sh` installs systemd units, the timer can be enabled manually:

```bash
sudo systemctl enable --now ai-council-job-runner.timer
sudo systemctl status ai-council-job-runner.timer
```

## Job File Format

Job files are strict `KEY=value` files created by `scripts/create_job.sh`. The runner reads only approved keys and does not execute job files as shell scripts.

Required fields:

```bash
JOB_ID=<generated-id>
JOB_TYPE=repo_check
REPO_NAME=ai-council
REQUEST_SOURCE=manual
REQUESTED_BY=tanabe
CREATED_AT=2026-06-02T00:00:00Z
```

Supported `JOB_TYPE` values:

- `repo_check`
- `workspace_summary`
- `ai_plan`
- `ai_check`

## Create A Job

Repo check:

```bash
bash scripts/create_job.sh repo_check ai-council
```

Workspace summary:

```bash
bash scripts/create_job.sh workspace_summary
```

AI worker plan:

```bash
bash scripts/create_job.sh ai_plan ai-council
```

AI worker bounded check:

```bash
bash scripts/create_job.sh ai_check ai-council
```

If the queue directory is root-owned, run the same command with `sudo`.

## Run One Job

Manual execution:

```bash
sudo bash scripts/run_job_once.sh
```

Check status:

```bash
bash scripts/job_status.sh
sudo bash scripts/report_job_result.sh
```

## Smartphone Entry Flow

1. Open GitHub from the smartphone.
2. Create an Issue using `.github/ISSUE_TEMPLATE/vps-job.md`.
3. Fill in `JOB_TYPE` and `REPO_NAME`.
4. `scripts/import_github_jobs.sh` converts the Issue into a VPS queue job when `gh` is authenticated on the VPS.
5. The VPS runner creates `/var/log/ai-council/jobs/latest-job-report.md`.
6. `scripts/post_job_result_to_github.sh` can paste the result back to the Issue when `gh` is authenticated on the VPS.

This phase creates the safe inbox and execution package. GitHub authentication stays outside this repository.

## Safety Rules

- Do not put passwords, GitHub tokens, SSH private keys, or API keys in job files.
- Do not use the job inbox for arbitrary shell commands.
- Do not run `git pull`, `git push`, `npm install`, or `npm ci` from the job runner.
- Do not delete workspace roots as part of normal recovery.
- Keep one job active at a time so evidence remains easy to inspect.

## Confirmation

The job inbox is not confirmed on the VPS until:

- `bash scripts/job_status.sh` ends with `JOB_INBOX_STATUS: OK`
- `sudo bash scripts/run_job_once.sh` processes a job
- `/var/log/ai-council/jobs/latest-job-report.md` exists
- repo or workspace reports exist under `/var/log/ai-council/workspaces`
