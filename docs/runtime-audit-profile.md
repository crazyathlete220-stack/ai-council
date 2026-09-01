# Runtime Audit Profile

## Purpose

`ai_check` remains a bounded, read-only check. Free-form Issue text is never executed as shell.

When an owner-created Issue contains the exact metadata line:

```text
AUDIT_PROFILE=runtime
```

`run_ai_check.sh` executes the normal generic check and then calls the fixed, allowlisted `run_runtime_audit.sh` probes.

## Supported metadata

```text
AUDIT_PROFILE=runtime
AUDIT_REPO=ai-council-private
AUDIT_ISSUES=91,98,101
AUDIT_EXPECTED_RUNTIME_COMMIT=2ed27b67ff01edbbd5ec1fd6504dcd6c74309bd5
AUDIT_EXPECTED_PRIVATE_COMMIT=d8c5001215994ca9172121f9c17b210b970ad092
```

Validation:

- `AUDIT_PROFILE` must equal `runtime`.
- `AUDIT_REPO` accepts only letters, digits, `.`, `_`, and `-`.
- `AUDIT_ISSUES` accepts comma-separated numeric IDs only.
- expected commits accept 7–40 hexadecimal characters.
- unsupported or malformed values fail the check; they are not interpreted as commands.

Environment variables with the same names prefixed by `AI_COUNCIL_` are available for direct operator tests.

## Read-only probes

The runtime profile reports:

- current user and non-interactive sudo availability
- GitHub CLI authentication success/failure without token values
- `/opt/ai-council` and public workspace paths, Git heads, and relation
- required runtime file presence and source/runtime file equality
- expected commit relation using only locally available Git objects
- systemd service `ExecStart`, service state, timer active/enabled state
- bridge import-only vs legacy combined mode
- runner durable-cycle vs legacy single-run mode
- private workspace config, path, Git validity, head, and origin presence
- queue/active/done/failed counts
- imported/blocked/rejected/posted marker counts
- requested Issue marker/job state
- stash count and stash refs only; stash content and subjects are not shown
- recent error-pattern count and latest timestamp only; full journal lines are not posted

The profile does not:

- edit files
- fetch/pull/switch/reset/clean/stash/pop/commit/push
- start, stop, restart, enable, or disable systemd units
- clone repositories
- register workspaces
- install packages
- print credentials, remote URLs, token values, or private key contents
- execute Issue body text

## Output boundary

The wrapper encloses the generated audit in:

```text
RUNTIME_AUDIT_OUTPUT_BEGIN
...
RUNTIME_AUDIT_OUTPUT_END
```

`extract_job_signals.sh` posts only allowlisted keys inside that boundary. Similar-looking lines elsewhere in the Issue snapshot or job log are ignored.

Important high-level fields:

```text
MERGED_RUNTIME_PRESENT: YES / NO / PARTIAL / UNKNOWN
BRIDGE_RUNTIME_MODE: IMPORT_ONLY / LEGACY_COMBINED / UNKNOWN
RUNNER_RUNTIME_MODE: DURABLE_CYCLE / LEGACY_ONCE / UNKNOWN
PRIVATE_CONFIG: EXISTS / MISSING / UNREADABLE
PRIVATE_WORKSPACE: OK / MISSING / INVALID_GIT
RUNTIME_AUDIT_FINDINGS: n
RUNTIME_AUDIT_UNKNOWNS: n
RUNTIME_RECOVERY_STATUS: READY / BLOCKED_...
RUNTIME_AUDIT_STATUS: COMPLETE / ERROR
```

`RUNTIME_AUDIT_STATUS: COMPLETE` means the fixed probes ran. It does not mean the runtime is healthy. Health/recovery is expressed by `RUNTIME_RECOVERY_STATUS` and the individual fields.

## Entry

Create an owner-authored Issue in the control repository with:

```text
JOB_TYPE=ai_check
REPO_NAME=ai-council
AUDIT_PROFILE=runtime
AUDIT_REPO=ai-council-private
AUDIT_ISSUES=91,98,101
```

The Issue must have the configured bridge label.

## Reading

Evidence of reading requires both:

- `STATE: QUEUED` with a concrete Job ID
- a per-job report associated with the same Issue

`DISPATCH_READY` alone proves only label eligibility.

## Execution

A complete audit job runs:

1. generic bounded `ai_check`
2. metadata validation
3. fixed runtime audit probes
4. per-job report creation
5. trusted signal extraction
6. GitHub result comment

## Evidence

Expected locations after the durable runtime is deployed:

- per-job report: `/var/log/ai-council/jobs/reports/<JOB_ID>.md`
- check artifact: `/var/log/ai-council/ai-worker/<JOB_ID>/check.md`
- summary: `/var/log/ai-council/jobs/summaries/<JOB_ID>.md`
- GitHub result comment on the source Issue

## Recovery

Typical next actions are selected but never executed by the audit:

- `BLOCKED_RUNTIME_DEPLOY`: update the reviewed public workspace and run `deploy_runtime.sh` as root
- `BLOCKED_PRIVATE_WORKSPACE`: place the private repository through an approved credential path, register it, and requeue the target Issue
- `BLOCKED_GITHUB_AUTH`: repair `gh` authentication without exposing the token
- `BLOCKED_TIMERS`: inspect unit state and journals before changing systemd
- `READY_WITH_STALE_JOBS`: inspect failed/blocked items and requeue only validated targets
- `READY`: run a fresh bounded E2E test

## Visibility

The source Issue should show:

```text
DISPATCH_READY
STATE: QUEUED
VPS job result
RUNTIME_RECOVERY_STATUS
RUNTIME_AUDIT_STATUS
JOB_RUNNER_STATUS
per-job report path
```

The audit profile is not complete merely because the metadata was added to an Issue or the wrapper was merged. It is complete only after the new runtime is deployed and the result returns from the VPS.
