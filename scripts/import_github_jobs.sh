#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
LABEL="${AI_COUNCIL_GITHUB_JOB_LABEL:-vps-job}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
LOG_DIR="${AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR:-/var/log/ai-council/github-bridge}"
IMPORT_DIR="${STATE_ROOT}/imported"
MAX_ISSUES="${AI_COUNCIL_GITHUB_IMPORT_LIMIT:-20}"

mkdir -p "${IMPORT_DIR}" "${LOG_DIR}"

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

for row in $(printf "%s" "${issues_json}" | jq -r '.[] | @base64'); do
  issue_json="$(printf "%s" "${row}" | base64 -d)"
  issue_number="$(printf "%s" "${issue_json}" | jq -r '.number')"
  issue_body="$(printf "%s" "${issue_json}" | jq -r '.body // ""')"
  issue_author="$(printf "%s" "${issue_json}" | jq -r '.author.login // "unknown"')"
  imported_marker="${IMPORT_DIR}/issue-${issue_number}.imported"

  if [[ -f "${imported_marker}" ]]; then
    skipped_count=$((skipped_count + 1))
    continue
  fi

  job_type="$(printf "%s\n" "${issue_body}" | awk -F= '/^JOB_TYPE=/{print $2; exit}' | tr -d '[:space:]')"
  repo_name="$(printf "%s\n" "${issue_body}" | awk -F= '/^REPO_NAME=/{print $2; exit}' | tr -d '[:space:]')"

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
    echo "IMPORTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "${imported_marker}"

  printf "%s\n" "${create_output}"
  echo "Imported GitHub Issue #${issue_number} as job ${job_id}"
  imported_count=$((imported_count + 1))
done

echo "Imported: ${imported_count}"
echo "Skipped: ${skipped_count}"
echo "GITHUB_JOB_IMPORT_STATUS: OK"

