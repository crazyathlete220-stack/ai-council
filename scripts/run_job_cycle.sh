#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
QUEUE_DIR="${JOB_ROOT}/queue"
ACTIVE_DIR="${JOB_ROOT}/active"
DONE_DIR="${JOB_ROOT}/done"
FAILED_DIR="${JOB_ROOT}/failed"
DEFERRED_DIR="${JOB_ROOT}/deferred"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
LATEST_REPORT="${LOG_DIR}/latest-job-report.md"
REPORT_DIR="${LOG_DIR}/reports"
PENDING_POST_DIR="${LOG_DIR}/pending-posts"
LOCK_FILE="${JOB_ROOT}/runner.lock"
LOCK_WAIT_SECONDS="${AI_COUNCIL_JOB_LOCK_WAIT_SECONDS:-30}"
STALE_ACTIVE_SECONDS="${AI_COUNCIL_STALE_ACTIVE_SECONDS:-1800}"
cycle_stamp="$(date -u +'%Y%m%dT%H%M%SZ')"

mkdir -p \
  "${QUEUE_DIR}" "${ACTIVE_DIR}" "${DONE_DIR}" "${FAILED_DIR}" "${DEFERRED_DIR}" \
  "${LOG_DIR}" "${REPORT_DIR}" "${PENDING_POST_DIR}"

if ! command -v flock >/dev/null 2>&1; then
  echo "ERROR: flock is required to serialize bridge and runner cycles" >&2
  echo "JOB_CYCLE_STATUS: LOCK_UNAVAILABLE" >&2
  exit 1
fi

exec 9>"${LOCK_FILE}"
if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
  echo "Another AI Council job cycle is active."
  echo "JOB_CYCLE_STATUS: BUSY"
  exit 0
fi

extract_status() {
  local file="$1"
  local key="$2"
  awk -F': ' -v key="${key}" '$1 == key {print $2}' "${file}" 2>/dev/null | tail -n 1 | tr -d '[:space:]'
}

post_report() {
  local report_file="$1"
  local post_log="${report_file%.md}.post.log"
  local post_rc=0
  local post_status=""

  AI_COUNCIL_JOB_REPORT_FILE="${report_file}" \
    bash "${APP_DIR}/scripts/post_job_result_to_github.sh" >"${post_log}" 2>&1
  post_rc=$?
  cat "${post_log}"
  post_status="$(extract_status "${post_log}" "GITHUB_JOB_POST_STATUS")"
  post_status="${post_status:-UNKNOWN}"

  case "${post_status}" in
    OK | ALREADY_POSTED | NO_ISSUE_SOURCE | NO_REPORT)
      return 0
      ;;
    *)
      echo "Pending GitHub post retained: ${report_file}" >&2
      echo "Post status: ${post_status}; exit: ${post_rc}" >&2
      return 1
      ;;
  esac
}

post_pending_reports() {
  local pending_reports=()
  local pending_report=""

  shopt -s nullglob
  pending_reports=("${PENDING_POST_DIR}"/*.md)
  shopt -u nullglob

  for pending_report in "${pending_reports[@]}"; do
    if post_report "${pending_report}"; then
      rm -f "${pending_report}"
    else
      return 1
    fi
  done

  return 0
}

recover_stale_active_jobs() {
  local active_jobs=()
  local active_job=""
  local job_base=""
  local job_id=""
  local job_type=""
  local repo_name=""
  local request_source=""
  local requested_by=""
  local created_at=""
  local modified_epoch=""
  local now_epoch=""
  local age_seconds=""
  local report_file=""
  local recent_active=0

  now_epoch="$(date -u +%s)"
  shopt -s nullglob
  active_jobs=("${ACTIVE_DIR}"/*.job)
  shopt -u nullglob

  for active_job in "${active_jobs[@]}"; do
    modified_epoch="$(stat -c '%Y' "${active_job}" 2>/dev/null || echo "${now_epoch}")"
    age_seconds="$(( now_epoch - modified_epoch ))"

    if [[ "${age_seconds}" -lt "${STALE_ACTIVE_SECONDS}" ]]; then
      echo "Active job is younger than stale threshold; leaving it untouched: ${active_job}"
      recent_active=1
      continue
    fi

    job_base="$(basename "${active_job}")"
    job_id="$(awk -F= '$1 == "JOB_ID" {print $2; exit}' "${active_job}" 2>/dev/null || true)"
    job_type="$(awk -F= '$1 == "JOB_TYPE" {print $2; exit}' "${active_job}" 2>/dev/null || true)"
    repo_name="$(awk -F= '$1 == "REPO_NAME" {print $2; exit}' "${active_job}" 2>/dev/null || true)"
    request_source="$(awk -F= '$1 == "REQUEST_SOURCE" {print $2; exit}' "${active_job}" 2>/dev/null || true)"
    requested_by="$(awk -F= '$1 == "REQUESTED_BY" {print $2; exit}' "${active_job}" 2>/dev/null || true)"
    created_at="$(awk -F= '$1 == "CREATED_AT" {print $2; exit}' "${active_job}" 2>/dev/null || true)"
    job_id="${job_id:-${job_base%.job}}"
    report_file="${REPORT_DIR}/${job_id}-stale-${cycle_stamp}.md"

    mv "${active_job}" "${FAILED_DIR}/${job_base}"
    {
      echo "# AI Council Job Run"
      echo
      echo "- Generated At: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      echo "- Hostname: $(hostname)"
      echo "- Job ID: ${job_id}"
      echo "- Job Type: ${job_type}"
      echo "- Repo Name: ${repo_name}"
      echo "- Request Source: ${request_source}"
      echo "- Requested By: ${requested_by}"
      echo "- Created At: ${created_at}"
      echo "- Status Reason: stale active job was recovered after ${age_seconds}s; automatic re-execution was refused to avoid duplicate side effects"
      echo "- Retry State: use requeue_github_issue.sh after reviewing the prior job log"
      echo
      echo "JOB_RUNNER_STATUS: ERROR"
    } >"${report_file}"
    cp "${report_file}" "${LATEST_REPORT}"

    if [[ "${request_source}" =~ ^github_issue_[0-9]+$ ]]; then
      cp "${report_file}" "${PENDING_POST_DIR}/$(basename "${report_file}")"
    fi

    echo "Recovered stale active job to failed: ${job_base}"
  done

  if [[ "${recent_active}" -eq 1 ]]; then
    return 2
  fi

  return 0
}

promote_deferred_jobs() {
  local now_epoch=""
  local retry_files=()
  local retry_file=""
  local job_base=""
  local deferred_job=""
  local retry_at=""

  now_epoch="$(date -u +%s)"
  shopt -s nullglob
  retry_files=("${DEFERRED_DIR}"/*.job.retry_at)
  shopt -u nullglob

  for retry_file in "${retry_files[@]}"; do
    job_base="$(basename "${retry_file}" .retry_at)"
    deferred_job="${DEFERRED_DIR}/${job_base}"
    retry_at="$(tr -d '[:space:]' <"${retry_file}" 2>/dev/null || true)"

    if [[ ! "${retry_at}" =~ ^[0-9]+$ ]]; then
      echo "Invalid deferred retry marker: ${retry_file}" >&2
      continue
    fi

    if [[ ! -f "${deferred_job}" ]]; then
      echo "Deferred job missing for retry marker: ${retry_file}" >&2
      rm -f "${retry_file}"
      continue
    fi

    if [[ "${now_epoch}" -ge "${retry_at}" ]]; then
      mv "${deferred_job}" "${QUEUE_DIR}/${job_base}"
      rm -f "${retry_file}"
      echo "Requeued deferred job: ${job_base}"
    fi
  done
}

if ! post_pending_reports; then
  echo "JOB_CYCLE_STATUS: POST_BLOCKED"
  exit 1
fi

recover_stale_active_jobs
active_recovery_rc=$?

if ! post_pending_reports; then
  echo "JOB_CYCLE_STATUS: POST_BLOCKED"
  exit 1
fi

if [[ "${active_recovery_rc}" -eq 2 ]]; then
  echo "JOB_CYCLE_STATUS: ACTIVE_PRESENT"
  exit 0
fi

promote_deferred_jobs

queued_jobs=()
shopt -s nullglob
queued_jobs=("${QUEUE_DIR}"/*.job)
shopt -u nullglob

if [[ "${#queued_jobs[@]}" -eq 0 ]]; then
  echo "AI Council job cycle"
  echo "No queued jobs."
  echo "JOB_CYCLE_STATUS: IDLE"
  exit 0
fi

job_file="${queued_jobs[0]}"
job_base="$(basename "${job_file}")"
expected_job_id="$(awk -F= '$1 == "JOB_ID" {print $2; exit}' "${job_file}" 2>/dev/null || true)"
expected_job_type="$(awk -F= '$1 == "JOB_TYPE" {print $2; exit}' "${job_file}" 2>/dev/null || true)"
expected_repo_name="$(awk -F= '$1 == "REPO_NAME" {print $2; exit}' "${job_file}" 2>/dev/null || true)"
expected_request_source="$(awk -F= '$1 == "REQUEST_SOURCE" {print $2; exit}' "${job_file}" 2>/dev/null || true)"
expected_requested_by="$(awk -F= '$1 == "REQUESTED_BY" {print $2; exit}' "${job_file}" 2>/dev/null || true)"
expected_created_at="$(awk -F= '$1 == "CREATED_AT" {print $2; exit}' "${job_file}" 2>/dev/null || true)"
expected_job_id="${expected_job_id:-${job_base%.job}}"

cycle_log="${LOG_DIR}/job-cycle-${cycle_stamp}-$$.log"

bash "${APP_DIR}/scripts/run_job_once.sh" >"${cycle_log}" 2>&1
runner_rc=$?
cat "${cycle_log}"

runner_status="$(extract_status "${cycle_log}" "JOB_RUNNER_STATUS")"
runner_status="${runner_status:-UNKNOWN}"

if [[ ! -r "${LATEST_REPORT}" ]] || ! grep -Fq -- "- Job ID: ${expected_job_id}" "${LATEST_REPORT}"; then
  generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo "# AI Council Job Run"
    echo
    echo "- Generated At: ${generated_at}"
    echo "- Hostname: $(hostname)"
    echo "- Job ID: ${expected_job_id}"
    echo "- Job Type: ${expected_job_type}"
    echo "- Repo Name: ${expected_repo_name}"
    echo "- Request Source: ${expected_request_source}"
    echo "- Requested By: ${expected_requested_by}"
    echo "- Created At: ${expected_created_at}"
    echo "- Status Reason: runner exited before producing its normal per-job report"
    echo "- Cycle Log: ${cycle_log}"
    echo
    echo "## Runner Output"
    echo
    echo '```text'
    tail -n 160 "${cycle_log}"
    echo '```'
    echo
    echo "JOB_RUNNER_STATUS: ERROR"
  } >"${LATEST_REPORT}"
  runner_status="ERROR"
fi

ai_exec_status="$(extract_status "${LATEST_REPORT}" "AI_EXEC_STATUS")"
job_deferred=0

if [[ "${runner_rc}" -ne 0 ]]; then
  retry_delay=0
  case "${ai_exec_status}" in
    RATE_LIMITED)
      retry_delay=300
      ;;
    HOURLY_LIMIT)
      retry_delay=3600
      ;;
    DAILY_LIMIT)
      retry_delay=86400
      ;;
    OUT_OF_HOURS)
      retry_delay=3600
      ;;
  esac

  if [[ "${retry_delay}" -gt 0 && -f "${FAILED_DIR}/${job_base}" ]]; then
    retry_at_epoch="$(( $(date -u +%s) + retry_delay ))"
    retry_at_iso="$(date -u -d "@${retry_at_epoch}" +'%Y-%m-%dT%H:%M:%SZ')"
    mv "${FAILED_DIR}/${job_base}" "${DEFERRED_DIR}/${job_base}"
    printf '%s\n' "${retry_at_epoch}" >"${DEFERRED_DIR}/${job_base}.retry_at"
    {
      echo "- Retry State: deferred"
      echo "- Retry After: ${retry_at_iso}"
      echo "JOB_RUNNER_STATUS: DEFERRED"
    } >>"${LATEST_REPORT}"
    runner_status="DEFERRED"
    job_deferred=1
  fi
fi

report_file="${REPORT_DIR}/${expected_job_id}-${cycle_stamp}.md"
cp "${LATEST_REPORT}" "${report_file}"

if [[ "${expected_request_source}" =~ ^github_issue_[0-9]+$ ]]; then
  cp "${report_file}" "${PENDING_POST_DIR}/$(basename "${report_file}")"
fi

report_log="${LOG_DIR}/job-cycle-report-${cycle_stamp}-$$.log"
bash "${APP_DIR}/scripts/report_job_result.sh" >"${report_log}" 2>&1
report_rc=$?
cat "${report_log}"

post_rc=0
if ! post_pending_reports; then
  post_rc=1
fi

echo "RUN_JOB_ONCE_EXIT: ${runner_rc}"
echo "REPORT_JOB_RESULT_EXIT: ${report_rc}"
echo "POST_PENDING_REPORTS_EXIT: ${post_rc}"

if [[ "${report_rc}" -ne 0 ]]; then
  echo "JOB_CYCLE_STATUS: REPORT_ERROR"
  exit 1
fi

if [[ "${post_rc}" -ne 0 ]]; then
  echo "JOB_CYCLE_STATUS: POST_BLOCKED"
  exit 1
fi

if [[ "${job_deferred}" -eq 1 ]]; then
  echo "JOB_CYCLE_STATUS: DEFERRED"
  exit 0
fi

if [[ "${runner_rc}" -ne 0 ]]; then
  echo "JOB_CYCLE_STATUS: JOB_ERROR_REPORTED"
  exit 0
fi

echo "JOB_CYCLE_STATUS: OK"
