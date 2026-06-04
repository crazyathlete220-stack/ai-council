# VPS GitHub Bridge

## Purpose

The GitHub bridge connects smartphone-friendly GitHub Issues to the VPS job inbox.

This is still not an AI model migration. The VPS reads approved GitHub Issue requests, creates local jobs, runs the existing job runner, and can post a short result comment back to the Issue when GitHub CLI authentication is already configured on the VPS.

## Requirements

- `gh` is installed on the VPS.
- `gh auth status` succeeds on the VPS.
- The authenticated GitHub account can read Issues and write Issue comments for this repository.
- Issues use the `vps-job` label.
- The Issue author is listed in the VPS-side allowlist file.

This repository does not create GitHub tokens, SSH private keys, API keys, or secrets.

## GitHub Author Allowlist

The bridge is default-deny. It does not import any GitHub Issue until the VPS has an allowlist file:

```text
/etc/ai-council/github-bridge-allowlist
```

Create it on the VPS with one GitHub username per line:

```bash
sudo install -d -m 0755 /etc/ai-council
printf '%s\n' '<GITHUB_USERNAME>' | sudo tee /etc/ai-council/github-bridge-allowlist >/dev/null
sudo chmod 0644 /etc/ai-council/github-bridge-allowlist
```

Blank lines and `#` comments are ignored. The allowlist is not a secret, but it stays outside this repository so VPS operators can change authorized users without committing environment-specific state.

To use a different file, set this VPS-side environment variable for the bridge process:

```bash
AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE=/etc/ai-council/github-bridge-allowlist
```

When the allowlist file is missing, empty, or does not include the Issue author, the bridge refuses to create a job. Rejection evidence is written to:

```text
/var/log/ai-council/github-bridge/rejected-issues.log
/var/lib/ai-council/github-bridge/rejected/
```

Expected blocked signal:

```text
GITHUB_JOB_IMPORT_STATUS: ALLOWLIST_REQUIRED
```

## Issue Request Format

For smartphone use, create an Issue from the `VPS Codex Direct` form for one short Codex-only instruction, or the `VPS Free Request` form for planning-only natural-language requests. Both apply the `vps-job` label automatically.

Known short Japanese requests are classified into specific safe jobs:

```text
ai-councilの状態見て
作業場まとめて
ai-councilを検証して
```

If a labeled Issue has no explicit `JOB_TYPE` and does not match a known phrase, the bridge routes it to `ai_plan` as a safe planning fallback.

Use `VPS Job Mobile` when you want to edit the direct command:

```text
JOB_TYPE=repo_check
REPO_NAME=ai-council
```

The shorter mobile guide is [mobile-vps-jobs.md](mobile-vps-jobs.md).

Supported job types:

- `repo_check`
- `workspace_summary`
- `ai_plan`
- `ai_check`
- `ai_exec`

Supported casual phrases are intentionally mapped only to those job types. Phrases with `計画`, `方針`, `plan`, or `プラン` map to `ai_plan`. Phrases with `検証`, `安全確認して`, `安全確認を`, `チェックだけ`, `確認だけ`, or `check only` map to `ai_check`. Unclassified free text maps to `ai_plan` and is not executed as shell.

`ai_exec` is not selected by casual phrase matching. Use the `VPS Codex Direct`, `VPS Quick AI Exec`, or `VPS AI Exec` Issue form, or explicit `JOB_TYPE=ai_exec`, when the VPS should run the authenticated Codex CLI.

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

Use the helper script so ON/OFF state is visible:

```bash
bash /opt/ai-council/scripts/github_bridge_timer.sh status
sudo bash /opt/ai-council/scripts/github_bridge_timer.sh enable
sudo bash /opt/ai-council/scripts/github_bridge_timer.sh disable
```

Recommended mode while the system is still being tuned:

- keep the timer disabled when you do not want the VPS to pick up new Issues
- enable it when smartphone requests should run while the PC is closed
- check that `GITHUB_BRIDGE_TIMER_STATUS: ON` appears before relying on unattended pickup

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
