#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_name="${1:-ai-council}"
job_id="${AI_COUNCIL_JOB_ID:-manual-$(date -u +"%Y%m%dT%H%M%SZ")}"
request_source="${AI_COUNCIL_REQUEST_SOURCE:-manual}"
github_repo="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
app_dir="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
log_root="${AI_COUNCIL_AI_WORKER_LOG_ROOT:-/var/log/ai-council/ai-worker}"
core_script="${app_dir}/scripts/run_ai_check_core.sh"
audit_script="${app_dir}/scripts/run_runtime_audit.sh"

audit_profile="${AI_COUNCIL_AUDIT_PROFILE:-}"
audit_repo="${AI_COUNCIL_AUDIT_REPO:-ai-council-private}"
audit_issues="${AI_COUNCIL_AUDIT_ISSUES:-}"
audit_expected_runtime_commit="${AI_COUNCIL_AUDIT_EXPECTED_RUNTIME_COMMIT:-}"
audit_expected_private_commit="${AI_COUNCIL_AUDIT_EXPECTED_PRIVATE_COMMIT:-}"
issue_body=""

extract_setting() {
  local setting="$1"
  printf '%s\n' "${issue_body}" | awk -F= -v wanted="${setting}" '
    $1 == wanted {
      sub(/^[^=]*=/, "")
      gsub(/[[:space:]]/, "")
      print
      exit
    }
  '
}

append_to_check_artifact() {
  local text="$1"
  local check_file="${log_root}/${job_id}/check.md"
  local latest_check="${log_root}/latest-check.md"

  if [[ -f "${check_file}" ]]; then
    printf '\n%s\n' "${text}" >> "${check_file}"
    cp "${check_file}" "${latest_check}"
  fi
}

if [[ ! -r "${core_script}" ]]; then
  echo "ERROR: generic ai_check core is not readable: ${core_script}" >&2
  echo "AI_CHECK_STATUS: ERROR"
  exit 1
fi

if [[ "${request_source}" =~ ^github_issue_([0-9]+)$ ]] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
  issue_number="${BASH_REMATCH[1]}"
  issue_json="$(gh issue view "${issue_number}" --repo "${github_repo}" --json body 2>/dev/null || true)"
  if [[ -n "${issue_json}" ]]; then
    issue_body="$(printf '%s' "${issue_json}" | jq -r '.body // ""')"
  fi
fi

if [[ -n "${issue_body}" ]]; then
  audit_profile="${audit_profile:-$(extract_setting AUDIT_PROFILE)}"
  audit_repo="${AI_COUNCIL_AUDIT_REPO:-$(extract_setting AUDIT_REPO)}"
  audit_repo="${audit_repo:-ai-council-private}"
  audit_issues="${audit_issues:-$(extract_setting AUDIT_ISSUES)}"
  audit_expected_runtime_commit="${audit_expected_runtime_commit:-$(extract_setting AUDIT_EXPECTED_RUNTIME_COMMIT)}"
  audit_expected_private_commit="${audit_expected_private_commit:-$(extract_setting AUDIT_EXPECTED_PRIVATE_COMMIT)}"
fi

if [[ -z "${audit_profile}" ]]; then
  exec bash "${core_script}" "$@"
fi

profile_error=""
if [[ "${audit_profile}" != "runtime" ]]; then
  profile_error="unsupported AUDIT_PROFILE: ${audit_profile}"
elif [[ ! "${audit_repo}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  profile_error="unsafe AUDIT_REPO"
elif [[ -n "${audit_issues}" && ! "${audit_issues}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
  profile_error="AUDIT_ISSUES must be comma-separated numeric issue IDs"
elif [[ -n "${audit_expected_runtime_commit}" && ! "${audit_expected_runtime_commit}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  profile_error="invalid AUDIT_EXPECTED_RUNTIME_COMMIT"
elif [[ -n "${audit_expected_private_commit}" && ! "${audit_expected_private_commit}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  profile_error="invalid AUDIT_EXPECTED_PRIVATE_COMMIT"
elif [[ ! -r "${audit_script}" ]]; then
  profile_error="runtime audit script is not readable: ${audit_script}"
fi

set +e
bash "${core_script}" "$@"
core_status=$?
set -e

if [[ -n "${profile_error}" ]]; then
  profile_output="$(cat <<EOF_PROFILE_ERROR
RUNTIME_AUDIT_OUTPUT_BEGIN
AUDIT_PROFILE: ${audit_profile}
AUDIT_PROFILE_STATUS: ERROR
RUNTIME_AUDIT_ERROR: ${profile_error}
RUNTIME_AUDIT_STATUS: ERROR
RUNTIME_AUDIT_OUTPUT_END
EOF_PROFILE_ERROR
)"
  printf '%s\n' "${profile_output}"
  append_to_check_artifact "${profile_output}"
  exit 1
fi

set +e
audit_body="$(bash "${audit_script}" "${audit_repo}" "${audit_issues}" "${audit_expected_runtime_commit}" "${audit_expected_private_commit}" 2>&1)"
audit_status=$?
set -e

profile_output="$(
  {
    echo "RUNTIME_AUDIT_OUTPUT_BEGIN"
    echo "AUDIT_PROFILE: runtime"
    echo "AUDIT_PROFILE_STATUS: OK"
    printf '%s\n' "${audit_body}"
    echo "RUNTIME_AUDIT_OUTPUT_END"
  }
)"

printf '%s\n' "${profile_output}"
append_to_check_artifact "${profile_output}"

if [[ "${core_status}" -ne 0 || "${audit_status}" -ne 0 ]]; then
  exit 1
fi

exit 0
