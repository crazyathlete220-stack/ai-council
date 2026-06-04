# VPS AI CLI Runner

## Purpose

The AI CLI runner is the first lane where repository work can actually run on the VPS instead of Tanabe-san's PC.

It lets a GitHub Issue create an `ai_exec` job. The job passes the request to an already-authenticated Codex CLI on the VPS, runs inside the registered workspace, and writes durable evidence under `/var/log/ai-council/ai-cli`.

This is still not an AI model host. The model runs through the external AI service used by the CLI. The local workload moved to the VPS is repository reading, file editing, command execution, and log generation.

## Boundary

- `ai_exec` may edit files in the registered VPS workspace.
- `ai_exec` does not run `git push`.
- `ai_exec` does not create a pull request.
- `ai_exec` does not create GitHub tokens, SSH private keys, API keys, passwords, or secrets.
- Free-form Issue text is passed to the AI CLI as a request, not executed as shell.
- The runner defaults to Codex CLI. Claude Code is checked by `ai_cli_status.sh`, but execution is not enabled in this phase.
- The default Codex model is `gpt-5.5`. Override `AI_COUNCIL_AI_MODEL` only when the target Codex account supports the requested model.
- GitHub Issue input is limited before the AI CLI starts.
- The AI CLI process is run with a timeout.
- Concurrent `ai_exec` jobs are blocked and back-to-back `ai_exec` jobs are rate-limited.

## Default Guardrails

The default safety limits are:

```text
AI_COUNCIL_AI_EXEC_MAX_ISSUE_BODY_BYTES=12000
AI_COUNCIL_AI_EXEC_TIMEOUT_SECONDS=900
AI_COUNCIL_AI_EXEC_MIN_INTERVAL_SECONDS=300
AI_COUNCIL_AI_EXEC_GUARD_ROOT=/var/lib/ai-council/ai-exec
```

Override these only as VPS-side environment variables. Do not commit secrets or account credentials into repository files.

Guardrail evidence appears in `/var/log/ai-council/ai-cli/latest-exec.md` as:

```text
Max Issue Body Bytes:
Issue Body Bytes:
Timeout Seconds:
Minimum Interval Seconds:
Guard Status:
```

Blocked `ai_exec` signals include:

```text
AI_EXEC_STATUS: INPUT_TOO_LARGE
AI_EXEC_STATUS: RATE_LIMITED
AI_EXEC_STATUS: TIMEOUT
AI_EXEC_STATUS: GUARD_UNAVAILABLE
```

## VPS Setup

Run from `/opt/ai-council` after the workspace is registered:

```bash
sudo bash scripts/setup_operator_user.sh
sudo bash scripts/setup_ai_cli_runner.sh ai-council
bash scripts/ai_cli_status.sh ai-council
```

`setup_ai_cli_runner.sh` creates AI CLI log/state directories and makes the registered workspace writable by the `ai-council` operator user.

Codex CLI authentication must be configured on the VPS for the `ai-council` user outside this repository. Do not put tokens or keys in repo files.

## Manual ai_exec Job

```bash
sudo bash scripts/create_job.sh ai_exec ai-council
sudo bash scripts/run_job_once.sh
sudo bash scripts/report_job_result.sh
```

A manual job without a GitHub Issue asks the CLI to inspect and report the next safe action without editing files.

## Smartphone ai_exec Job

Use the `VPS AI Exec` Issue form. It includes:

```text
JOB_TYPE=ai_exec
REPO_NAME=ai-council
```

The request body can be natural language. Keep secrets out of the Issue.

## Evidence

`ai_exec` writes:

```text
/var/log/ai-council/ai-cli/<JOB_ID>/prompt.md
/var/log/ai-council/ai-cli/<JOB_ID>/cli-output.log
/var/log/ai-council/ai-cli/<JOB_ID>/last-message.md
/var/log/ai-council/ai-cli/<JOB_ID>/exec.md
/var/log/ai-council/ai-cli/latest-exec.md
/var/log/ai-council/jobs/latest-job-report.md
```

Expected signals:

```text
AI_EXEC_STATUS: OK
JOB_RUNNER_STATUS: OK
```

If Codex CLI is missing or not authenticated for the `ai-council` user, the job reports:

```text
AI_EXEC_STATUS: CLI_MISSING
AI_EXEC_STATUS: AUTH_REQUIRED
```

## Review Local VPS Changes

After an `ai_exec` run:

```bash
cd /opt/ai-workspaces/ai-council
git status --short
git diff --stat
git diff
```

Do not push from the VPS until a separate PR-creation phase is reviewed.

## Recovery

```bash
bash /opt/ai-council/scripts/ai_cli_status.sh ai-council
sudo cat /var/log/ai-council/ai-cli/latest-exec.md
sudo cat /var/log/ai-council/jobs/latest-job-report.md
sudo journalctl -u ai-council-github-bridge.service -n 100 --no-pager
```

If the workspace is not writable by `ai-council`, rerun:

```bash
sudo bash /opt/ai-council/scripts/setup_ai_cli_runner.sh ai-council
```
