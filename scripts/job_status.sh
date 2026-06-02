#!/usr/bin/env bash
set -euo pipefail

JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"

count_jobs() {
  local dir="$1"
  local files=()

  if [[ -d "${dir}" ]]; then
    shopt -s nullglob
    files=("${dir}"/*.job)
    shopt -u nullglob
  fi

  echo "${#files[@]}"
}

echo "AI Council job inbox status"
echo
echo "- queue: $(count_jobs "${JOB_ROOT}/queue")"
echo "- active: $(count_jobs "${JOB_ROOT}/active")"
echo "- done: $(count_jobs "${JOB_ROOT}/done")"
echo "- failed: $(count_jobs "${JOB_ROOT}/failed")"
echo "- job root: ${JOB_ROOT}"
echo "- log dir: ${LOG_DIR}"

if [[ -r "${LOG_DIR}/latest-job-report.md" ]]; then
  echo "- latest-job-report.md: yes"
else
  echo "- latest-job-report.md: no"
fi

if [[ -r "${LOG_DIR}/latest-summary.md" ]]; then
  echo "- latest-summary.md: yes"
else
  echo "- latest-summary.md: no"
fi

if [[ -d "${JOB_ROOT}/queue" && -d "${JOB_ROOT}/active" && -d "${JOB_ROOT}/done" && -d "${JOB_ROOT}/failed" ]]; then
  echo
  echo "JOB_INBOX_STATUS: OK"
else
  echo
  echo "JOB_INBOX_STATUS: ERROR"
  exit 1
fi

