#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
IMPORT_DIR="${STATE_ROOT}/imported"
REJECT_DIR="${STATE_ROOT}/rejected"
BLOCKED_DIR="${STATE_ROOT}/blocked"
STATE_EVENT_DIR="${STATE_ROOT}/state-events"
STATE_EVENT_POSTED_DIR="${STATE_ROOT}/state-events-posted"
LOG_DIR="${AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR:-/var/log/ai-council/github-bridge}"
cycle_stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
cycle_log="${LOG_DIR}/bridge-cycle-${cycle_stamp}-$$.log"
latest_cycle="${LOG_DIR}/latest-cycle.log"

mkdir -p \
  "${IMPORT_DIR}" "${REJECT_DIR}" "${BLOCKED_DIR}" \
  "${STATE_EVENT_DIR}" "${STATE_EVENT_POSTED_DIR}" "${LOG_DIR}"

snapshot_markers() {
  local directory="$1"
  local output_file="$2"
  find "${directory}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort >"${output_file}"
}

enqueue_new_state_events() {
  local event_type="$1"
  local marker_dir="$2"
  local before_file="$3"
  local after_file="$4"
  local marker_name=""
  local marker_file=""
  local event_file=""
  local event_tmp=""

  while IFS= read -r marker_name; do
    [[ -n "${marker_name}" ]] || continue
    marker_file="${marker_dir}/${marker_name}"
    [[ -r "${marker_file}" ]] || continue

    event_file="${STATE_EVENT_DIR}/${event_type}-${marker_name}.event"
    [[ -e "${event_file}" ]] && continue

    event_tmp="${event_file}.tmp.$$"
    {
      echo "EVENT_TYPE=${event_type}"
      cat "${marker_file}"
    } >"${event_tmp}"
    mv "${event_tmp}" "${event_file}"
  done < <(comm -13 "${before_file}" "${after_file}")
}

post_state_event() {
  local event_file="$1"
  local event_type=""
  local issue_number=""
  local job_id=""
  local job_type=""
  local repo_name=""
  local reason=""
  local recovery=""
  local event_time=""
  local body=""

  event_type="$(awk -F= '$1 == "EVENT_TYPE" {print $2; exit}' "${event_file}")"
  issue_number="$(awk -F= '$1 == "ISSUE_NUMBER" {print $2; exit}' "${event_file}")"
  job_id="$(awk -F= '$1 == "JOB_ID" {print $2; exit}' "${event_file}")"
  job_type="$(awk -F= '$1 == "JOB_TYPE" {print $2; exit}' "${event_file}")"
  repo_name="$(awk -F= '$1 == "REPO_NAME" {print $2; exit}' "${event_file}")"
  reason="$(awk -F= '$1 == "REASON" {print substr($0, index($0, "=") + 1); exit}' "${event_file}")"
  recovery="$(awk -F= '$1 == "RECOVERY" {print substr($0, index($0, "=") + 1); exit}' "${event_file}")"

  if [[ ! "${issue_number}" =~ ^[0-9]+$ ]]; then
    echo "Invalid state event issue number: ${event_file}" >&2
    return 1
  fi

  case "${event_type}" in
    QUEUED)
      event_time="$(awk -F= '$1 == "IMPORTED_AT" {print $2; exit}' "${event_file}")"
      body="$(cat <<EOF
VPS_STATE: **QUEUED**

- Job ID: \`${job_id}\`
- Job Type: \`${job_type}\`
- Repo Name: \`${repo_name}\`
- Imported At: \`${event_time:-unknown}\`

This confirms bridge pickup and queue creation. It does not confirm execution success.
EOF
)"
      ;;
    BLOCKED)
      event_time="$(awk -F= '$1 == "BLOCKED_AT" {print $2; exit}' "${event_file}")"
      body="$(cat <<EOF
VPS_STATE: **BLOCKED**

- Job Type: \`${job_type}\`
- Repo Name: \`${repo_name}\`
- Reason: \`${reason:-UNKNOWN}\`
- Detected At: \`${event_time:-unknown}\`
- Recovery: ${recovery:-inspect the bridge recovery runbook}

No job was created. The bridge will re-check this Issue after the blocking condition is repaired.
EOF
)"
      ;;
    REJECTED)
      event_time="$(awk -F= '$1 == "REJECTED_AT" {print $2; exit}' "${event_file}")"
      body="$(cat <<EOF
VPS_STATE: **REJECTED**

- Reason: \`${reason:-UNKNOWN}\`
- Detected At: \`${event_time:-unknown}\`

No job was created. Correct the Issue fields or author authorization before retrying.
EOF
)"
      ;;
    *)
      echo "Unknown state event type in ${event_file}: ${event_type}" >&2
      return 1
      ;;
  esac

  gh issue comment "${issue_number}" --repo "${REPOSITORY}" --body "${body}" >/dev/null
}

post_pending_state_events() {
  local event_files=()
  local event_file=""
  local posted_file=""

  shopt -s nullglob
  event_files=("${STATE_EVENT_DIR}"/*.event)
  shopt -u nullglob

  if [[ "${#event_files[@]}" -eq 0 ]]; then
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status --hostname github.com >/dev/null 2>&1; then
    echo "State events are pending but GitHub authentication is unavailable." >&2
    return 1
  fi

  for event_file in "${event_files[@]}"; do
    if ! post_state_event "${event_file}"; then
      echo "Pending state event retained: ${event_file}" >&2
      return 1
    fi

    posted_file="${STATE_EVENT_POSTED_DIR}/$(basename "${event_file}" .event).posted"
    {
      cat "${event_file}"
      echo "POSTED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    } >"${posted_file}"
    rm -f "${event_file}"
  done

  return 0
}

run_cycle() {
  local before_imported=""
  local after_imported=""
  local before_blocked=""
  local after_blocked=""
  local before_rejected=""
  local after_rejected=""
  local import_log=""
  local import_rc=0
  local import_status=""
  local job_cycle_rc=0

  before_imported="$(mktemp)"
  after_imported="$(mktemp)"
  before_blocked="$(mktemp)"
  after_blocked="$(mktemp)"
  before_rejected="$(mktemp)"
  after_rejected="$(mktemp)"
  import_log="${LOG_DIR}/import-${cycle_stamp}-$$.log"

  cleanup_cycle_temp() {
    rm -f \
      "${before_imported}" "${after_imported}" \
      "${before_blocked}" "${after_blocked}" \
      "${before_rejected}" "${after_rejected}"
  }

  echo "AI Council GitHub bridge cycle"
  echo "Generated At: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Repository: ${REPOSITORY}"
  echo

  if ! post_pending_state_events; then
    echo "GITHUB_BRIDGE_CYCLE_STATUS: STATE_COMMENT_BLOCKED"
    cleanup_cycle_temp
    return 1
  fi

  snapshot_markers "${IMPORT_DIR}" "${before_imported}"
  snapshot_markers "${BLOCKED_DIR}" "${before_blocked}"
  snapshot_markers "${REJECT_DIR}" "${before_rejected}"

  bash "${APP_DIR}/scripts/import_github_jobs.sh" >"${import_log}" 2>&1
  import_rc=$?
  cat "${import_log}"

  snapshot_markers "${IMPORT_DIR}" "${after_imported}"
  snapshot_markers "${BLOCKED_DIR}" "${after_blocked}"
  snapshot_markers "${REJECT_DIR}" "${after_rejected}"

  enqueue_new_state_events "QUEUED" "${IMPORT_DIR}" "${before_imported}" "${after_imported}"
  enqueue_new_state_events "BLOCKED" "${BLOCKED_DIR}" "${before_blocked}" "${after_blocked}"
  enqueue_new_state_events "REJECTED" "${REJECT_DIR}" "${before_rejected}" "${after_rejected}"

  import_status="$(awk -F': ' '$1 == "GITHUB_JOB_IMPORT_STATUS" {print $2}' "${import_log}" | tail -n 1 | tr -d '[:space:]')"
  import_status="${import_status:-UNKNOWN}"

  echo
  echo "IMPORT_GITHUB_JOBS_EXIT: ${import_rc}"
  echo "IMPORT_GITHUB_JOBS_STATUS: ${import_status}"

  case "${import_status}" in
    OK | NO_MATCHING_ISSUES)
      ;;
    AUTH_REQUIRED | ALLOWLIST_REQUIRED)
      echo "GITHUB_BRIDGE_CYCLE_STATUS: ENTRY_BLOCKED"
      cleanup_cycle_temp
      return 1
      ;;
    *)
      if [[ "${import_rc}" -ne 0 || "${import_status}" == "UNKNOWN" ]]; then
        echo "GITHUB_BRIDGE_CYCLE_STATUS: IMPORT_ERROR"
        cleanup_cycle_temp
        return 1
      fi
      ;;
  esac

  if ! post_pending_state_events; then
    echo "GITHUB_BRIDGE_CYCLE_STATUS: STATE_COMMENT_BLOCKED"
    cleanup_cycle_temp
    return 1
  fi
  echo "STATE_COMMENT_STATUS: OK"
  cleanup_cycle_temp

  echo
  bash "${APP_DIR}/scripts/run_job_cycle.sh"
  job_cycle_rc=$?

  echo
  echo "RUN_JOB_CYCLE_EXIT: ${job_cycle_rc}"

  if [[ "${job_cycle_rc}" -ne 0 ]]; then
    echo "GITHUB_BRIDGE_CYCLE_STATUS: JOB_OR_POST_ERROR"
    return 1
  fi

  echo "GITHUB_BRIDGE_CYCLE_STATUS: OK"
  return 0
}

run_cycle > >(tee "${cycle_log}" "${latest_cycle}") 2>&1
cycle_rc=$?
exit "${cycle_rc}"
