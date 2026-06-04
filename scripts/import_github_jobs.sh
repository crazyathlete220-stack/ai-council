#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
LABEL="${AI_COUNCIL_GITHUB_JOB_LABEL:-vps-job}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
LOG_DIR="${AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR:-/var/log/ai-council/github-bridge}"
IMPORT_DIR="${STATE_ROOT}/imported"
REJECT_DIR="${STATE_ROOT}/rejected"
REJECT_LOG="${LOG_DIR}/rejected-issues.log"
ALLOWLIST_FILE="${AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE:-/etc/ai-council/github-bridge-allowlist}"
MAX_ISSUES="${AI_COUNCIL_GITHUB_IMPORT_LIMIT:-20}"

mkdir -p "${IMPORT_DIR}" "${REJECT_DIR}" "${LOG_DIR}"

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
  local rejected_marker="${REJECT_DIR}/issue-${issue_number}.rejected"

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
  --limit "${MAX_ISSUES}" \
  --json number,title,body,author,updatedAt)"

issue_count="$(printf "%s" "${issues_json}" | jq "length")"

if [[ "${issue_count}" -eq 0 ]]; then
  echo "GITHUB_JOB_IMPORT_STATUS: NO_MATCHING_ISSUES"
  exit 0
fi

imported_count=0
skipped_count=0
rejected_count=0
allowlist_required_count=0

for row in $(printf "%s" "${issues_json}" | jq -r '.[] | @base64'); do
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
      reject_issue "${issue_number}" "${issue_author}" "author_not_allowed"
      rejected_count=$((rejected_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
    2)
      echo "Rejecting issue #${issue_number}: GitHub allowlist file is not readable: ${ALLOWLIST_FILE}"
      reject_issue "${issue_number}" "${issue_author}" "allowlist_file_missing"
      rejected_count=$((rejected_count + 1))
      allowlist_required_count=$((allowlist_required_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
    3)
      echo "Rejecting issue #${issue_number}: GitHub allowlist file is empty: ${ALLOWLIST_FILE}"
      reject_issue "${issue_number}" "${issue_author}" "allowlist_empty"
      rejected_count=$((rejected_count + 1))
      allowlist_required_count=$((allowlist_required_count + 1))
      skipped_count=$((skipped_count + 1))
      continue
      ;;
    *)
      echo "Rejecting issue #${issue_number}: GitHub allowlist check failed"
      reject_issue "${issue_number}" "${issue_author}" "allowlist_check_failed"
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
        echo "Skipping issue #${issue_number}: repo_check requires REPO_NAME"
        skipped_count=$((skipped_count + 1))
        continue
      fi
      ;;
    workspace_summary)
      repo_name="${repo_name:-all}"
      ;;
    ai_plan)
      repo_name="${repo_name:-ai-council}"
      ;;
    ai_check)
      repo_name="${repo_name:-ai-council}"
      ;;
    ai_exec)
      repo_name="${repo_name:-ai-council}"
      ;;
    *)
      echo "Skipping issue #${issue_number}: unsupported or missing JOB_TYPE"
      skipped_count=$((skipped_count + 1))
      continue
      ;;
  esac

  if [[ ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Skipping issue #${issue_number}: unsafe REPO_NAME"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  create_output="$(
    AI_COUNCIL_REQUEST_SOURCE="github_issue_${issue_number}" \
    AI_COUNCIL_REQUESTED_BY="${issue_author}" \
    bash "${APP_DIR}/scripts/create_job.sh" "${job_type}" "${repo_name}"
  )"

  job_id="$(printf "%s\n" "${create_output}" | awk -F= '/JOB_ID=/{print $2; exit}' | tr -d '[:space:]')"

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
done

echo "Imported: ${imported_count}"
echo "Skipped: ${skipped_count}"
echo "Rejected: ${rejected_count}"
echo "Allowlist File: ${ALLOWLIST_FILE}"

if [[ "${imported_count}" -eq 0 && "${allowlist_required_count}" -gt 0 ]]; then
  echo "GITHUB_JOB_IMPORT_STATUS: ALLOWLIST_REQUIRED"
else
  echo "GITHUB_JOB_IMPORT_STATUS: OK"
fi
