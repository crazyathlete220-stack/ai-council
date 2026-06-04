# VPS AI Worker

## Purpose

VPS AI Worker is the next track after the AI Council healthcheck, workspace, job inbox, and GitHub bridge foundations.

The goal is to reduce PC load by moving repository inspection, planning, checks, patch preparation, and eventually PR creation toward the VPS.

This is not an AI model migration to the VPS. Phase 5 starts with safe planning and bounded checks only.

## Phase Order

1. `ai_plan`
   - creates a plan report on the VPS
   - reads safe metadata from the workspace and request source
   - does not edit files
   - does not run build/test/install commands
   - does not push or create PRs

2. `ai_check`
   - runs bounded repository checks on the VPS
   - checks required files, shell syntax, git metadata, and package script availability
   - does not run install commands
   - does not edit files

3. `ai_patch`
   - future phase
   - prepares a local diff on the VPS
   - does not push

4. `ai_pr`
   - future phase
   - creates a branch, verifies it, and opens a PR after a separate credential and approval design

## Send An ai_plan Request

Create a GitHub Issue with the `vps-job` label and include:

```text
JOB_TYPE=ai_plan
REPO_NAME=ai-council
```

The `VPS AI Plan` Issue form provides that default command.

Short casual phrases that include `計画`, `方針`, `plan`, or `プラン` are also mapped to `ai_plan` for `ai-council`.

Free-form requests that do not match a known safe job type are also routed to `ai_plan`. This lets smartphone requests stay conversational while keeping execution planning-only.

## Send An ai_check Request

Create a GitHub Issue with the `vps-job` label and include:

```text
JOB_TYPE=ai_check
REPO_NAME=ai-council
```

The `VPS AI Check` Issue form provides that default command.

Short casual phrases that include `検証`, `安全確認して`, `安全確認を`, `チェックだけ`, `確認だけ`, or `check only` are mapped to `ai_check` for `ai-council`.

## Run Manually On The VPS

```bash
bash /opt/ai-council/scripts/create_job.sh ai_plan ai-council
sudo bash /opt/ai-council/scripts/run_job_once.sh
sudo bash /opt/ai-council/scripts/report_job_result.sh
```

For a bounded check:

```bash
bash /opt/ai-council/scripts/create_job.sh ai_check ai-council
sudo bash /opt/ai-council/scripts/run_job_once.sh
sudo bash /opt/ai-council/scripts/report_job_result.sh
```

## Evidence

`ai_plan` writes:

```text
/var/log/ai-council/ai-worker/<JOB_ID>/plan.md
/var/log/ai-council/ai-worker/latest-plan.md
/var/log/ai-council/jobs/latest-job-report.md
```

`ai_check` writes:

```text
/var/log/ai-council/ai-worker/<JOB_ID>/check.md
/var/log/ai-council/ai-worker/latest-check.md
/var/log/ai-council/jobs/latest-job-report.md
```

Expected signals:

```text
AI_PLAN_STATUS: OK
AI_CHECK_STATUS: OK
JOB_RUNNER_STATUS: OK
```

When the request came from a GitHub Issue, the bridge can post those signals back to the same Issue.

## Safety Boundary

- Issue text is not executed as shell.
- `ai_plan` does not edit files.
- `ai_plan` does not run build, test, install, push, or PR creation commands.
- `ai_check` does not edit files.
- `ai_check` does not run install, push, or PR creation commands.
- `ai_check` does not execute free-form Issue text as shell.
- `ai_plan` does not create GitHub tokens, SSH private keys, API keys, passwords, or secrets.
- VPS AI CLI execution is not confirmed in this phase.

## Recovery

If an `ai_plan` request does not produce a result:

```bash
bash /opt/ai-council/scripts/job_status.sh
sudo journalctl -u ai-council-github-bridge.service -n 100 --no-pager
sudo cat /var/log/ai-council/jobs/latest-job-report.md
sudo cat /var/log/ai-council/ai-worker/latest-plan.md
sudo cat /var/log/ai-council/ai-worker/latest-check.md
```
