# Mobile VPS Jobs

## Purpose

Use this guide to send a simple VPS job from a smartphone while the PC is closed.

The current mobile flow is:

1. create a GitHub Issue
2. let the VPS import the Issue as a queued job
3. let the VPS run the job
4. read the result comment on the same Issue

This is a VPS workspace/job flow. It is not an AI model migration to the VPS.

## Send A Request From A Smartphone

Open GitHub on the smartphone, then:

1. open `crazyathlete220-stack/ai-council`
2. open `Issues`
3. tap `New issue`
4. choose `VPS Free Request` for natural-language planning, `VPS AI Exec` for actual VPS AI CLI work, or `VPS Job Casual` for a known short request
5. write the request naturally, such as `PCを閉じているので、次に安全に進める作業を整理して`
6. submit the Issue

When the bridge can classify the request, it turns known phrases into safe VPS jobs. For example:

```text
ai-councilの状態見て
```

into the safe VPS job:

```text
JOB_TYPE=repo_check
REPO_NAME=ai-council
```

If the bridge cannot classify the free text, it routes the request to:

```text
JOB_TYPE=ai_plan
REPO_NAME=ai-council
```

This fallback creates planning evidence only. It does not execute the free-form text as shell.

Use `VPS AI Exec` when the VPS should run the authenticated AI CLI and may edit files in the registered workspace. This route does not run `git push`, create PRs, or create secrets.

The Issue template applies the `vps-job` label automatically. The bridge only imports Issues with that label.

The bridge also checks the VPS-side GitHub author allowlist. Your GitHub username must be listed in `/etc/ai-council/github-bridge-allowlist` on the VPS, otherwise the Issue is not converted into a job.

Use `VPS Job Mobile` instead when you want to edit `JOB_TYPE` and `REPO_NAME` directly.

## Confirm The Result

Open the same Issue after a few minutes and look for a comment titled:

```text
VPS job result
```

The result is healthy when the comment includes:

```text
REPO_CHECK_STATUS: OK
JOB_RUNNER_STATUS: OK
```

For the normal `ai-council` check, the comment should also show:

```text
Repo Name: ai-council
Repo Path: /opt/ai-workspaces/ai-council
```

## Other Supported Request

Casual planning examples:

```text
ai-councilの作業計画を立てて
次の方針を出して
```

Direct plan command:

```text
JOB_TYPE=ai_plan
REPO_NAME=ai-council
```

Free-form examples that safely fall back to planning:

```text
PCを閉じているので、次に安全に進める作業を整理して
このあとどう進めればいいかVPS側で考えて
スマホから雑に投げるので、まず方針だけ出して
```

Casual bounded check examples:

```text
ai-councilを検証して
ai-councilをチェックだけして
PCを閉じているので安全確認して
```

Direct bounded check command:

```text
JOB_TYPE=ai_check
REPO_NAME=ai-council
```

Direct AI CLI execution command:

```text
JOB_TYPE=ai_exec
REPO_NAME=ai-council
```

Casual workspace summary examples:

```text
作業場まとめて
ワークスペース一覧見て
```

Direct command:

```text
JOB_TYPE=workspace_summary
REPO_NAME=all
```

Create one Issue per job. To run the same job again, create a new Issue.

## If No Comment Appears

Wait up to ten minutes, then check the Issue:

- label includes `vps-job`
- your GitHub username is listed in `/etc/ai-council/github-bridge-allowlist` on the VPS
- request says `ai-councilの状態見て`, `ai-councilをチェックして`, `ai-councilを検証して`, `作業場まとめて`, uses direct `JOB_TYPE` lines, uses `VPS AI Exec`, or uses a free-form planning request
- no passwords, tokens, SSH private keys, API keys, or other secrets were included

If the Issue still has no result comment, check the VPS:

```bash
systemctl status ai-council-github-bridge.timer
sudo journalctl -u ai-council-github-bridge.service -n 100 --no-pager
sudo tail -n 50 /var/log/ai-council/github-bridge/rejected-issues.log
bash /opt/ai-council/scripts/job_status.sh
```

## Safety Rules

- Do not include passwords, tokens, SSH private keys, API keys, or other secrets.
- Do not request arbitrary shell commands.
- Do not request `git pull`, `git push`, `npm install`, or `npm ci`.
- Do not close existing Issues as part of a job request.
- Free-form requests are planning-first unless they match a known safe job type.
- Use `VPS AI Exec` only when the VPS should actually run the authenticated AI CLI in the workspace.
- For `VPS AI Exec`, keep the request short enough for one bounded job. The defaults reject Issue bodies over 12000 bytes, stop the AI CLI after 900 seconds, block concurrent `ai_exec` runs, and rate-limit back-to-back `ai_exec` runs for 300 seconds.
