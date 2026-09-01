#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
IMPORT_DIR="${STATE_ROOT}/imported"
BLOCKED_DIR="${STATE_ROOT}/blocked"
POSTED_DIR="${STATE_ROOT}/posted"
ISSUE_NUMBER="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root: sudo bash scripts/requeue_github_issue.sh <ISSUE_NUMBER>" >&2
  exit 1
fi
if [[ ! "${ISSUE_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: ISSUE_NUMBER must be numeric" >&2
  exit 1
fi

imported_marker="${IMPORT_DIR}/issue-${ISSUE_NUMBER}.imported"
blocked_marker="${BLOCKED_DIR}/issue-${ISSUE_NUMBER}.blocked"

if [[ -r "${imported_marker}" ]]; then
  job_id="$(awk -F= '/^JOB_ID=/{print $2; exit}' "${imported_marker}")"
  if [[ -z "${job_id}" || ! "${job_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "ERROR: imported marker has no safe JOB_ID: ${imported_marker}" >&2
    exit 1
  fi
  job_file="${job_id}.job"

  if [[ -e "${JOB_ROOT}/active/${job_file}" ]]; then
    echo "REQUEUE_STATUS: BLOCKED_ACTIVE"
    exit 1
  fi
  if [[ -e "${JOB_ROOT}/queue/${job_file}" ]]; then
    echo "REQUEUE_STATUS: ALREADY_QUEUED"
    exit 0
  fi
  if [[ -e "${JOB_ROOT}/done/${job_file}" ]]; then
    echo "REQUEUE_STATUS: BLOCKED_ALREADY_DONE"
    exit 1
  fi

  if [[ -e "${JOB_ROOT}/failed/${job_file}" ]]; then
    temp_job="${JOB_ROOT}/failed/${job_file}.tmp"
    awk -F= '$1 != "NOT_BEFORE_EPOCH" && $1 != "DEFER_COUNT" {print}' "${JOB_ROOT}/failed/${job_file}" > "${temp_job}"
    echo "DEFER_COUNT=0" >> "${temp_job}"
    mv "${temp_job}" "${JOB_ROOT}/queue/${job_file}"
    rm -f "${JOB_ROOT}/failed/${job_file}"
    rm -f "${POSTED_DIR}/${job_id}-"*.posted
    {
      cat "${imported_marker}"
      echo "STATE=REQUEUED"
      echo "REQUEUED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "${imported_marker}.tmp"
    mv "${imported_marker}.tmp" "${imported_marker}"
    echo "REQUEUE_STATUS: OK"
    echo "JOB_ID=${job_id}"
    exit 0
  fi

  echo "Imported marker exists but no queue/active/done/failed job file was found. Clearing stale marker."
  rm -f "${imported_marker}"
fi

rm -f "${blocked_marker}"
AI_COUNCIL_GITHUB_IMPORT_LIMIT="${AI_COUNCIL_GITHUB_IMPORT_LIMIT:-100}" bash "${APP_DIR}/scripts/import_github_jobs.sh"
echo "REQUEUE_STATUS: IMPORT_REQUESTED"
