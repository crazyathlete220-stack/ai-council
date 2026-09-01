#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
LABEL="${AI_COUNCIL_GITHUB_JOB_LABEL:-vps-job}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
LOG_DIR="${AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR:-/var/log/ai-council/github-bridge}"
IMPORT_DIR="${STATE_ROOT}/imported"
REJECT_DIR="${STATE_ROOT}/rejected"
BLOCKED_DIR="${STATE_ROOT}/blocked"
REJECT_LOG="${LOG_DIR}/rejected-issues.log"
BLOCKED_LOG="${LOG_DIR}/blocked-issues.log"
ALLOWLIST_FILE="${AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE:-/etc/ai-council/github-bridge-allowlist}"
REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
WORKSPACE_ROOT="${AI_COUNCIL_WORKSPACE_ROOT:-/opt/ai-workspaces}"
OPERATOR_USER="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
SCAN_LIMIT="${AI_COUNCIL_GITHUB_SCAN_LIMIT:-1000}"
IMPORT_LIMIT="${AI_COUNCIL_GITHUB_IMPORT_LIMIT:-20}"

mkdir -p "${IMPORT_DIR}" "${REJECT_DIR}" "${BLOCKED_DIR}" "${LOG_DIR}"

for numeric_value in "${SCAN_LIMIT}" "${IMPORT_LIMIT}"; do
  if [[ ! "${numeric_value}" =~ ^[0-9]+$ || "${numeric_value}" -lt 1 ]]; then
    echo "GITHUB_JOB_IMPORT_STATUS: CONFIG_ERROR" >&2
    echo "Reason: scan/import limits must be positive integers." >&2
    exit 1
  fi
done

derive_casual_job() {
  local request_text="$1"
  local request_text_lc=""

  request_text_lc="$(printf "%s" "${request_text}" | tr "[:upper:]" "[:lower:]")"

  if printf "%s" "${request_text_lc}" | grep -Eq "ai_plan|計画|作戦|方針|plan|プラン"; then
    job_type="ai_plan"
    repo_name="ai-council"
    return 0
  fi

  if printf "%s" "${request_text_lc}" | grep -Eq "ai_check|検証|安全確認して|安全確認を|安全に確認|チェックだけ|確認だけ|check only"; then
    job_type="ai_check"
    repo_name="ai-council"
    return 0
  fi

  if printf "%s" "${request_text_lc}" | grep -Eq "workspace_summary|作業場|ワークスペース|workspace|一覧|まとめ|サマリー"; then
    job_type="workspace_summary"
    repo_name="all"
    return 0
  fi

  if printf "%s" "${request_text_lc}" | grep -Eq "repo_check|ai-council.*(状態|確認|チェック)|ヘルス|health|repo|リポジトリ"; then
    job_type="repo_check"
    repo_name="ai-council"
    return 0
  fi

  return 1
}

author_allowed() {
  local author="$1"
  local author_lc=""
  local allowed_seen=0
  local line=""
  local line_lc=""

  if [[ ! -r "${ALLOWLIST_FILE}" ]]; then
    return 2
  fi

  author_lc="$(printf "%s" "${author}" | tr "[:upper:]" "[:lower:]")"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="$(printf "%s" "${line}" | tr -d "[:space:]")"

    if [[ -z "${line}" ]]; then
      continue
    fi

    allowed_seen=1

    if [[ ! "${line}" =~ ^[A-Za-z0-9-]+$ ]]; then
      continue
    fi

    line_lc="$(printf "%s" "${line}" | tr "[:upper:]" "[:lower:]")"
    if [[ "${line_lc}" == "${author_lc}" ]]; then
      return 0
    fi
  done < "${ALLOWLIST_FILE}"

  if [[ "${allowed_seen}" -eq 0 ]]; then
    return 3
  fi

  return 1
}

reject_issue() {
  local issue_number="$1"
  local issue_author="$2"
  local reason="$3"
  local rejected_marker="${REJECT_DIR}/issue-${issue_number}-${reason}.rejected"

  find "${REJECT_DIR}" -maxdepth 1 -type f -name "issue-${issue_number}-*.rejected" ! -name "$(basename "${rejected_marker}")" -delete 2>/dev/null || true

  if [[ ! -f "${rejected_marker}" ]]; then
    {
      printf "REJECTED_AT=%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      printf "ISSUE_NUMBER=%s\n" "${issue_number}"
      printf "ISSUE_AUTHOR=%s\n" "${issue_author}"
      printf "REASON=%s\n" "${reason}"
    } > "${rejected_marker}"

    printf "%s issue=%s author=%s reason=%s\n" \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      "${issue_number}" \
      "${issue_author}" \
      "${reason}" >> "${REJECT_LOG}"
  fi
}

block_issue() {
  local issue_number="$1"
  local issue_author="$2"
  local job_type_value="$3"
  local repo_name_value="$4"
  local reason="$5"
  local recovery="$6"
  local blocked_marker="${BLOCKED_DIR}/issue-${issue_number}-${reason}.blocked"

  find "${BLOCKED_DIR}" -maxdepth 1 -type f -name "issue-${issue_number}-*.blocked" ! -name "$(basename "${blocked_marker}")" -delete 2>/dev/null || true

  if [[ ! -f "${blocked_marker}" ]]; then
    {
      printf "BLOCKED_AT=%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      printf "ISSUE_NUMBER=%s\n" "${issue_number}"
      printf "ISSUE_AUTHOR=%s\n" "${issue_author}"
      printf "JOB_TYPE=%s\n" "${job_type_value}"
      printf "REPO_NAME=%s\n" "${repo_name_value}"
      printf "REASON=%s\n" "${reason}"
      printf "RECOVERY=%s\n" "${recovery}"
    } > "${blocked_marker}"

    printf "%s issue=%s author=%s job_type=%s repo=%s reason=%s\n" \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      "${issue_number}" \
      "${issue_author}" \
      "${job_type_value}" \
      "${repo_name_value}" \
      "${reason}" >> "${BLOCKED_LOG}"
  fi
}

clear_issue_blocks() {
  local issue_number="$1"
  find "${BLOCKED_DIR}" -maxdepth 1 -type f -name "issue-${issue_number}-*.blocked" -delete 2>/dev/null || true
}

workspace_preflight() {
  local job_type_value="$1"
  local repo_name_value="$2"
  local config_file="${REGISTRY_DIR}/${repo_name_value}.env"
  local config_owner=""
  local config_mode=""
  local config_mode_decimal=0
  local configured_repo_name=""
  local configured_repo_path=""
  local configured_log_dir=""
  local repo_real=""
  local root_real=""

  workspace_block_reason=""
  workspace_recovery=""

  if [[ "${job_type_value}" == "workspace_summary" || "${repo_name_value}" == "all" ]]; then
    return 0
  fi

  if [[ ! -r "${config_file}" ]]; then
    workspace_block_reason="WORKSPACE_NOT_REGISTERED"
    workspace_recovery="register ${repo_name_value} under ${REGISTRY_DIR}"
    return 1
  fi

  config_owner="$(stat -c '%U' "${config_file}" 2>/dev/null || true)"
  config_mode="$(stat -c '%a' "${config_file}" 2>/dev/null || true)"
  if [[ "${config_owner}" != "root" || ! "${config_mode}" =~ ^[0-7]{3,4}$ ]]; then
    workspace_block_reason="WORKSPACE_CONFIG_UNSAFE"
    workspace_recovery="restore a root-owned non-writable workspace config"
    return 1
  fi
  config_mode_decimal=$((8#${config_mode}))
  if (( (config_mode_decimal & 0022) != 0 )); then
    workspace_block_reason="WORKSPACE_CONFIG_UNSAFE"
    workspace_recovery="remove group/world write permission from ${config_file}"
    return 1
  fi

  REPO_NAME=""
  REPO_PATH=""
  LOG_DIR=""
  # shellcheck disable=SC1090
  source "${config_file}"
  configured_repo_name="${REPO_NAME:-}"
  configured_repo_path="${REPO_PATH:-}"
  configured_log_dir="${LOG_DIR:-}"

  if [[ "${configured_repo_name}" != "${repo_name_value}" ]]; then
    workspace_block_reason="WORKSPACE_CONFIG_MISMATCH"
    workspace_recovery="re-register ${repo_name_value}; registry name does not match"
    return 1
  fi

  if [[ -z "${configured_repo_path}" || ! -d "${configured_repo_path}/.git" ]]; then
    workspace_block_reason="WORKSPACE_SOURCE_MISSING"
    workspace_recovery="place a Git checkout at ${WORKSPACE_ROOT}/${repo_name_value} and re-register it"
    return 1
  fi

  repo_real="$(realpath -e "${configured_repo_path}" 2>/dev/null || true)"
  root_real="$(realpath -e "${WORKSPACE_ROOT}" 2>/dev/null || true)"
  if [[ -z "${repo_real}" || -z "${root_real}" || "${repo_real}" != "${root_real}/"* ]]; then
    workspace_block_reason="WORKSPACE_PATH_OUTSIDE_ROOT"
    workspace_recovery="move and register the workspace under ${WORKSPACE_ROOT}"
    return 1
  fi

  if [[ -z "${configured_log_dir}" ]]; then
    workspace_block_reason="WORKSPACE_LOG_UNSET"
    workspace_recovery="re-register ${repo_name_value} with a valid log directory"
    return 1
  fi

  if [[ "${job_type_value}" == "ai_exec" || "${job_type_value}" == "repo_check" ]]; then
    if ! id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
      workspace_block_reason="OPERATOR_USER_MISSING"
      workspace_recovery="run setup_operator_user.sh"
      return 1
    fi

    if ! sudo -H -u "${OPERATOR_USER}" test -w "${configured_repo_path}" >/dev/null 2>&1; then
      workspace_block_reason="WORKSPACE_NOT_WRITABLE"
      workspace_recovery="run setup_ai_cli_runner.sh ${repo_name_value}"
      return 1
    fi
  fi

  if [[ "${job_type_value}" == "ai_exec" ]]; then
    if ! command -v bwrap >/dev/null 2>&1; then
      workspace_block_reason="SANDBOX_MISSING"
      workspace_recovery="install and verify bubblewrap before ai_exec"
      return 1
    fi

    if ! command -v codex >/dev/null 2>&1; then
      workspace_block_reason="CODEX_MISSING"
      workspace_recovery="install Codex CLI for the VPS"
      return 1
    fi

    if ! sudo -H -u "${OPERATOR_USER}" codex login status >/dev/null 2>&1; then
      workspace_block_reason="CODEX_AUTH_REQUIRED"
      workspace_recovery="authenticate Codex CLI for ${OPERATOR_USER} outside GitHub"
      return 1
    fi

    if ! sudo -H -u "${OPERATOR_USER}" git -C "${configured_repo_path}" diff --quiet --ignore-submodules -- 2>/dev/null || \
       ! sudo -H -u "${OPERATOR_USER}" git -C "${configured_repo_path}" diff --cached --quiet --ignore-submodules -- 2>/dev/null || \
       [[ -n "$(sudo -H -u "${OPERATOR_USER}" git -C "${configured_repo_path}" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
      workspace_block_reason="WORKSPACE_DIRTY"
      workspace_recovery="review and preserve existing workspace changes before retrying ai_exec"
      return 1
    fi
  fi

  return 0
}

if ! command -v gh >/dev/null 2>&1; then
  echo "GITHUB_JOB_IMPORT_STATUS: AUTH_REQUIRED"
  echo "Reason: gh command is not installed on the VPS."
  exit 0
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "GITHUB_JOB_IMPORT_STATUS: AUTH_REQUIRED"
  echo "Reason: gh is not authenticated for github.com on the VPS."
  exit 0
fi

issues_json="$(gh issue list \
  --repo "${REPOSITORY}" \
  --label "${LABEL}" \
  --state open \
  --limit "${SCAN_LIMIT}" \
  --json number,title,body,author,updatedAt)"

issue_count="$(printf "%s" "${issues_json}" | jq "length")"

if [[ "${issue_count}" -eq 0 ]]; then
  echo "GITHUB_JOB_IMPORT_STATUS: NO_MATCHING_ISSUES"
  exit 0
fi

imported_count=0
skipped_count=0
rejected_count=0
blocked_count=0
allowlist_required_count=0

while IFS= read -r row; do
  if [[ "${imported_count}" -ge "${IMPORT_LIMIT}" ]]; then
    break
  fi

  issue_json="$(printf "%s" "${row}" | base64 -d)"
  issue_number="$(printf "%s" "${issue_json}" | jq -r '.number')"
  issue_title="$(printf "%s" "${issue_json}" | jq -r '.title // ""')"
  issue_body="$(printf "%s" "${issue_json}" | jq -r '.body // ""')"
  issue_author="$(printf "%s" "${issue_json}" | jq -r '.author.login // "unknown"')"
  imported_marker="${IMPORT_DIR}/issue-${issue_number}.imported"

  if [[ -f "${imported_marker}" ]]; then
    skipped_count=$((skipped_count + 1))
    continue
  fi

  allow_status=0
  author_allowed "${issue_author}" || allow_status=$?

  case "${allow_status}" in
    0)
      ;;
    1)
      echo "Rejecting issue #${issue_number}: author is not in GitHub allowlist"
      reject_issue "${issue_number}" "${issue_author}" "AUTHOR_NOT_ALLOWED"
      rejected_count=$((rejected_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
    2)
      echo "Rejecting issue #${issue_number}: GitHub allowlist file is not readable: ${ALLOWLIST_FILE}"
      reject_issue "${issue_number}" "${issue_author}" "ALLOWLIST_FILE_MISSING"
      rejected_count=$((rejected_count + 1))
      allowlist_required_count=$((allowlist_required_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
    3)
      echo "Rejecting issue #${issue_number}: GitHub allowlist file is empty: ${ALLOWLIST_FILE}"
      reject_issue "${issue_number}" "${issue_author}" "ALLOWLIST_EMPTY"
      rejected_count=$((rejected_count + 1))
      allowlist_required_count=$((allowlist_required_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
    *)
      echo "Rejecting issue #${issue_number}: GitHub allowlist check failed"
      reject_issue "${issue_number}" "${issue_author}" "ALLOWLIST_CHECK_FAILED"
      rejected_count=$((rejected_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
  esac

  job_type="$(printf "%s\n" "${issue_body}" | awk -F= '/^JOB_TYPE=/{print $2; exit}' | tr -d '[:space:]')"
  repo_name="$(printf "%s\n" "${issue_body}" | awk -F= '/^REPO_NAME=/{print $2; exit}' | tr -d '[:space:]')"
  request_mode="explicit"

  if [[ -z "${job_type}" ]]; then
    if derive_casual_job "${issue_title}
${issue_body}"; then
      request_mode="casual"
    else
      job_type="ai_plan"
      repo_name="${repo_name:-ai-council}"
      request_mode="freeform_plan"
      echo "Routing issue #${issue_number}: free-form request -> ai_plan"
    fi
  fi

  case "${job_type}" in
    repo_check)
      if [[ -z "${repo_name}" ]]; then
        echo "Rejecting issue #${issue_number}: repo_check requires REPO_NAME"
        reject_issue "${issue_number}" "${issue_author}" "REPO_NAME_REQUIRED"
        rejected_count=$((rejected_count + 1))
        skipped_count=$((skipped_count + 1))
        continue
      fi
      ;;
    workspace_summary)
      repo_name="${repo_name:-all}"
      ;;
    ai_plan | ai_check | ai_exec)
      repo_name="${repo_name:-ai-council}"
      ;;
    *)
      echo "Rejecting issue #${issue_number}: unsupported JOB_TYPE"
      reject_issue "${issue_number}" "${issue_author}" "UNSUPPORTED_JOB_TYPE"
      rejected_count=$((rejected_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
  esac

  if [[ ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Rejecting issue #${issue_number}: unsafe REPO_NAME"
    reject_issue "${issue_number}" "${issue_author}" "UNSAFE_REPO_NAME"
    rejected_count=$((rejected_count + 1))
    skipped_count=$((skipped_count + 1))
    continue
  fi

  workspace_block_reason=""
  workspace_recovery=""
  if ! workspace_preflight "${job_type}" "${repo_name}"; then
    echo "Blocking issue #${issue_number}: ${workspace_block_reason}"
    block_issue \
      "${issue_number}" \
      "${issue_author}" \
      "${job_type}" \
      "${repo_name}" \
      "${workspace_block_reason}" \
      "${workspace_recovery}"
    blocked_count=$((blocked_count + 1))
    skipped_count=$((skipped_count + 1))
    continue
  fi
  clear_issue_blocks "${issue_number}"

  set +e
  create_output="$(
    AI_COUNCIL_REQUEST_SOURCE="github_issue_${issue_number}" \
    AI_COUNCIL_REQUESTED_BY="${issue_author}" \
    bash "${APP_DIR}/scripts/create_job.sh" "${job_type}" "${repo_name}" 2>&1
  )"
  create_rc=$?
  set -e

  if [[ "${create_rc}" -ne 0 ]]; then
    echo "Blocking issue #${issue_number}: job creation failed"
    printf "%s\n" "${create_output}"
    block_issue \
      "${issue_number}" \
      "${issue_author}" \
      "${job_type}" \
      "${repo_name}" \
      "JOB_CREATION_FAILED" \
      "check queue ownership, free space, and create_job.sh"
    blocked_count=$((blocked_count + 1))
    skipped_count=$((skipped_count + 1))
    continue
  fi

  job_id="$(printf "%s\n" "${create_output}" | awk -F= '/JOB_ID=/{print $2; exit}' | tr -d '[:space:]')"
  if [[ -z "${job_id}" || ! "${job_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "Blocking issue #${issue_number}: create_job returned an invalid JOB_ID"
    block_issue \
      "${issue_number}" \
      "${issue_author}" \
      "${job_type}" \
      "${repo_name}" \
      "INVALID_JOB_ID" \
      "inspect create_job.sh output and queue state"
    blocked_count=$((blocked_count + 1))
    skipped_count=$((skipped_count + 1))
    continue
  fi

  {
    echo "ISSUE_NUMBER=${issue_number}"
    echo "JOB_ID=${job_id}"
    echo "JOB_TYPE=${job_type}"
    echo "REPO_NAME=${repo_name}"
    echo "REQUEST_MODE=${request_mode}"
    echo "IMPORTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "${imported_marker}"

  printf "%s\n" "${create_output}"
  echo "Imported GitHub Issue #${issue_number} as job ${job_id}"
  imported_count=$((imported_count + 1))
done < <(printf "%s" "${issues_json}" | jq -r '.[] | @base64')

echo "Scanned: ${issue_count}/${SCAN_LIMIT}"
echo "Imported: ${imported_count}/${IMPORT_LIMIT}"
echo "Skipped: ${skipped_count}"
echo "Blocked: ${blocked_count}"
echo "Rejected: ${rejected_count}"
echo "Allowlist File: ${ALLOWLIST_FILE}"

if [[ "${imported_count}" -eq 0 && "${allowlist_required_count}" -gt 0 ]]; then
  echo "GITHUB_JOB_IMPORT_STATUS: ALLOWLIST_REQUIRED"
else
  echo "GITHUB_JOB_IMPORT_STATUS: OK"
fi
