# VPS GitHub Bridge Recovery

## Purpose

Restore the full path:

```text
GitHub Issue
→ vps-job label
→ GitHub bridge
→ imported marker
→ queue
→ Runner
→ job-specific report
→ GitHub result comment
```

A created Issue, an applied label, or an enabled timer is not sufficient evidence of recovery. Recovery is complete only when a probe Issue receives both a `VPS_STATE: QUEUED` comment and a terminal VPS job result.

## Known failure classes

### 1. Entry Issue has no `vps-job` label

The importer reads only open Issues carrying the configured dispatch label. An unlabeled Issue is invisible to the VPS.

Evidence:

- GitHub Issue label list
- GitHub Actions `DISPATCH_READY` comment when the private orchestrator workflow is installed

Recovery:

- add `vps-job`
- do not add the project execution label until its target workspace is ready

### 2. VPS or SSH endpoint is unavailable

Signals:

- TCP port 22 refuses or times out
- no bridge result is returned even for a correctly labeled `ai_check`
- provider console reports the VPS stopped or isolated

Recovery begins in the VPS provider console. Starting a VPS in the provider UI is separate from enabling the AI Council timers.

### 3. Bridge timer was intentionally stopped and never re-enabled

Check:

```bash
systemctl is-enabled ai-council-github-bridge.timer
systemctl is-active ai-council-github-bridge.timer
systemctl list-timers ai-council-github-bridge.timer --all
```

Expected:

```text
enabled
active
```

### 4. Root GitHub CLI authentication or allowlist is unavailable

Check without printing credentials:

```bash
gh auth status --hostname github.com
test -r /etc/ai-council/github-bridge-allowlist
```

Evidence and rejection logs:

```text
/var/log/ai-council/github-bridge/rejected-issues.log
/var/lib/ai-council/github-bridge/rejected/
```

Do not print tokens, passwords, private keys, or credential files into an Issue or log.

### 5. Workspace is missing or unregistered

Check:

```bash
bash /opt/ai-council/scripts/workspace_status.sh
test -d /opt/ai-workspaces/ai-council-private/.git
test -r /etc/ai-council/workspaces.d/ai-council-private.env
```

A registry file without a real Git checkout is not a working workspace.

### 6. Codex CLI or Linux sandbox is unavailable

Check:

```bash
bash /opt/ai-council/scripts/ai_cli_status.sh ai-council-private
command -v bwrap
```

Prior Linux sandbox failures must not be treated as repaired merely because a package was installed. A bounded `ai_exec` probe must create the expected evidence and return a terminal result.

### 7. A failed result cannot reach GitHub

Current recovery design stores job reports under:

```text
/var/log/ai-council/jobs/reports/
/var/log/ai-council/jobs/pending-posts/
```

A GitHub authentication or network outage leaves the report in `pending-posts`. New work is blocked until pending reports are delivered, preventing invisible execution and result overwrite.

### 8. Rate limit or execution window blocks `ai_exec`

The following statuses are transient and are deferred rather than permanently discarded:

```text
OUT_OF_HOURS
RATE_LIMITED
HOURLY_LIMIT
DAILY_LIMIT
```

Deferred jobs are stored under:

```text
/var/lib/ai-council/jobs/deferred/
```

The source Issue receives one deferred-state report. A later terminal result uses a separate posting marker.

### 9. A crash leaves a job under `active`

Jobs older than the stale threshold are moved to `failed` and reported to the source Issue. They are not automatically executed again because the previous process may have made partial changes.

After reviewing the job log, use:

```bash
sudo bash /opt/ai-council/scripts/requeue_github_issue.sh <ISSUE_NUMBER>
```

### 10. Bridge and Runner timers overlap

Both timer paths use the same `flock` lock. This serializes execution and prevents two workers from processing or posting the same global state concurrently.

## One-command recovery

Run from a fresh, reviewed checkout of this repository. Do not overwrite a VPS workspace that contains unpushed local commits.

For bridge/timer recovery only:

```bash
sudo bash scripts/recover_github_bridge.sh
```

For bridge recovery plus private workspace placement/registration through an already authenticated root `gh` session:

```bash
sudo bash scripts/recover_github_bridge.sh \
  ai-council-private \
  crazyathlete220-stack/ai-council-private
```

The script:

1. installs the current runtime scripts and systemd units
2. validates shell syntax
3. checks `gh auth` without exposing credentials
4. checks the author allowlist
5. creates queue, deferred, report, and pending-post directories
6. optionally places and registers the target workspace
7. reloads systemd
8. enables the bridge and Runner timers
9. runs one bridge cycle
10. reports exact evidence paths

## Non-destructive boundaries

The recovery script must not:

- delete existing workspaces
- reset Git history
- discard local commits or uncommitted files
- print credentials
- replace interactive authentication
- claim success when the probe Issue has no VPS result

## Required evidence after recovery

### Entry

- source Issue has `vps-job`
- private auto-label workflow, when installed, has a successful run

### Read

- source Issue receives `VPS_STATE: QUEUED`
- `/var/lib/ai-council/github-bridge/imported/issue-<N>.imported` exists

### Execute

- queue job moves to `done`, `failed`, or `deferred`
- `JOB_RUNNER_STATUS` is recorded

### Evidence

- job-specific report under `/var/log/ai-council/jobs/reports/`
- terminal or deferred GitHub comment
- commit SHA when the job changes a repository

### Recovery

- `latest-cycle.log`
- service journal
- rejected Issue log
- pending result directory
- requeue command

### Operator visibility

The source Issue alone must show one of:

```text
QUEUED
DEFERRED
SUCCESS
ERROR/BLOCKED
```

## First locations to inspect

```bash
systemctl status ai-council-github-bridge.timer --no-pager
systemctl status ai-council-github-bridge.service --no-pager
systemctl status ai-council-job-runner.timer --no-pager
systemctl status ai-council-job-runner.service --no-pager
journalctl -u ai-council-github-bridge.service -n 200 --no-pager
journalctl -u ai-council-job-runner.service -n 200 --no-pager
cat /var/log/ai-council/github-bridge/latest-cycle.log
bash /opt/ai-council/scripts/job_status.sh
bash /opt/ai-council/scripts/workspace_status.sh
```

## Completion gate

Infrastructure recovery is `SUCCESS` only when all of the following are true:

- bridge timer enabled and active
- Runner timer enabled and active
- root `gh auth` valid
- allowlist valid
- target workspace valid
- probe Issue imported
- queue evidence posted
- Runner result posted
- no undelivered report remains in `pending-posts`

Project recovery is a separate gate: Issue #91 must then create `programs.csv`, `shortlist.md`, a commit, and a final result comment.
