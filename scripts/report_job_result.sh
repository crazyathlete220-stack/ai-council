#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
SUMMARY_DIR="${LOG_DIR}/summaries"
LATEST_SUMMARY="${LOG_DIR}/latest-summary.md"
REPORT_FILE="${1:-${LOG_DIR}/latest-job-report.md}"
EXTRACTOR="${APP_DIR}/scripts/extract_job_signals.sh"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "${LOG_DIR}" "${SUMMARY_DIR}"

if [[ ! -r "${REPORT_FILE}" ]]; then
  echo "ERROR: job report is not readable: ${REPORT_FILE}" >&2
  echo "JOB_REPORT_STATUS: NO_REPORT"
  exit 1
fi
if [[ ! -r "${EXTRACTOR}" ]]; then
  echo "ERROR: job signal extractor is not readable: ${EXTRACTOR}" >&2
  echo "JOB_REPORT_STATUS: EXTRACTOR_MISSING"
  exit 1
fi

job_id="$(awk -F': ' '/^- Job ID: /{print $2; exit}' "${REPORT_FILE}")"
job_id="${job_id:-unknown-job}"
job_id_safe="$(printf '%s' "${job_id}" | tr -c 'A-Za-z0-9._-' '_')"
SUMMARY_FILE="${SUMMARY_DIR}/${job_id_safe}.md"

{
  echo "# AI Council Job Summary"
  echo
  echo "- Generated At: ${generated_at}"
  echo "- Source Report: ${REPORT_FILE}"
  echo
  echo "## Job Signals"
  bash "${EXTRACTOR}" "${REPORT_FILE}"
  echo
  echo "JOB_REPORT_STATUS: OK"
} | tee "${SUMMARY_FILE}" "${LATEST_SUMMARY}"
