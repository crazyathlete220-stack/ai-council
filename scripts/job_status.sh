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

count_pending_posts() {
  local files=()

  if [[ -d "${LOG_DIR}/pending-posts" ]]; then
    shopt -s nullglob
    files=("${LOG_DIR}/pending-posts"/*.md)
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
echo "- deferred: $(count_jobs "${JOB_ROOT}/deferred")"
echo "- pending GitHub posts: $(count_pending_posts)"
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

required_dirs=(
  "${JOB_ROOT}/queue"
  "${JOB_ROOT}/active"
  "${JOB_ROOT}/done"
  "${JOB_ROOT}/failed"
  "${JOB_ROOT}/deferred"
  "${LOG_DIR}/reports"
  "${LOG_DIR}/pending-posts"
)

missing=0
for required_dir in "${required_dirs[@]}"; do
  if [[ ! -d "${required_dir}" ]]; then
    echo "- missing directory: ${required_dir}"
    missing=1
  fi
done

if [[ "${missing}" -eq 0 ]]; then
  echo
  echo "JOB_INBOX_STATUS: OK"
else
  echo
  echo "JOB_INBOX_STATUS: ERROR"
  exit 1
fi
