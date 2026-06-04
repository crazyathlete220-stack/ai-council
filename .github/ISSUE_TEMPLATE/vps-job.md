---
name: VPS Job Request
about: Request a VPS workspace job from a PC or smartphone
title: "[VPS Job] "
labels: vps-job
---

## Request

```text
JOB_TYPE=repo_check
REPO_NAME=ai-council
REQUEST_SOURCE=github_issue
REQUESTED_BY=
```

Supported `JOB_TYPE` values:

- `repo_check`
- `workspace_summary`
- `ai_plan`
- `ai_check`
- `ai_exec`

## Purpose

What should the VPS check?

## Evidence Target

Where should the result be reported after `/var/log/ai-council/jobs/latest-job-report.md` is generated?

## Safety

- Do not include passwords, tokens, SSH private keys, API keys, or other secrets.
- Do not request arbitrary shell commands.
- Do not request `git pull`, `git push`, `npm install`, or `npm ci`.
- Use `JOB_TYPE=ai_exec` only when the VPS should run the authenticated AI CLI inside the registered workspace.
