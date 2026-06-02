# VPS GitHub Bridge

## Purpose

The GitHub bridge connects smartphone-friendly GitHub Issues to the VPS job inbox.

This is still not an AI model migration. The VPS reads approved GitHub Issue requests, creates local jobs, runs the existing job runner, and can post a short result comment back to the Issue when GitHub CLI authentication is already configured on the VPS.

## Requirements

- `gh` is installed on the VPS.
- `gh auth status` succeeds on the VPS.
- The authenticated GitHub account can read Issues and write Issue comments for this repository.
- Issues use the `vps-job` label.

This repository does not create GitHub tokens, SSH private keys, API keys, or secrets.

## Issue Request Format

For smartphone use, create an Issue from the `VPS Job Casual` form. It applies the `vps-job` label automatically and accepts short Japanese requests:

```text
ai-councilの状態見て
作業場まとめて
```

Use `VPS Job Mobile` when you want to edit the direct command:

```text
JOB_TYPE=repo_check
REPO_NAME=ai-council
```

The shorter mobile guide is [mobile-vps-jobs.md](mobile-vps-jobs.md).

Supported job types:

- `repo_check`
- `workspace_summary`

Supported casual phrases are intentionally mapped only to those job types. Unsupported free text is skipped instead of being executed.

One Issue creates one VPS job. To run another job, create another Issue.

## Manual Bridge Run

Run from `/opt/ai-council` on the VPS:

```bash
sudo bash scripts/import_github_jobs.sh
sudo bash scripts/run_job_once.sh
sudo bash scripts/report_job_result.sh
sudo bash scripts/post_job_result_to_github.sh
```

Expected signals:

- `GITHUB_JOB_IMPORT_STATUS: OK`, `NO_MATCHING_ISSUES`, or `AUTH_REQUIRED`
- `JOB_RUNNER_STATUS: OK`, `ERROR`, or `IDLE`
- `JOB_REPORT_STATUS: OK`
- `GITHUB_JOB_POST_STATUS: OK`, `NO_ISSUE_SOURCE`, `ALREADY_POSTED`, or `AUTH_REQUIRED`

## Timer-Based Bridge

After review, enable the timer manually:

```bash
sudo systemctl enable --now ai-council-github-bridge.timer
sudo systemctl status ai-council-github-bridge.timer
```

The timer runs:

1. import GitHub Issue requests into `/var/lib/ai-council/jobs/queue`
2. process one queued job
3. update the latest job summary
4. post the latest result back to the source GitHub Issue when authenticated

## State Files

The bridge stores local state under:

```text
/var/lib/ai-council/github-bridge/imported
/var/lib/ai-council/github-bridge/posted
/var/log/ai-council/github-bridge
```

These files prevent duplicate job imports and duplicate result comments.

## Confirmation

The bridge is not confirmed until a GitHub Issue request produces:

- a queued job under `/var/lib/ai-council/jobs/queue`
- a completed job report under `/var/log/ai-council/jobs/latest-job-report.md`
- a GitHub Issue comment with `JOB_RUNNER_STATUS` and `REPO_CHECK_STATUS`

If `gh` is missing or not authenticated, the bridge reports `AUTH_REQUIRED` and does not touch secrets.

For smartphone confirmation, open the same Issue and check for a `VPS job result` comment containing `JOB_RUNNER_STATUS: OK` and the expected job-specific status such as `REPO_CHECK_STATUS: OK`.
