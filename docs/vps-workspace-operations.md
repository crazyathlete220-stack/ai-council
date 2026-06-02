# VPS Workspace Operations

## Purpose

Use the VPS as an AI work area so build, test, repository checks, and log generation can move away from Tanabe-san's PC. This phase lowers PC-side workload for checks and evidence collection; it does not move AI model hosting to the VPS.

## Entry

- GitHub Issues that describe work to check
- GitHub PRs that need build, test, lint, or status evidence
- Tanabe-san's manual VPS commands
- A future job inbox for queued workspace tasks

## Read

Workspace operations read:

- VPS workspace directory: `/opt/ai-workspaces`
- repo registry files: `/etc/ai-council/workspaces.d/*.env`
- repo files such as `package.json`, `pyproject.toml`, and `requirements.txt`
- repo logs under `/var/log/ai-council/workspaces/`
- latest repo reports and run logs

## Execute

The Phase 2 workspace flow is:

1. Confirm the repo exists under `/opt/ai-workspaces`.
2. Register the repo with `scripts/register_workspace.sh`.
3. Detect dependency and command candidates from repo files.
4. Run available build, test, and lint commands manually through `scripts/run_repo_check.sh`.
5. Write the result to repo-specific logs.

This phase never runs `npm install` or `npm ci` automatically. Missing scripts are recorded as `SKIP`, not treated as a command failure.

## Evidence

Workspace evidence is stored under:

```text
/var/log/ai-council/workspaces/
```

Repo-specific evidence includes:

- `/var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md`
- `/var/log/ai-council/workspaces/<REPO_NAME>/runs/<timestamp>.log`
- command output captured in the run log
- `/var/log/ai-council/workspaces/latest-summary.md`

GitHub report template:

```md
## VPS workspace report

## Result
- REPO_CHECK_STATUS:
- WORKSPACE_SUMMARY_STATUS:

## Evidence
- latest-report.md:
- run log:
- latest-summary.md:

## Follow-up
- Missing dependency:
- Skipped command:
- Failed command:

## Unconfirmed
- VPS-side manual execution:
- GitHub posting:
- secrets configuration:
- AI model migration:
```

## Recovery

When a workspace command fails, check in this order:

1. Repo log: `/var/log/ai-council/workspaces/<REPO_NAME>/latest-report.md`
2. Run log: `/var/log/ai-council/workspaces/<REPO_NAME>/runs/`
3. Registry file: `/etc/ai-council/workspaces.d/<REPO_NAME>.env`
4. Repo path: `/opt/ai-workspaces/<REPO_NAME>`
5. Working tree state: `git status --short`
6. Dependency availability: `command -v npm` or `command -v python3`

Retry with:

```bash
bash scripts/workspace_status.sh
bash scripts/run_repo_check.sh <REPO_NAME>
bash scripts/report_workspaces.sh
```

If repo placement is wrong, re-place or re-register that repo only. Do not delete workspace roots as part of the normal recovery path.

## Visibility

Tanabe-san can keep editing video on the PC while checking:

- GitHub Issues and PRs
- VPS workspace logs
- `scripts/workspace_status.sh` output
- `latest-report.md` for each repo
- `latest-summary.md` across registered workspaces

## Notes

- This phase does not host ChatGPT, Claude, Codex, or other AI model services on the VPS.
- The VPS is a work area, execution area, and evidence area.
- Treat workspace operation as unconfirmed until a VPS-side run writes a repo report under `/var/log/ai-council/workspaces/`.
- GitHub posting and credentials automation remain out of scope.
