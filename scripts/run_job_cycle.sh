#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
CYCLE_LOG_DIR="${LOG_DIR}/cycles"
CLASSIFIER="${AI_COUNCIL_AI_EXEC_RESULT_CLASSIFIER:-${APP_DIR}/scripts/classify_ai_exec_result.sh}"
mkdir -p "${CYCLE_LOG_DIR}"

cycle_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
cycle_log="${CYCLE_LOG_DIR}/${cycle_stamp}-$$.log"

set +e
bash "${APP_DIR}/scripts/run_job_once.sh" 2>&1 | tee "${cycle_log}"
run_status="${PIPESTATUS[0]}"
set -e

report_path="$(awk -F': ' '/^JOB_REPORT_FILE: /{value=$2} END {print value}' "${cycle_log}")"
report_status=0
post_status=0
final_runner_status=""
job_type=""
job_id=""
request_source=""

append_contract_result() {
  local contract_status="$1"
  local marker="$2"
  local reason="$3"
  {
    echo
    echo "- Result Marker: ${marker}"
    echo "- Result Contract Status: ${contract_status}"
    echo "- Result Contract Reason: ${reason}"
  } >> "${report_path}"
}

move_done_job_to_failed() {
  local done_file=""
  local failed_file=""

  [[ -n "${job_id}" && "${job_id}" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  done_file="${JOB_ROOT}/done/${job_id}.job"
  failed_file="${JOB_ROOT}/failed/${job_id}.job"

  if [[ -f "${done_file}" && ! -e "${failed_file}" ]]; then
    mv "${done_file}" "${failed_file}"
    return 0
  fi
  [[ -f "${failed_file}" ]]
}

if [[ -n "${report_path}" && -r "${report_path}" ]]; then
  final_runner_status="$(awk -F': ' '/^JOB_RUNNER_STATUS: /{value=$2} END {print value}' "${report_path}")"
  job_type="$(awk -F': ' '/^- Job Type: /{print $2; exit}' "${report_path}")"
  job_id="$(awk -F': ' '/^- Job ID: /{print $2; exit}' "${report_path}")"
  request_source="$(awk -F': ' '/^- Request Source: /{print $2; exit}' "${report_path}")"

  if [[ "${job_type}" == "ai_exec" && "${request_source}" =~ ^github_issue_[0-9]+$ && "${final_runner_status}" == "OK" ]]; then
    last_message="$(awk -F': ' '/^- Last Message: /{print $2; exit}' "${report_path}")"
    contract_output=""
    contract_exit=22

    # The classifier is invoked through bash. Source checkouts created by the
    # GitHub Contents API can carry mode 0644, while runtime-manifest install
    # applies 0755. Readability is the correct cross-environment prerequisite.
    if [[ -r "${CLASSIFIER}" ]]; then
      set +e
      contract_output="$(bash "${CLASSIFIER}" "${last_message}" 2>&1)"
      contract_exit=$?
      set -e
    else
      contract_output=$'AI_EXEC_RESULT_CONTRACT_STATUS: INDETERMINATE\nAI_EXEC_RESULT_MARKER: MISSING_CLASSIFIER\nAI_EXEC_RESULT_REASON: classifier_not_readable'
    fi

    contract_status="$(printf '%s\n' "${contract_output}" | awk -F': ' '/^AI_EXEC_RESULT_CONTRACT_STATUS: /{print $2; exit}')"
    result_marker="$(printf '%s\n' "${contract_output}" | awk -F': ' '/^AI_EXEC_RESULT_MARKER: /{print $2; exit}')"
    contract_reason="$(printf '%s\n' "${contract_output}" | awk -F': ' '/^AI_EXEC_RESULT_REASON: /{print $2; exit}')"
    contract_status="${contract_status:-INDETERMINATE}"
    result_marker="${result_marker:-UNKNOWN}"
    contract_reason="${contract_reason:-classifier_output_invalid}"

    append_contract_result "${contract_status}" "${result_marker}" "${contract_reason}"

    case "${contract_exit}" in
      0)
        ;;
      20)
        {
          echo "AI_EXEC_STATUS: BLOCKED"
          echo "JOB_RUNNER_STATUS: ERROR"
        } >> "${report_path}"
        run_status=1
        move_done_job_to_failed || true
        ;;
      21)
        {
          echo "AI_EXEC_STATUS: FAILED"
          echo "JOB_RUNNER_STATUS: ERROR"
        } >> "${report_path}"
        run_status=1
        move_done_job_to_failed || true
        ;;
      *)
        {
          echo "AI_EXEC_STATUS: INDETERMINATE"
          echo "JOB_RUNNER_STATUS: ERROR"
        } >> "${report_path}"
        run_status=1
        move_done_job_to_failed || true
        ;;
    esac
  fi

  final_runner_status="$(awk -F': ' '/^JOB_RUNNER_STATUS: /{value=$2} END {print value}' "${report_path}")"

  # Defense in depth: a hard job error must fail the systemd cycle even if an
  # older runner implementation accidentally returned status 0.
  if [[ "${final_runner_status}" == "ERROR" && "${run_status}" -eq 0 ]]; then
    run_status=1
  fi

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
  echo "JOB_CYCLE_FINAL_RUNNER_STATUS: ${final_runner_status:-NONE}"
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

echo "JOB_CYCLE_FINAL_RUNNER_STATUS: ${final_runner_status:-UNKNOWN}" >&2
echo "JOB_CYCLE_STATUS: ERROR" >&2
exit 1
