# AI Council Recovery Audit — 2026-09-01

Status: IN PROGRESS

This document records repository-side findings for the GitHub Issue bridge recovery.

Confirmed findings:

1. `scripts/import_github_jobs.sh` imports only open issues carrying the configured `vps-job` label.
2. Recovery Issues #91 and #98 were created without that label, so they were not eligible for import.
3. `systemd/ai-council-github-bridge.service` runs result reporting only after `run_job_once.sh` succeeds. A handled job error therefore prevents GitHub result posting.
4. Imported markers are written before job execution, so a failed job is not automatically re-imported.
5. `post_job_result_to_github.sh` reads a global `latest-job-report.md`, which can associate a result with the wrong job when bridge and runner timers overlap.

Required recovery sequence:

- Confirm the bridge with a labeled `ai_check` issue.
- Process a labeled recovery job on the known `ai-council` workspace.
- Verify or register `ai-council-private` on the VPS.
- Requeue Issue #91 only after workspace readiness is confirmed.
- Add durable per-job reporting and explicit failure/deferred states.

This file is evidence of repository-side analysis only. It is not evidence that the VPS has been repaired.
