#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
CYCLE_LOG_DIR="${LOG_DIR}/cycles"
mkdir -p "${CYCLE_LOG_DIR}"

cycle_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
cycle_log="${CYCLE_LOG_DIR}/${cycle_stamp}-$$.log"

set +e
bash "${APP_DIR}/scripts/run_job_once.sh" > >(tee "${cycle_log}") 2>&1
run_status=$?
set -e

report_path="$(awk -F': ' '/^JOB_REPORT_FILE: /{value=$2} END {print value}' "${cycle_log}")"
report_status=0
post_status=0

if [[ -n "${report_path}" && -r "${report_path}" ]]; then
  set +e
  bash "${APP_DIR}/scripts/report_job_result.sh" "${report_path}"
  report_status=$?
  bash "${APP_DIR}/scripts/post_job_result_to_github.sh" "${report_path}"
  post_status=$?
  set -e
else
  if [[ "${run_status}" -ne 0 ]]; then
    echo "ERROR: runner failed without a readable per-job report" >&2
    report_status=1
  fi
fi

if [[ "${run_status}" -eq 0 && "${report_status}" -eq 0 && "${post_status}" -eq 0 ]]; then
  echo "JOB_CYCLE_STATUS: OK"
  exit 0
fi

if [[ "${run_status}" -ne 0 ]]; then
  echo "JOB_CYCLE_RUN_STATUS: ${run_status}" >&2
fi
if [[ "${report_status}" -ne 0 ]]; then
  echo "JOB_CYCLE_REPORT_STATUS: ${report_status}" >&2
fi
if [[ "${post_status}" -ne 0 ]]; then
  echo "JOB_CYCLE_POST_STATUS: ${post_status}" >&2
fi

echo "JOB_CYCLE_STATUS: ERROR" >&2
exit 1
