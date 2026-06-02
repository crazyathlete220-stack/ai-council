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
bash scripts/run_repo_check.sh <REPO_NAME>
```

If writing to `/var/log/ai-council/workspaces` is blocked, rerun with:

```bash
sudo bash scripts/run_repo_check.sh <REPO_NAME>
```

### npm Missing

If `package.json` exists and npm is missing, the report records an error. Install decisions remain manual; this phase does not run `npm install` or `npm ci`.

### build/test SKIP

If `lint`, `test`, or `build` scripts are absent from `package.json`, the repo check records `SKIP`. A skipped command is not a failure unless that repo is expected to provide the script.

### Aggregate Workspace Reports

```bash
bash scripts/report_workspaces.sh
sudo cat /var/log/ai-council/workspaces/latest-summary.md
```

If writing the summary is blocked, rerun the report command with `sudo`.

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
