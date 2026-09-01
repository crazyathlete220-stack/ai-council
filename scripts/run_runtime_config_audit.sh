#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

CONFIG_FILE="${1:-${AI_COUNCIL_RUNTIME_CONFIG:-/etc/ai-council/runtime.env}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate_runtime_config.sh"
BRIDGE_SERVICE="${AI_COUNCIL_GITHUB_BRIDGE_SERVICE_NAME:-ai-council-github-bridge.service}"
RUNNER_SERVICE="${AI_COUNCIL_JOB_RUNNER_SERVICE_NAME:-ai-council-job-runner.service}"

config_value() {
  local file="$1"
  local wanted="$2"
  awk -F= -v wanted="${wanted}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == wanted {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "${file}"
}

unit_config_source() {
  local unit="$1"
  local sources=""

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'UNKNOWN'
    return 0
  fi

  sources="$(systemctl show "${unit}" -p EnvironmentFiles --value 2>/dev/null || true)"
  if [[ -z "${sources}" ]]; then
    printf 'MISSING'
  elif grep -Fq "${CONFIG_FILE}" <<< "${sources}"; then
    printf 'SHARED'
  else
    printf 'MISMATCH'
  fi
}

if [[ ! -r "${VALIDATOR}" ]]; then
  echo "RUNTIME_CONFIG_STATUS: ERROR"
  echo "RUNTIME_CONFIG_ERROR: validator_missing"
  echo "RUNTIME_CONFIG_RECOVERY_STATUS: BLOCKED_RUNTIME_CONFIG"
  echo "RUNTIME_CONFIG_AUDIT_STATUS: COMPLETE"
  exit 1
fi

set +e
validator_output="$(bash "${VALIDATOR}" "${CONFIG_FILE}" 2>&1)"
validator_status=$?
set -e

if [[ "${validator_status}" -ne 0 ]]; then
  safe_error="$(printf '%s\n' "${validator_output}" | tail -n 1 | sed -E 's/[[:space:]]+/ /g; s/^ERROR: //')"
  echo "RUNTIME_CONFIG_STATUS: ERROR"
  echo "RUNTIME_CONFIG_ERROR: ${safe_error:-validation_failed}"
  echo "RUNTIME_CONFIG_RECOVERY_STATUS: BLOCKED_RUNTIME_CONFIG"
  echo "RUNTIME_CONFIG_AUDIT_STATUS: COMPLETE"
  exit 1
fi

repo="$(config_value "${CONFIG_FILE}" AI_COUNCIL_GITHUB_REPO)"
label="$(config_value "${CONFIG_FILE}" AI_COUNCIL_GITHUB_JOB_LABEL)"
allowlist_file="$(config_value "${CONFIG_FILE}" AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE)"
config_mode="$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || true)"
bridge_config_source="$(unit_config_source "${BRIDGE_SERVICE}")"
runner_config_source="$(unit_config_source "${RUNNER_SERVICE}")"

github_repo_access="NG"
github_repo_visibility="UNKNOWN"
github_label_status="UNKNOWN"
if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
  set +e
  github_repo_visibility="$(gh repo view "${repo}" --json visibility --jq '.visibility' 2>/dev/null)"
  repo_status=$?
  set -e
  if [[ "${repo_status}" -eq 0 && -n "${github_repo_visibility}" ]]; then
    github_repo_access="OK"
    if gh label list --repo "${repo}" --limit 100 --json name --jq '.[].name' 2>/dev/null | grep -Fxq "${label}"; then
      github_label_status="OK"
    else
      github_label_status="MISSING"
    fi
  fi
fi

allowlist_status="MISSING"
allowlist_count=0
allowlist_mode="UNKNOWN"
if [[ -L "${allowlist_file}" ]]; then
  allowlist_status="SYMLINK_REJECTED"
elif [[ -r "${allowlist_file}" ]]; then
  allowlist_mode="$(stat -c '%a' "${allowlist_file}" 2>/dev/null || true)"
  invalid_allowlist_lines="$(awk '
    {
      line=$0
      sub(/#.*/, "", line)
      gsub(/[[:space:]]/, "", line)
      if (line == "") next
      if (line !~ /^[A-Za-z0-9-]+$/) invalid++
      else valid++
    }
    END { print invalid+0 ":" valid+0 }
  ' "${allowlist_file}")"
  invalid_count="${invalid_allowlist_lines%%:*}"
  allowlist_count="${invalid_allowlist_lines#*:}"
  allowlist_mode_value=0
  if [[ "${allowlist_mode}" =~ ^[0-7]{3,4}$ ]]; then
    allowlist_mode_value=$((8#${allowlist_mode}))
  fi
  if [[ "${invalid_count}" -gt 0 ]]; then
    allowlist_status="INVALID_LINES"
  elif [[ "${allowlist_count}" -eq 0 ]]; then
    allowlist_status="EMPTY"
  elif (( allowlist_mode_value & 0022 )); then
    allowlist_status="UNSAFE_MODE"
  else
    allowlist_status="OK"
  fi
elif [[ -e "${allowlist_file}" ]]; then
  allowlist_status="UNREADABLE"
fi

path_keys=(
  AI_COUNCIL_WORKSPACE_REGISTRY_DIR
  AI_COUNCIL_JOB_ROOT
  AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT
  AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR
  AI_COUNCIL_JOB_LOG_DIR
  AI_COUNCIL_AI_WORKER_LOG_ROOT
)
paths_missing=0
paths_unwritable=0
for key in "${path_keys[@]}"; do
  path="$(config_value "${CONFIG_FILE}" "${key}")"
  if [[ ! -d "${path}" ]]; then
    paths_missing=$((paths_missing + 1))
  elif [[ ! -w "${path}" ]]; then
    paths_unwritable=$((paths_unwritable + 1))
  fi
done
paths_status="OK"
if [[ "${paths_missing}" -gt 0 ]]; then
  paths_status="MISSING"
elif [[ "${paths_unwritable}" -gt 0 ]]; then
  paths_status="UNWRITABLE"
fi

recovery_status="READY"
result_status=0
if [[ "${bridge_config_source}" != "SHARED" || "${runner_config_source}" != "SHARED" ]]; then
  recovery_status="BLOCKED_UNIT_CONFIG_MISMATCH"
  result_status=1
elif [[ "${github_repo_access}" != "OK" ]]; then
  recovery_status="BLOCKED_GITHUB_REPO_ACCESS"
  result_status=1
elif [[ "${github_label_status}" != "OK" ]]; then
  recovery_status="BLOCKED_GITHUB_LABEL"
  result_status=1
elif [[ "${allowlist_status}" != "OK" ]]; then
  recovery_status="BLOCKED_ALLOWLIST"
  result_status=1
elif [[ "${paths_status}" != "OK" ]]; then
  recovery_status="BLOCKED_RUNTIME_PATHS"
  result_status=1
fi

cat <<EOF_REPORT
RUNTIME_CONFIG_STATUS: OK
RUNTIME_CONFIG_REPO: ${repo}
RUNTIME_CONFIG_LABEL: ${label}
RUNTIME_CONFIG_MODE: ${config_mode:-UNKNOWN}
BRIDGE_CONFIG_SOURCE: ${bridge_config_source}
RUNNER_CONFIG_SOURCE: ${runner_config_source}
GITHUB_REPO_ACCESS: ${github_repo_access}
GITHUB_REPO_VISIBILITY: ${github_repo_visibility:-UNKNOWN}
GITHUB_LABEL_STATUS: ${github_label_status}
ALLOWLIST_STATUS: ${allowlist_status}
ALLOWLIST_ENTRY_COUNT: ${allowlist_count}
ALLOWLIST_MODE: ${allowlist_mode}
RUNTIME_PATHS_STATUS: ${paths_status}
RUNTIME_PATHS_MISSING_COUNT: ${paths_missing}
RUNTIME_PATHS_UNWRITABLE_COUNT: ${paths_unwritable}
RUNTIME_CONFIG_RECOVERY_STATUS: ${recovery_status}
RUNTIME_CONFIG_AUDIT_STATUS: COMPLETE
EOF_REPORT

exit "${result_status}"
