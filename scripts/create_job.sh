#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: bash scripts/create_job.sh <repo_check|workspace_summary|ai_plan|ai_check|ai_exec> [REPO_NAME]" >&2
}

JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
QUEUE_DIR="${JOB_ROOT}/queue"
job_type="${1:-}"
repo_name="${2:-}"
request_source="${AI_COUNCIL_REQUEST_SOURCE:-manual}"
requested_by="${AI_COUNCIL_REQUESTED_BY:-unknown}"

if [[ -z "${job_type}" ]]; then
  usage
  exit 1
fi

case "${job_type}" in
  repo_check)
    if [[ -z "${repo_name}" ]]; then
      echo "ERROR: repo_check requires REPO_NAME" >&2
      usage
      exit 1
    fi
    ;;
  workspace_summary)
    repo_name="${repo_name:-all}"
    ;;
  ai_plan)
    repo_name="${repo_name:-ai-council}"
    ;;
  ai_check)
    repo_name="${repo_name:-ai-council}"
    ;;
  ai_exec)
    repo_name="${repo_name:-ai-council}"
    ;;
  *)
    echo "ERROR: Unsupported job type: ${job_type}" >&2
    usage
    exit 1
    ;;
esac

if [[ ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: REPO_NAME may contain only letters, numbers, dot, underscore, and hyphen" >&2
  exit 1
fi

if [[ ! "${request_source}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  echo "ERROR: AI_COUNCIL_REQUEST_SOURCE contains unsupported characters" >&2
  exit 1
fi

if [[ ! "${requested_by}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  echo "ERROR: AI_COUNCIL_REQUESTED_BY contains unsupported characters" >&2
  exit 1
fi

if [[ ! -d "${QUEUE_DIR}" ]]; then
  echo "ERROR: Queue directory not found: ${QUEUE_DIR}" >&2
  echo "Run: sudo bash scripts/setup_operator_user.sh" >&2
  exit 1
fi

created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
job_id="${stamp}-${job_type}-${repo_name}-$$"
job_file="${QUEUE_DIR}/${job_id}.job"

{
  printf "JOB_ID=%s\n" "${job_id}"
  printf "JOB_TYPE=%s\n" "${job_type}"
  printf "REPO_NAME=%s\n" "${repo_name}"
  printf "REQUEST_SOURCE=%s\n" "${request_source}"
  printf "REQUESTED_BY=%s\n" "${requested_by}"
  printf "CREATED_AT=%s\n" "${created_at}"
} > "${job_file}"

echo "Created job:"
echo "  ${job_file}"
echo "  JOB_ID=${job_id}"
echo "  JOB_TYPE=${job_type}"
echo "  REPO_NAME=${repo_name}"
echo
echo "Next command:"
echo "  sudo bash scripts/run_job_once.sh"
