# Runbook

## Check The systemd Timer

```bash
sudo systemctl status ai-council-healthcheck.timer
sudo systemctl list-timers ai-council-healthcheck.timer
```

Expected result: the timer is loaded, active, and has a next run time.

## Check journalctl

```bash
sudo journalctl -u ai-council-healthcheck.service -n 100 --no-pager
sudo journalctl -u ai-council-healthcheck.timer -n 100 --no-pager
```

Look for the latest start time, exit status, and script error messages.

## Check Log Files

```bash
sudo ls -la /var/log/ai-council
sudo cat /var/log/ai-council/latest-report.md
```

Expected result: `latest-report.md` exists and contains either `STATUS: OK` or `STATUS: ERROR`.

## Run Manually

```bash
sudo /opt/ai-council/scripts/healthcheck.sh
sudo /opt/ai-council/scripts/report_status.sh
sudo systemctl start ai-council-healthcheck.service
```

After manual execution, check the report timestamp:

```bash
sudo grep -E "Generated At|Last Successful Run|STATUS:" /var/log/ai-council/latest-report.md
```

## Phase 2 Workspace Recovery

### Check Workspace List

```bash
bash scripts/workspace_status.sh
```

Expected result: registered repos are listed and the command ends with `WORKSPACE_REGISTRY_STATUS: OK` or a readable `ERROR`.

### Check Repo Registration

```bash
sudo ls -la /etc/ai-council/workspaces.d
sudo cat /etc/ai-council/workspaces.d/<REPO_NAME>.env
```

Confirm `REPO_NAME`, `REPO_PATH`, and `LOG_DIR` point to the intended repo and log directory.

### Check Repo Path

```bash
ls -la /opt/ai-workspaces/<REPO_NAME>
cd /opt/ai-workspaces/<REPO_NAME>
git status --short
```

A dirty working tree is recorded as an error in `run_repo_check.sh` so the PR or Issue can see the exact state.

### Check Latest Report

```bash
sudo cat /var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md
```

Look for `REPO_CHECK_STATUS: OK` or `REPO_CHECK_STATUS: ERROR`.

### Check Run Logs

```bash
sudo ls -la /var/log/ai-council/workspaces/<REPO_NAME>/runs
sudo tail -n 80 /var/log/ai-council/workspaces/<REPO_NAME>/runs/<timestamp>.log
```

Run logs contain the command output that produced the latest report.

### Rerun Repo Check Manually

```bash
sudo bash scripts/run_repo_check.sh <REPO_NAME>
```

Use `sudo` because the repo check writes under `/var/log/ai-council/workspaces`.

### npm Missing

If `package.json` exists and npm is missing, the report records an error. Install decisions remain manual; this phase does not run `npm install` or `npm ci`.

### build/test SKIP

If `lint`, `test`, or `build` scripts are absent from `package.json`, the repo check records `SKIP`. A skipped command is not a failure unless that repo is expected to provide the script.

### Aggregate Workspace Reports

```bash
sudo bash scripts/report_workspaces.sh
sudo cat /var/log/ai-council/workspaces/latest-summary.md
```

Use `sudo` because the summary writes to `/var/log/ai-council/workspaces/latest-summary.md`.

## Phase 3 Operator And Job Inbox Recovery

### Check Job Inbox

```bash
bash scripts/job_status.sh
sudo ls -la /var/lib/ai-council/jobs/queue
sudo ls -la /var/lib/ai-council/jobs/active
sudo ls -la /var/lib/ai-council/jobs/done
sudo ls -la /var/lib/ai-council/jobs/failed
```

Expected result: the command ends with `JOB_INBOX_STATUS: OK`, and only one job is in `active` at a time.

### Create A Manual Job

```bash
bash scripts/create_job.sh repo_check <REPO_NAME>
```

If the queue directory is not writable by the current user, run the same command with `sudo`.

### Run One Job Manually

```bash
sudo bash scripts/run_job_once.sh
```

Expected result: the command ends with `JOB_RUNNER_STATUS: OK`, `JOB_RUNNER_STATUS: ERROR`, or `JOB_RUNNER_STATUS: IDLE`.

### Check Job Evidence

```bash
sudo cat /var/log/ai-council/jobs/latest-job-report.md
sudo bash scripts/report_job_result.sh
sudo cat /var/log/ai-council/jobs/latest-summary.md
```

Record the latest job ID, status, and log path in the GitHub Issue or PR before retrying a failed job.

### Check Job Timer

```bash
sudo systemctl status ai-council-job-runner.timer
sudo systemctl list-timers ai-council-job-runner.timer
sudo journalctl -u ai-council-job-runner.service -n 100 --no-pager
```

The job timer is enabled manually after review:

```bash
sudo systemctl enable --now ai-council-job-runner.timer
```

### Smartphone Request Recovery

If a smartphone request is missing, check:

- the requester used the `VPS Job Casual` or `VPS Job Mobile` Issue form
- GitHub Issues with the `vps-job` label from a browser or authenticated local machine
- the Issue body includes a supported casual phrase such as `ai-councilの状態見て` or direct `JOB_TYPE=repo_check` and `REPO_NAME=ai-council`
- the Issue has no passwords, tokens, SSH private keys, API keys, or other secrets
- `bash scripts/job_status.sh` on the VPS

If the GitHub bridge is not configured yet, convert approved GitHub requests into local jobs with `scripts/create_job.sh`.

The mobile confirmation path is the Issue comment titled `VPS job result`. A healthy repository check includes `REPO_CHECK_STATUS: OK` and `JOB_RUNNER_STATUS: OK`.

## GitHub Bridge Recovery

### Check GitHub CLI

```bash
command -v gh
gh auth status --hostname github.com
```

If either command fails, the bridge reports `AUTH_REQUIRED`. Configure GitHub authentication outside this repository.

### Import GitHub Jobs

```bash
sudo bash scripts/import_github_jobs.sh
```

Expected result: `GITHUB_JOB_IMPORT_STATUS: OK`, `NO_MATCHING_ISSUES`, or `AUTH_REQUIRED`.

### Post Latest Job Result

```bash
sudo bash scripts/post_job_result_to_github.sh
```

Expected result: `GITHUB_JOB_POST_STATUS: OK`, `ALREADY_POSTED`, `NO_ISSUE_SOURCE`, `NO_REPORT`, or `AUTH_REQUIRED`.

### Check Bridge State

```bash
sudo ls -la /var/lib/ai-council/github-bridge/imported
sudo ls -la /var/lib/ai-council/github-bridge/posted
sudo journalctl -u ai-council-github-bridge.service -n 100 --no-pager
```

### Check Bridge Timer

```bash
sudo systemctl status ai-council-github-bridge.timer
sudo systemctl list-timers ai-council-github-bridge.timer
```

The bridge timer is enabled manually after `gh auth status` succeeds:

```bash
sudo systemctl enable --now ai-council-github-bridge.timer
```

## AI Worker Plan Recovery

### Create A Manual Plan Job

```bash
bash /opt/ai-council/scripts/create_job.sh ai_plan ai-council
sudo bash /opt/ai-council/scripts/run_job_once.sh
sudo bash /opt/ai-council/scripts/report_job_result.sh
```

Expected result:

```text
AI_PLAN_STATUS: OK
JOB_RUNNER_STATUS: OK
```

### Check AI Plan Evidence

```bash
sudo cat /var/log/ai-council/ai-worker/latest-plan.md
sudo grep -E "AI_PLAN_STATUS|JOB_RUNNER_STATUS|Plan File|Latest Plan" /var/log/ai-council/jobs/latest-job-report.md
```

`ai_plan` is planning only. It does not edit files, run build/test/install commands, push branches, or create PRs.

## GitHub Report Template

```md
## VPS healthcheck report

## Result
- STATUS:
- Checked at:

## Evidence
- latest-report.md:
- journalctl:
- timer status:

## Recovery action
- Action taken:
- Result:

## Unconfirmed
- VPS environment details:
- GitHub posting:
- secrets configuration:
```
