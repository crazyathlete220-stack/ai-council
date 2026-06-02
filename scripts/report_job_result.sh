#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
SUMMARY_FILE="${LOG_DIR}/latest-summary.md"
LATEST_REPORT="${LOG_DIR}/latest-job-report.md"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "${LOG_DIR}"

{
  echo "# AI Council Job Summary"
  echo
  echo "- Generated At: ${generated_at}"
  echo "- Hostname: $(hostname)"
  echo

  if [[ -r "${LATEST_REPORT}" ]]; then
    echo "## Latest Job Signals"
    grep -E "Generated At|Job ID|Job Type|Repo Name|Plan File|Latest Plan|JOB_RUNNER_STATUS|REPO_CHECK_STATUS|WORKSPACE_SUMMARY_STATUS|AI_PLAN_STATUS" "${LATEST_REPORT}" || true
  else
    echo "## Latest Job Signals"
    echo "- latest-job-report.md: not found"
  fi

  echo
  echo "JOB_REPORT_STATUS: OK"
} | tee "${SUMMARY_FILE}"
