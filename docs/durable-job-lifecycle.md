# Durable GitHub Job Lifecycle

## Purpose

Prevent silent loss, duplicate execution, and result mix-ups in the GitHub Issue → bridge → queue → Runner → GitHub path.

## Runtime split

- `ai-council-github-bridge.service`: import eligible labeled Issues only.
- `ai-council-job-runner.service`: execute one serialized job cycle, create a per-job report, summarize it, and post the result.
- `run_job_once.sh`: owns the single-runner lock and queue transitions.
- `run_job_cycle.sh`: guarantees result handling is attempted even when execution fails.

The bridge and runner must not both consume the queue.

## States visible from GitHub

- `DISPATCH_READY`: label is present; VPS pickup is not yet proven.
- `STATE: BLOCKED`: import preflight found a durable blocker, such as `WORKSPACE_NOT_REGISTERED`.
- `STATE: QUEUED`: a concrete Job ID was created.
- `JOB_RUNNER_STATUS: DEFERRED`: transient guardrail blocked execution; the same job remains queued with `NOT_BEFORE_EPOCH`.
- `JOB_RUNNER_STATUS: OK`: execution completed.
- `JOB_RUNNER_STATUS: ERROR`: execution failed and the job moved to `failed/`.

## Evidence locations

- Per-job report: `/var/log/ai-council/jobs/reports/<JOB_ID>.md`
- Per-job summary: `/var/log/ai-council/jobs/summaries/<JOB_ID>.md`
- Queue: `/var/lib/ai-council/jobs/queue/`
- Failed jobs: `/var/lib/ai-council/jobs/failed/`
- Import markers: `/var/lib/ai-council/github-bridge/imported/`
- Blocked markers: `/var/lib/ai-council/github-bridge/blocked/`
- Posted markers: `/var/lib/ai-council/github-bridge/posted/`

`latest-job-report.md` remains a convenience pointer only. Final GitHub posting uses the explicit per-job report path.

## Deployment

From the checked-out `ai-council` workspace on the VPS:

```bash
sudo bash scripts/deploy_runtime.sh
```

This installs only runtime scripts and the bridge/runner units, reloads systemd, enables both timers, and triggers one import/run cycle. It does not install packages or alter credentials.

## Workspace recovery

A missing workspace is blocked before queue creation. After placing and registering the repo:

```bash
sudo bash scripts/register_workspace.sh <REPO_NAME> /opt/ai-workspaces/<REPO_NAME>
sudo bash scripts/requeue_github_issue.sh <ISSUE_NUMBER>
```

## Completion test

A recovery is complete only when all are visible:

1. `DISPATCH_READY`
2. `STATE: QUEUED` with Job ID
3. per-job report path
4. execution-specific status
5. `JOB_RUNNER_STATUS: OK` or an explicit `BLOCKED/ERROR`
6. a result comment on the same Issue
