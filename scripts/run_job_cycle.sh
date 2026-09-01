#!/usr/bin/env bash
set -u

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
QUEUE_DIR="${JOB_ROOT}/queue"
ACTIVE_DIR="${JOB_ROOT}/active"
DONE_DIR="${JOB_ROOT}/done"
FAILED_DIR="${JOB_ROOT}/failed"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
LATEST_REPORT="${LOG_DIR}/latest-job-report.md"
LOCK_FILE="${JOB_ROOT}/runner.lock"
LOCK_WAIT_SECONDS="${AI_COUNCIL_JOB_LOCK_WAIT_SECONDS:-30}"

mkdir -p "${QUEUE_DIR}" "${ACTIVE_DIR}" "${DONE_DIR}" "${FAILED_DIR}" "${LOG_DIR}"

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

queued_before="$(find "${QUEUE_DIR}" -maxdepth 1 -type f -name '*.job' -printf '%f\n' 2>/dev/null | sort | head -n 1)"
expected_job_id=""
expected_job_type=""
expected_repo_name=""
expected_request_source=""
expected_requested_by=""
expected_created_at=""

if [[ -n "${queued_before}" && -r "${QUEUE_DIR}/${queued_before}" ]]; then
  expected_job_id="$(awk -F= '$1 == "JOB_ID" {print $2; exit}' "${QUEUE_DIR}/${queued_before}")"
  expected_job_type="$(awk -F= '$1 == "JOB_TYPE" {print $2; exit}' "${QUEUE_DIR}/${queued_before}")"
  expected_repo_name="$(awk -F= '$1 == "REPO_NAME" {print $2; exit}' "${QUEUE_DIR}/${queued_before}")"
  expected_request_source="$(awk -F= '$1 == "REQUEST_SOURCE" {print $2; exit}' "${QUEUE_DIR}/${queued_before}")"
  expected_requested_by="$(awk -F= '$1 == "REQUESTED_BY" {print $2; exit}' "${QUEUE_DIR}/${queued_before}")"
  expected_created_at="$(awk -F= '$1 == "CREATED_AT" {print $2; exit}' "${QUEUE_DIR}/${queued_before}")"
fi

cycle_stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
cycle_log="${LOG_DIR}/job-cycle-${cycle_stamp}-$$.log"

set +e
bash "${APP_DIR}/scripts/run_job_once.sh" >"${cycle_log}" 2>&1
runner_rc=$?
set -e
cat "${cycle_log}"

runner_status="$(grep -E 'JOB_RUNNER_STATUS:' "${cycle_log}" | tail -n 1 | awk -F': ' '{print $2}' | tr -d '[:space:]')"
runner_status="${runner_status:-UNKNOWN}"

if [[ "${runner_status}" == "IDLE" ]]; then
  echo "JOB_CYCLE_STATUS: IDLE"
  exit 0
fi

if [[ -n "${expected_job_id}" ]] && { [[ ! -r "${LATEST_REPORT}" ]] || ! grep -Fq -- "- Job ID: ${expected_job_id}" "${LATEST_REPORT}"; }; then
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
fi

report_log="${LOG_DIR}/job-cycle-report-${cycle_stamp}-$$.log"
post_log="${LOG_DIR}/job-cycle-post-${cycle_stamp}-$$.log"

set +e
bash "${APP_DIR}/scripts/report_job_result.sh" >"${report_log}" 2>&1
report_rc=$?
bash "${APP_DIR}/scripts/post_job_result_to_github.sh" >"${post_log}" 2>&1
post_rc=$?
set -e

cat "${report_log}"
cat "${post_log}"

echo "RUN_JOB_ONCE_EXIT: ${runner_rc}"
echo "REPORT_JOB_RESULT_EXIT: ${report_rc}"
echo "POST_JOB_RESULT_EXIT: ${post_rc}"

if [[ "${runner_rc}" -ne 0 || "${report_rc}" -ne 0 || "${post_rc}" -ne 0 ]]; then
  echo "JOB_CYCLE_STATUS: ERROR"
  exit 1
fi

echo "JOB_CYCLE_STATUS: OK"
