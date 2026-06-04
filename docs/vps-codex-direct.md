# VPS Codex Direct

## Purpose

VPS Codex Direct is the simple lane for sending instructions to Codex only.

It is separate from the broader AI Council meeting-room concept. Use this lane when Tanabe-san wants to ask one concrete task from a smartphone or another external device without starting a multi-agent discussion.

This is still not an AI model migration. The VPS runs Codex CLI and calls the external AI service.

## When To Use

Use `VPS Codex Direct` for:

- one short repository inspection
- one bounded documentation or script edit
- one verification request
- one next-step recommendation

Use `VPS Free Request` instead when you only want planning evidence and no file edits.

Do not use this lane for:

- AI会議室 style multi-agent discussion
- Claude Code execution
- `git push`
- PR creation
- dependency installation
- secrets, tokens, SSH keys, API keys, or passwords

## Smartphone Flow

1. Open GitHub from the smartphone.
2. Open `crazyathlete220-stack/ai-council`.
3. Open `Issues`.
4. Tap `New issue`.
5. Choose `VPS Codex Direct`.
6. Write one short instruction.
7. Submit the Issue.
8. Wait for the `VPS job result` comment.

The form creates:

```text
JOB_TYPE=ai_exec
REPO_NAME=ai-council
```

The bridge imports it only when:

- the Issue has the `vps-job` label
- the GitHub author is listed in `/etc/ai-council/github-bridge-allowlist`
- the request passes the `ai_exec` guardrails

## Budget Guardrails

Default Codex Direct execution limits:

```text
AI_COUNCIL_AI_EXEC_ALLOWED_HOURS_JST=10-21
AI_COUNCIL_AI_EXEC_MAX_PER_HOUR=1
AI_COUNCIL_AI_EXEC_MAX_PER_DAY=5
AI_COUNCIL_AI_EXEC_TIMEOUT_SECONDS=900
AI_COUNCIL_AI_EXEC_MIN_INTERVAL_SECONDS=300
AI_COUNCIL_AI_EXEC_MAX_ISSUE_BODY_BYTES=12000
```

`10-21` means Codex Direct can start from 10:00 through 21:59 JST. At 22:00 JST and later, the job is refused before Codex CLI starts.

These limits are indirect cost controls. They limit when and how often Codex CLI can run, but they do not measure exact token usage.

## Good Request Examples

```text
READMEを確認して、スマホからの依頼入口が分かりやすいかだけ報告して。編集はしないで。
```

```text
scripts/*.sh のbash構文を確認して、結果だけ報告して。
```

```text
docs/vps-github-bridge.mdを読んで、timerをONにすべきかOFFにすべきか判断材料を3つ出して。
```

```text
READMEのCodex Direct案内だけを短く分かりやすく直して、bash -n scripts/*.sh まで確認して。
```

## Expected Result

The Issue should receive a comment containing:

```text
VPS job result
AI_EXEC_STATUS: OK
JOB_RUNNER_STATUS: OK
```

Expected guardrail refusal signals:

```text
AI_EXEC_STATUS: OUT_OF_HOURS
AI_EXEC_STATUS: HOURLY_LIMIT
AI_EXEC_STATUS: DAILY_LIMIT
```

If no comment appears after ten minutes, check:

```bash
bash /opt/ai-council/scripts/github_bridge_timer.sh status
sudo journalctl -u ai-council-github-bridge.service -n 100 --no-pager
sudo tail -n 50 /var/log/ai-council/github-bridge/rejected-issues.log
bash /opt/ai-council/scripts/job_status.sh
```

## Boundary

- Codex Direct uses the existing `ai_exec` runner.
- Codex Direct may edit files in the registered VPS workspace when the request asks for edits.
- Codex Direct does not run `git push`.
- Codex Direct does not create PRs.
- Codex Direct does not install dependencies unless a future reviewed phase explicitly allows it.
- Codex Direct does not run Claude Code.
- Codex Direct is not an AI model host.
