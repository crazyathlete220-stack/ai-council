#!/usr/bin/env bash
set -euo pipefail

JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
QUEUE_DIR="${JOB_ROOT}/queue"
ACTIVE_DIR="${JOB_ROOT}/active"
DONE_DIR="${JOB_ROOT}/done"
FAILED_DIR="${JOB_ROOT}/failed"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"

mkdir -p "${QUEUE_DIR}" "${ACTIVE_DIR}" "${DONE_DIR}" "${FAILED_DIR}" "${LOG_DIR}"

shopt -s nullglob
queued_jobs=("${QUEUE_DIR}"/*.job)
shopt -u nullglob

if [[ "${#queued_jobs[@]}" -eq 0 ]]; then
  echo "AI Council job runner"
  echo "No queued jobs."
  echo "JOB_RUNNER_STATUS: IDLE"
  exit 0
fi

job_file="${queued_jobs[0]}"
job_base="$(basename "${job_file}")"
active_file="${ACTIVE_DIR}/${job_base}"

if [[ -e "${active_file}" ]]; then
  echo "ERROR: Active job already exists: ${active_file}" >&2
  exit 1
fi

mv "${job_file}" "${active_file}"

JOB_ID=""
JOB_TYPE=""
REPO_NAME=""
REQUEST_SOURCE=""
REQUESTED_BY=""
CREATED_AT=""
key=""
value=""

while IFS='=' read -r key value || [[ -n "${key}" ]]; do
  [[ -z "${key}" || "${key}" == \#* ]] && continue

  case "${key}" in
    JOB_ID)
      JOB_ID="${value}"
      ;;
    JOB_TYPE)
      JOB_TYPE="${value}"
      ;;
    REPO_NAME)
      REPO_NAME="${value}"
      ;;
    REQUEST_SOURCE)
      REQUEST_SOURCE="${value}"
      ;;
    REQUESTED_BY)
      REQUESTED_BY="${value}"
      ;;
    CREATED_AT)
      CREATED_AT="${value}"
      ;;
    *)
      echo "ERROR: Unsupported job key: ${key}" >&2
      mv "${active_file}" "${FAILED_DIR}/${job_base}"
      exit 1
      ;;
  esac
done < "${active_file}"

if [[ -z "${JOB_ID}" || -z "${JOB_TYPE}" ]]; then
  echo "ERROR: Job file is missing JOB_ID or JOB_TYPE: ${active_file}" >&2
  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  exit 1
fi

if [[ ! "${JOB_ID}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "ERROR: Unsafe JOB_ID: ${JOB_ID}" >&2
  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  exit 1
fi

case "${JOB_TYPE}" in
  repo_check | workspace_summary | ai_plan | ai_check | ai_exec)
    ;;
  *)
    echo "ERROR: Unsupported job type: ${JOB_TYPE}" >&2
    mv "${active_file}" "${FAILED_DIR}/${job_base}"
    exit 1
    ;;
esac

if [[ -n "${REPO_NAME}" && ! "${REPO_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Unsafe REPO_NAME: ${REPO_NAME}" >&2
  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  exit 1
fi

if [[ -n "${REQUEST_SOURCE}" && ! "${REQUEST_SOURCE}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  echo "ERROR: Unsafe REQUEST_SOURCE: ${REQUEST_SOURCE}" >&2
  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  exit 1
fi

if [[ -n "${REQUESTED_BY}" && ! "${REQUESTED_BY}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  echo "ERROR: Unsafe REQUESTED_BY: ${REQUESTED_BY}" >&2
  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  exit 1
fi

if [[ -n "${CREATED_AT}" && ! "${CREATED_AT}" =~ ^[A-Za-z0-9._:@+-]+$ ]]; then
  echo "ERROR: Unsafe CREATED_AT: ${CREATED_AT}" >&2
  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  exit 1
fi

run_stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log_file="${LOG_DIR}/${JOB_ID}-${run_stamp}.log"
latest_report="${LOG_DIR}/latest-job-report.md"

run_job() {
  echo "# AI Council Job Run"
  echo
  echo "- Generated At: ${generated_at}"
  echo "- Hostname: $(hostname)"
  echo "- Job ID: ${JOB_ID}"
  echo "- Job Type: ${JOB_TYPE}"
  echo "- Repo Name: ${REPO_NAME:-}"
  echo "- Request Source: ${REQUEST_SOURCE:-}"
  echo "- Requested By: ${REQUESTED_BY:-}"
  echo "- Created At: ${CREATED_AT:-}"
  echo "- Job Log: ${log_file}"
  echo

  case "${JOB_TYPE}" in
    repo_check)
      if [[ -z "${REPO_NAME}" || "${REPO_NAME}" == "all" ]]; then
        echo "ERROR: repo_check requires a single REPO_NAME" >&2
        return 1
      fi
      if [[ ! -f "${APP_DIR}/scripts/run_repo_check.sh" ]]; then
        echo "ERROR: Missing script: ${APP_DIR}/scripts/run_repo_check.sh" >&2
        return 1
      fi
      echo "## Execute"
      echo "sudo bash ${APP_DIR}/scripts/run_repo_check.sh ${REPO_NAME}"
      echo
      sudo bash "${APP_DIR}/scripts/run_repo_check.sh" "${REPO_NAME}"
      ;;
    workspace_summary)
      if [[ ! -f "${APP_DIR}/scripts/report_workspaces.sh" ]]; then
        echo "ERROR: Missing script: ${APP_DIR}/scripts/report_workspaces.sh" >&2
        return 1
      fi
      echo "## Execute"
      echo "sudo bash ${APP_DIR}/scripts/report_workspaces.sh"
      echo
      sudo bash "${APP_DIR}/scripts/report_workspaces.sh"
      ;;
    ai_plan)
      if [[ ! -f "${APP_DIR}/scripts/run_ai_plan.sh" ]]; then
        echo "ERROR: Missing script: ${APP_DIR}/scripts/run_ai_plan.sh" >&2
        return 1
      fi
      echo "## Execute"
      echo "sudo bash ${APP_DIR}/scripts/run_ai_plan.sh ${REPO_NAME:-ai-council}"
      echo
      sudo env \
        AI_COUNCIL_JOB_ID="${JOB_ID}" \
        AI_COUNCIL_REQUEST_SOURCE="${REQUEST_SOURCE:-}" \
        AI_COUNCIL_REQUESTED_BY="${REQUESTED_BY:-}" \
        bash "${APP_DIR}/scripts/run_ai_plan.sh" "${REPO_NAME:-ai-council}"
      ;;
    ai_check)
      if [[ ! -f "${APP_DIR}/scripts/run_ai_check.sh" ]]; then
        echo "ERROR: Missing script: ${APP_DIR}/scripts/run_ai_check.sh" >&2
        return 1
      fi
      echo "## Execute"
      echo "sudo bash ${APP_DIR}/scripts/run_ai_check.sh ${REPO_NAME:-ai-council}"
      echo
      sudo env \
        AI_COUNCIL_JOB_ID="${JOB_ID}" \
        AI_COUNCIL_REQUEST_SOURCE="${REQUEST_SOURCE:-}" \
        AI_COUNCIL_REQUESTED_BY="${REQUESTED_BY:-}" \
        bash "${APP_DIR}/scripts/run_ai_check.sh" "${REPO_NAME:-ai-council}"
      ;;
    ai_exec)
      if [[ ! -f "${APP_DIR}/scripts/run_ai_exec.sh" ]]; then
        echo "ERROR: Missing script: ${APP_DIR}/scripts/run_ai_exec.sh" >&2
        return 1
      fi
      echo "## Execute"
      echo "sudo bash ${APP_DIR}/scripts/run_ai_exec.sh ${REPO_NAME:-ai-council}"
      echo
      sudo env \
        AI_COUNCIL_JOB_ID="${JOB_ID}" \
        AI_COUNCIL_REQUEST_SOURCE="${REQUEST_SOURCE:-}" \
        AI_COUNCIL_REQUESTED_BY="${REQUESTED_BY:-}" \
        bash "${APP_DIR}/scripts/run_ai_exec.sh" "${REPO_NAME:-ai-council}"
      ;;
    *)
      echo "ERROR: Unsupported job type: ${JOB_TYPE}" >&2
      return 1
      ;;
  esac
}

if run_job > >(tee "${log_file}" "${latest_report}") 2>&1; then
  {
    echo
    echo "JOB_RUNNER_STATUS: OK"
  } | tee -a "${log_file}" "${latest_report}" >/dev/null
  mv "${active_file}" "${DONE_DIR}/${job_base}"
  echo "Job completed: ${JOB_ID}"
  echo "JOB_RUNNER_STATUS: OK"
else
  status=$?
  {
    echo
    echo "JOB_RUNNER_STATUS: ERROR"
  } | tee -a "${log_file}" "${latest_report}" >/dev/null
  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  echo "Job failed: ${JOB_ID}" >&2
  echo "JOB_RUNNER_STATUS: ERROR" >&2
  exit "${status}"
fi
