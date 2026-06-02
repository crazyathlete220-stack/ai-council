# VPS Phase 2 Workspace Setup

## Purpose

Create `/opt/ai-workspaces` and `/var/log/ai-council/workspaces` on the VPS so each repo can run build, test, lint, and check commands with logs.

## Prerequisites

- Phase 1 healthcheck completion is preferred.
- At PR creation time, VPS-side execution is unconfirmed.
- Do not write GitHub tokens, SSH private keys, API keys, passwords, IP addresses, or personal usernames into this repository.
- For private repos, start with a Mac-side ZIP download or manual file copy route.
- Future GitHub SSH deploy keys or GitHub App access should be considered in Phase 3 or later.
- This phase is workspace migration for checks and evidence, not AI model migration.

## First Target Repo Examples

- `crazyathlete220-stack/ai-council`
- `your-org/your-private-workspace-repo`

This issue does not clone or copy those repos. It prepares the scripts and manual steps only.

## Manual Placement Route

Mac-side example:

```bash
cd ~/Downloads
unzip <REPO_ZIP>.zip
scp -r <UNZIPPED_REPO_DIR> <SSH_USER>@<VPS_IP>:/tmp/<REPO_NAME>
```

VPS-side example:

```bash
ssh <SSH_USER>@<VPS_IP>
sudo mkdir -p /opt/ai-workspaces
sudo mkdir -p /var/log/ai-council/workspaces
sudo mv /tmp/<REPO_NAME> /opt/ai-workspaces/<REPO_NAME>
```

Codex does not run these commands in this phase.

## Initialization Commands

Run these manually from this repository directory on the VPS:

```bash
sudo bash scripts/setup_workspaces.sh
sudo bash scripts/register_workspace.sh <REPO_NAME> /opt/ai-workspaces/<REPO_NAME>
bash scripts/workspace_status.sh
bash scripts/run_repo_check.sh <REPO_NAME>
bash scripts/report_workspaces.sh
```

If writing under `/var/log/ai-council/workspaces` is blocked, rerun the repo check or summary command with `sudo`.

## Success Conditions

- `/opt/ai-workspaces` exists.
- `/var/log/ai-council/workspaces` exists.
- The repo-specific log directory exists.
- `scripts/run_repo_check.sh <REPO_NAME>` can run.
- `/var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md` is generated.
- The report ends with `REPO_CHECK_STATUS: OK` or `REPO_CHECK_STATUS: ERROR`.
- `scripts/workspace_status.sh` ends with `WORKSPACE_REGISTRY_STATUS: OK` or `WORKSPACE_REGISTRY_STATUS: ERROR`.

## Failure Checks

### Repo Is Not Found

Look at:

```bash
bash scripts/workspace_status.sh
sudo cat /etc/ai-council/workspaces.d/<REPO_NAME>.env
sudo ls -la /opt/ai-workspaces
```

Then re-register the repo path:

```bash
sudo bash scripts/register_workspace.sh <REPO_NAME> /opt/ai-workspaces/<REPO_NAME>
```

### package.json Is Missing

Look at:

```bash
ls -la /opt/ai-workspaces/<REPO_NAME>
```

This is not always an error. It means Node.js package checks are skipped for that repo.

### npm Is Missing

Look at the latest report:

```bash
sudo cat /var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md
```

If `package.json` exists and npm is missing, install decisions stay manual. This phase does not run `npm install` or `npm ci`.

### build Script Is Missing

Look at:

```bash
cd /opt/ai-workspaces/<REPO_NAME>
npm run
```

Missing `build` is recorded as `SKIP` and is not a failure by itself.

### test Script Is Missing

Look at:

```bash
cd /opt/ai-workspaces/<REPO_NAME>
npm run
```

Missing `test` is recorded as `SKIP` and is not a failure by itself.

### Permission Error

Look at:

```bash
ls -ld /opt/ai-workspaces
sudo ls -ld /var/log/ai-council/workspaces
sudo ls -ld /etc/ai-council/workspaces.d
```

Then rerun the blocked command with `sudo`.

### Working Tree Is Dirty

Look at:

```bash
cd /opt/ai-workspaces/<REPO_NAME>
git status --short
```

Record the dirty state in the PR or Issue before rerunning checks. Do not run `git pull` or `git push` as part of this phase.

### Logs Are Not Generated

Look at:

```bash
sudo ls -la /var/log/ai-council/workspaces/<REPO_NAME>
sudo ls -la /var/log/ai-council/workspaces/<REPO_NAME>/runs
```

Then rerun:

```bash
sudo bash scripts/run_repo_check.sh <REPO_NAME>
sudo bash scripts/report_workspaces.sh
```

## Report Template

```md
## VPS Phase 2 workspace report

## Result
- WORKSPACE_REGISTRY_STATUS:
- REPO_CHECK_STATUS:
- WORKSPACE_SUMMARY_STATUS:

## Evidence
- latest-report.md:
- run log:
- latest-summary.md:

## Skips
- lint:
- test:
- build:
- Python pytest candidate:

## Unconfirmed
- VPS-side manual execution:
- GitHub posting:
- secrets configuration:
- AI model migration:
```
