#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
QUEUE_DIR="${JOB_ROOT}/queue"
ACTIVE_DIR="${JOB_ROOT}/active"
DONE_DIR="${JOB_ROOT}/done"
FAILED_DIR="${JOB_ROOT}/failed"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
REPORT_DIR="${LOG_DIR}/reports"
APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
LOCK_FILE="${AI_COUNCIL_JOB_RUNNER_LOCK_FILE:-${JOB_ROOT}/runner.lock}"
DEFER_SECONDS="${AI_COUNCIL_JOB_DEFER_SECONDS:-3600}"
MAX_DEFER_COUNT="${AI_COUNCIL_JOB_MAX_DEFER_COUNT:-48}"

mkdir -p "${QUEUE_DIR}" "${ACTIVE_DIR}" "${DONE_DIR}" "${FAILED_DIR}" "${LOG_DIR}" "${REPORT_DIR}"

if ! command -v flock >/dev/null 2>&1; then
  echo "ERROR: flock is required for the job runner" >&2
  echo "JOB_RUNNER_STATUS: ERROR"
  exit 1
fi

if [[ ! "${DEFER_SECONDS}" =~ ^[0-9]+$ || "${DEFER_SECONDS}" -lt 60 ]]; then
  echo "ERROR: AI_COUNCIL_JOB_DEFER_SECONDS must be an integer of at least 60" >&2
  exit 1
fi

if [[ ! "${MAX_DEFER_COUNT}" =~ ^[0-9]+$ || "${MAX_DEFER_COUNT}" -lt 1 ]]; then
  echo "ERROR: AI_COUNCIL_JOB_MAX_DEFER_COUNT must be a positive integer" >&2
  exit 1
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "AI Council job runner"
  echo "Another runner already holds ${LOCK_FILE}."
  echo "JOB_RUNNER_STATUS: BUSY"
  exit 0
fi

now_epoch="$(date -u +%s)"
job_file=""
deferred_waiting=0

shopt -s nullglob
queued_jobs=("${QUEUE_DIR}"/*.job)
shopt -u nullglob

for candidate in "${queued_jobs[@]}"; do
  not_before="$(awk -F= '/^NOT_BEFORE_EPOCH=/{print $2; exit}' "${candidate}" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "${not_before}" && "${not_before}" =~ ^[0-9]+$ && "${not_before}" -gt "${now_epoch}" ]]; then
    deferred_waiting=$((deferred_waiting + 1))
    continue
  fi
  job_file="${candidate}"
  break
done

if [[ -z "${job_file}" ]]; then
  echo "AI Council job runner"
  if [[ "${deferred_waiting}" -gt 0 ]]; then
    echo "No eligible jobs. Deferred jobs waiting: ${deferred_waiting}."
    echo "JOB_RUNNER_STATUS: IDLE_DEFERRED"
  else
    echo "No queued jobs."
    echo "JOB_RUNNER_STATUS: IDLE"
  fi
  exit 0
fi

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
NOT_BEFORE_EPOCH=""
DEFER_COUNT="0"
parse_error=""
key=""
value=""

while IFS='=' read -r key value || [[ -n "${key}" ]]; do
  [[ -z "${key}" || "${key}" == \#* ]] && continue

  case "${key}" in
    JOB_ID) JOB_ID="${value}" ;;
    JOB_TYPE) JOB_TYPE="${value}" ;;
    REPO_NAME) REPO_NAME="${value}" ;;
    REQUEST_SOURCE) REQUEST_SOURCE="${value}" ;;
    REQUESTED_BY) REQUESTED_BY="${value}" ;;
    CREATED_AT) CREATED_AT="${value}" ;;
    NOT_BEFORE_EPOCH) NOT_BEFORE_EPOCH="${value}" ;;
    DEFER_COUNT) DEFER_COUNT="${value}" ;;
    *)
      parse_error="Unsupported job key: ${key}"
      break
      ;;
  esac
done < "${active_file}"

fallback_job_id="${job_base%.job}"
report_job_id="${JOB_ID:-${fallback_job_id}}"
if [[ ! "${report_job_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  report_job_id="invalid-job-$(date -u +%Y%m%dT%H%M%SZ)"
fi

run_stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log_file="${LOG_DIR}/${report_job_id}-${run_stamp}.log"
per_job_report="${REPORT_DIR}/${report_job_id}.md"
latest_report="${LOG_DIR}/latest-job-report.md"

write_validation_failure() {
  local reason="$1"
  {
    echo "# AI Council Job Run"
    echo
    echo "- Generated At: ${generated_at}"
    echo "- Hostname: $(hostname)"
    echo "- Job ID: ${report_job_id}"
    echo "- Job Type: ${JOB_TYPE:-unknown}"
    echo "- Repo Name: ${REPO_NAME:-}"
    echo "- Request Source: ${REQUEST_SOURCE:-}"
    echo "- Requested By: ${REQUESTED_BY:-}"
    echo "- Created At: ${CREATED_AT:-}"
    echo "- Job Log: ${log_file}"
    echo "- Job Report: ${per_job_report}"
    echo
    echo "ERROR: ${reason}"
    echo "JOB_RUNNER_STATUS: ERROR"
  } | tee "${log_file}" "${per_job_report}" "${latest_report}" >/dev/null

  mv "${active_file}" "${FAILED_DIR}/${job_base}"
  echo "Job failed validation: ${report_job_id}" >&2
  echo "JOB_REPORT_FILE: ${per_job_report}"
  echo "JOB_RUNNER_STATUS: ERROR" >&2
  exit 1
}

[[ -z "${parse_error}" ]] || write_validation_failure "${parse_error}"
[[ -n "${JOB_ID}" && -n "${JOB_TYPE}" ]] || write_validation_failure "Job file is missing JOB_ID or JOB_TYPE"
[[ "${JOB_ID}" =~ ^[A-Za-z0-9._:-]+$ ]] || write_validation_failure "Unsafe JOB_ID"

case "${JOB_TYPE}" in
  repo_check | workspace_summary | ai_plan | ai_check | ai_exec) ;;
  *) write_validation_failure "Unsupported job type: ${JOB_TYPE}" ;;
esac

if [[ -n "${REPO_NAME}" && ! "${REPO_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  write_validation_failure "Unsafe REPO_NAME"
fi
if [[ -n "${REQUEST_SOURCE}" && ! "${REQUEST_SOURCE}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  write_validation_failure "Unsafe REQUEST_SOURCE"
fi
if [[ -n "${REQUESTED_BY}" && ! "${REQUESTED_BY}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  write_validation_failure "Unsafe REQUESTED_BY"
fi
if [[ -n "${CREATED_AT}" && ! "${CREATED_AT}" =~ ^[A-Za-z0-9._:@+-]+$ ]]; then
  write_validation_failure "Unsafe CREATED_AT"
fi
if [[ -n "${NOT_BEFORE_EPOCH}" && ! "${NOT_BEFORE_EPOCH}" =~ ^[0-9]+$ ]]; then
  write_validation_failure "Unsafe NOT_BEFORE_EPOCH"
fi
if [[ ! "${DEFER_COUNT}" =~ ^[0-9]+$ ]]; then
  write_validation_failure "Unsafe DEFER_COUNT"
fi

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "ERROR: root privileges are required and sudo is unavailable" >&2
    return 1
  fi
}

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
  echo "- Job Report: ${per_job_report}"
  echo "- Defer Count: ${DEFER_COUNT}"
  echo

  case "${JOB_TYPE}" in
    repo_check)
      [[ -n "${REPO_NAME}" && "${REPO_NAME}" != "all" ]] || { echo "ERROR: repo_check requires a single REPO_NAME" >&2; return 1; }
      [[ -f "${APP_DIR}/scripts/run_repo_check.sh" ]] || { echo "ERROR: Missing script: ${APP_DIR}/scripts/run_repo_check.sh" >&2; return 1; }
      echo "## Execute"
      echo "bash ${APP_DIR}/scripts/run_repo_check.sh ${REPO_NAME}"
      echo
      run_as_root bash "${APP_DIR}/scripts/run_repo_check.sh" "${REPO_NAME}"
      ;;
    workspace_summary)
      [[ -f "${APP_DIR}/scripts/report_workspaces.sh" ]] || { echo "ERROR: Missing script: ${APP_DIR}/scripts/report_workspaces.sh" >&2; return 1; }
      echo "## Execute"
      echo "bash ${APP_DIR}/scripts/report_workspaces.sh"
      echo
      run_as_root bash "${APP_DIR}/scripts/report_workspaces.sh"
      ;;
    ai_plan)
      [[ -f "${APP_DIR}/scripts/run_ai_plan.sh" ]] || { echo "ERROR: Missing script: ${APP_DIR}/scripts/run_ai_plan.sh" >&2; return 1; }
      echo "## Execute"
      echo "bash ${APP_DIR}/scripts/run_ai_plan.sh ${REPO_NAME:-ai-council}"
      echo
      run_as_root env AI_COUNCIL_JOB_ID="${JOB_ID}" AI_COUNCIL_REQUEST_SOURCE="${REQUEST_SOURCE:-}" AI_COUNCIL_REQUESTED_BY="${REQUESTED_BY:-}" bash "${APP_DIR}/scripts/run_ai_plan.sh" "${REPO_NAME:-ai-council}"
      ;;
    ai_check)
      [[ -f "${APP_DIR}/scripts/run_ai_check.sh" ]] || { echo "ERROR: Missing script: ${APP_DIR}/scripts/run_ai_check.sh" >&2; return 1; }
      echo "## Execute"
      echo "bash ${APP_DIR}/scripts/run_ai_check.sh ${REPO_NAME:-ai-council}"
      echo
      run_as_root env AI_COUNCIL_JOB_ID="${JOB_ID}" AI_COUNCIL_REQUEST_SOURCE="${REQUEST_SOURCE:-}" AI_COUNCIL_REQUESTED_BY="${REQUESTED_BY:-}" bash "${APP_DIR}/scripts/run_ai_check.sh" "${REPO_NAME:-ai-council}"
      ;;
    ai_exec)
      [[ -f "${APP_DIR}/scripts/run_ai_exec.sh" ]] || { echo "ERROR: Missing script: ${APP_DIR}/scripts/run_ai_exec.sh" >&2; return 1; }
      echo "## Execute"
      echo "bash ${APP_DIR}/scripts/run_ai_exec.sh ${REPO_NAME:-ai-council}"
      echo
      run_as_root env AI_COUNCIL_JOB_ID="${JOB_ID}" AI_COUNCIL_REQUEST_SOURCE="${REQUEST_SOURCE:-}" AI_COUNCIL_REQUESTED_BY="${REQUESTED_BY:-}" bash "${APP_DIR}/scripts/run_ai_exec.sh" "${REPO_NAME:-ai-council}"
      ;;
  esac
}

append_to_reports() {
  tee -a "${log_file}" "${per_job_report}" "${latest_report}" >/dev/null
}

set +e
run_job 2>&1 | tee "${log_file}" "${per_job_report}" "${latest_report}"
status="${PIPESTATUS[0]}"
set -e

if [[ "${status}" -eq 0 ]]; then
  {
    echo
    echo "JOB_RUNNER_STATUS: OK"
  } | append_to_reports
  mv "${active_file}" "${DONE_DIR}/${job_base}"
  echo "Job completed: ${JOB_ID}"
  echo "JOB_REPORT_FILE: ${per_job_report}"
  echo "JOB_RUNNER_STATUS: OK"
  exit 0
fi

transient_status="$(awk -F': ' '
  /^AI_EXEC_STATUS: (OUT_OF_HOURS|RATE_LIMITED|HOURLY_LIMIT|DAILY_LIMIT)$/ {value=$2}
  END {print value}
' "${per_job_report}")"

if [[ -n "${transient_status}" && "${DEFER_COUNT}" -lt "${MAX_DEFER_COUNT}" ]]; then
  next_defer_count=$((DEFER_COUNT + 1))
  retry_epoch=$(( $(date -u +%s) + DEFER_SECONDS ))
  temp_job="${active_file}.tmp"
  awk -F= '$1 != "NOT_BEFORE_EPOCH" && $1 != "DEFER_COUNT" {print}' "${active_file}" > "${temp_job}"
  {
    echo "NOT_BEFORE_EPOCH=${retry_epoch}"
    echo "DEFER_COUNT=${next_defer_count}"
  } >> "${temp_job}"
  mv "${temp_job}" "${active_file}"
  mv "${active_file}" "${QUEUE_DIR}/${job_base}"

  {
    echo
    echo "- Deferred Reason: ${transient_status}"
    echo "- Retry Not Before Epoch: ${retry_epoch}"
    echo "- Defer Count: ${next_defer_count}"
    echo "JOB_RUNNER_STATUS: DEFERRED"
  } | append_to_reports

  echo "Job deferred: ${JOB_ID} (${transient_status})"
  echo "JOB_REPORT_FILE: ${per_job_report}"
  echo "JOB_RUNNER_STATUS: DEFERRED"
  exit 0
fi

{
  echo
  if [[ -n "${transient_status}" ]]; then
    echo "- Deferred Reason: ${transient_status}"
    echo "- Defer Count: ${DEFER_COUNT}"
    echo "- Max Defer Count: ${MAX_DEFER_COUNT}"
  fi
  echo "JOB_RUNNER_STATUS: ERROR"
} | append_to_reports

mv "${active_file}" "${FAILED_DIR}/${job_base}"
echo "Job failed: ${JOB_ID}" >&2
echo "JOB_REPORT_FILE: ${per_job_report}"
echo "JOB_RUNNER_STATUS: ERROR" >&2
exit "${status}"
