#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
IMPORT_DIR="${STATE_ROOT}/imported"
REJECT_DIR="${STATE_ROOT}/rejected"
LOG_DIR="${AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR:-/var/log/ai-council/github-bridge}"
cycle_stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
cycle_log="${LOG_DIR}/bridge-cycle-${cycle_stamp}-$$.log"
latest_cycle="${LOG_DIR}/latest-cycle.log"

mkdir -p "${IMPORT_DIR}" "${REJECT_DIR}" "${LOG_DIR}"

snapshot_markers() {
  local directory="$1"
  local output_file="$2"
  find "${directory}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort >"${output_file}"
}

post_new_queue_comments() {
  local before_file="$1"
  local after_file="$2"
  local marker_name=""
  local marker_file=""
  local issue_number=""
  local job_id=""
  local job_type=""
  local repo_name=""
  local failures=0

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status --hostname github.com >/dev/null 2>&1; then
    return 1
  fi

  while IFS= read -r marker_name; do
    [[ -n "${marker_name}" ]] || continue
    marker_file="${IMPORT_DIR}/${marker_name}"
    [[ -r "${marker_file}" ]] || continue

    issue_number="$(awk -F= '$1 == "ISSUE_NUMBER" {print $2; exit}' "${marker_file}")"
    job_id="$(awk -F= '$1 == "JOB_ID" {print $2; exit}' "${marker_file}")"
    job_type="$(awk -F= '$1 == "JOB_TYPE" {print $2; exit}' "${marker_file}")"
    repo_name="$(awk -F= '$1 == "REPO_NAME" {print $2; exit}' "${marker_file}")"

    if [[ ! "${issue_number}" =~ ^[0-9]+$ ]]; then
      continue
    fi

    if ! gh issue comment "${issue_number}" --repo "${REPOSITORY}" --body "$(cat <<EOF
VPS_STATE: **QUEUED**

- Job ID: \`${job_id}\`
- Job Type: \`${job_type}\`
- Repo Name: \`${repo_name}\`
- Imported At: \`$(date -u +'%Y-%m-%dT%H:%M:%SZ')\`

This confirms bridge pickup and queue creation. It does not confirm execution success.
EOF
)" >/dev/null; then
      failures=$((failures + 1))
    fi
  done < <(comm -13 "${before_file}" "${after_file}")

  [[ "${failures}" -eq 0 ]]
}

run_cycle() {
  local before_imported=""
  local after_imported=""
  local import_log=""
  local import_rc=0
  local import_status=""
  local job_cycle_rc=0
  local queue_comment_status="OK"

  before_imported="$(mktemp)"
  after_imported="$(mktemp)"
  import_log="${LOG_DIR}/import-${cycle_stamp}-$$.log"
  trap 'rm -f "${before_imported}" "${after_imported}"' RETURN

  echo "AI Council GitHub bridge cycle"
  echo "Generated At: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Repository: ${REPOSITORY}"
  echo

  snapshot_markers "${IMPORT_DIR}" "${before_imported}"
  bash "${APP_DIR}/scripts/import_github_jobs.sh" >"${import_log}" 2>&1
  import_rc=$?
  cat "${import_log}"
  snapshot_markers "${IMPORT_DIR}" "${after_imported}"

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
      return 1
      ;;
    *)
      if [[ "${import_rc}" -ne 0 || "${import_status}" == "UNKNOWN" ]]; then
        echo "GITHUB_BRIDGE_CYCLE_STATUS: IMPORT_ERROR"
        return 1
      fi
      ;;
  esac

  if ! post_new_queue_comments "${before_imported}" "${after_imported}"; then
    queue_comment_status="ERROR"
    echo "WARNING: one or more QUEUED comments could not be posted" >&2
  fi
  echo "QUEUE_COMMENT_STATUS: ${queue_comment_status}"

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
