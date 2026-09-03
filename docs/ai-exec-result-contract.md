# ai_exec Result Contract

## Purpose

Prevent a Codex process exit code of `0` from being treated as business success when the final response actually says the work is blocked, failed, or incomplete.

## Entry contract

For owner-authored GitHub Issues with:

```text
JOB_TYPE=ai_exec
REPO_NAME=<registered-workspace>
```

the repository workflow appends one fixed instruction block identified by:

```text
<!-- AI_COUNCIL_RESULT_CONTRACT_V1 -->
```

The block requires the final non-empty line of the Codex response to be exactly one of:

```text
AI_EXEC_RESULT: SUCCESS
AI_EXEC_RESULT: BLOCKED
AI_EXEC_RESULT: FAILED
```

The workflow does not interpret the user request as shell and does not add secrets.

## Classification

`classify_ai_exec_result.sh` accepts only one exact marker and requires it to be the final non-empty line.

| Marker state | Semantic status | Runner result | Job directory |
|---|---|---|---|
| `SUCCESS` | verified success | `JOB_RUNNER_STATUS: OK` | `done/` |
| `BLOCKED` | verified blocker | `JOB_RUNNER_STATUS: ERROR` | `failed/` |
| `FAILED` | verified failure | `JOB_RUNNER_STATUS: ERROR` | `failed/` |
| missing | indeterminate | `JOB_RUNNER_STATUS: ERROR` | `failed/` |
| multiple | indeterminate | `JOB_RUNNER_STATUS: ERROR` | `failed/` |
| not final | indeterminate | `JOB_RUNNER_STATUS: ERROR` | `failed/` |

The classifier does not infer success from prose.

## Execution

`run_job_once.sh` still owns the initial queue transition and process execution. `run_job_cycle.sh` then applies the result contract before generating the summary and posting to GitHub.

For GitHub-originated `ai_exec` jobs that initially report process-level success:

1. Read the per-job report.
2. Locate the exact `last-message.md` path recorded by `run_ai_exec.sh`.
3. Run the strict classifier.
4. Append `Result Marker` and contract details to the same per-job report.
5. Preserve verified success, or correct the final statuses and move the job from `done/` to `failed/`.
6. Generate the summary and GitHub result from the corrected report.

Non-GitHub and non-`ai_exec` jobs keep their existing behavior.

## Evidence

Expected GitHub-visible signals:

```text
Result Marker: SUCCESS | BLOCKED | FAILED | MISSING | MULTIPLE | NOT_FINAL
AI_EXEC_STATUS: OK | BLOCKED | FAILED | INDETERMINATE
JOB_RUNNER_STATUS: OK | ERROR
```

The durable source is:

```text
/var/log/ai-council/jobs/reports/<JOB_ID>.md
```

## Recovery

For `INDETERMINATE`:

1. Read the per-job report and `Last Message` path.
2. Confirm whether the required marker is missing, duplicated, or followed by trailing text.
3. Correct the request/result-contract delivery issue.
4. Requeue the source Issue through `requeue_github_issue.sh`.
5. Do not manually move job files or delete markers.

For a real blocker, create a new or requeued job only after the blocker has been removed.

## Visibility and completion

Repository tests and a merge prove only the code path. VPS completion additionally requires:

- runtime deployment from the reviewed main commit
- a fresh GitHub `ai_exec` Issue receiving the contract block
- `STATE: QUEUED`
- one verified `SUCCESS` E2E result
- one controlled `BLOCKED` E2E result
- per-job report paths and final GitHub comments for both

A code merge alone is not VPS recovery evidence.
