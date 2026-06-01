#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ai-council"
LOG_DIR="/var/log/ai-council"
REPORT_FILE="${LOG_DIR}/latest-report.md"
SUCCESS_FILE="${LOG_DIR}/last-successful-run"
TMP_REPORT="$(mktemp)"

cleanup() {
  rm -f "${TMP_REPORT}"
}
trap cleanup EXIT

mkdir -p "${LOG_DIR}"

if "${APP_DIR}/scripts/healthcheck.sh" >"${TMP_REPORT}" 2>&1; then
  run_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf "%s\\n" "${run_time}" >"${SUCCESS_FILE}"
  {
    echo "STATUS: OK"
    echo "Last Successful Run: ${run_time}"
    echo
    cat "${TMP_REPORT}"
  } >"${REPORT_FILE}"
else
  run_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  last_success="unconfirmed"
  if [[ -r "${SUCCESS_FILE}" ]]; then
    last_success="$(cat "${SUCCESS_FILE}")"
  fi
  {
    echo "STATUS: ERROR"
    echo "Checked At: ${run_time}"
    echo "Last Successful Run: ${last_success}"
    echo
    cat "${TMP_REPORT}"
  } >"${REPORT_FILE}"
  exit 1
fi

echo "Wrote ${REPORT_FILE}"
