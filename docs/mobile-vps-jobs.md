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
4. choose `VPS Job Mobile`
5. leave the default command unchanged for the normal check
6. submit the Issue

Default command:

```text
JOB_TYPE=repo_check
REPO_NAME=ai-council
```

The Issue template applies the `vps-job` label automatically. The bridge only imports Issues with that label.

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

Workspace summary:

```text
JOB_TYPE=workspace_summary
REPO_NAME=all
```

Create one Issue per job. To run the same job again, create a new Issue.

## If No Comment Appears

Wait up to ten minutes, then check the Issue:

- label includes `vps-job`
- command includes `JOB_TYPE=repo_check`
- command includes `REPO_NAME=ai-council`
- no passwords, tokens, SSH private keys, API keys, or other secrets were included

If the Issue still has no result comment, check the VPS:

```bash
systemctl status ai-council-github-bridge.timer
sudo journalctl -u ai-council-github-bridge.service -n 100 --no-pager
bash /opt/ai-council/scripts/job_status.sh
```

## Safety Rules

- Do not include passwords, tokens, SSH private keys, API keys, or other secrets.
- Do not request arbitrary shell commands.
- Do not request `git pull`, `git push`, `npm install`, or `npm ci`.
- Do not close existing Issues as part of a job request.
