#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
POSTED_DIR="${STATE_ROOT}/posted"
LATEST_REPORT="${LOG_DIR}/latest-job-report.md"

mkdir -p "${POSTED_DIR}"

if [[ ! -r "${LATEST_REPORT}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_REPORT"
  exit 0
fi

job_id="$(awk -F': ' '/^- Job ID:/{print $2; exit}' "${LATEST_REPORT}")"
request_source="$(awk -F': ' '/^- Request Source:/{print $2; exit}' "${LATEST_REPORT}")"

if [[ -z "${job_id}" || -z "${request_source}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_ISSUE_SOURCE"
  exit 0
fi

if [[ ! "${request_source}" =~ ^github_issue_([0-9]+)$ ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_ISSUE_SOURCE"
  exit 0
fi

issue_number="${BASH_REMATCH[1]}"
posted_marker="${POSTED_DIR}/${job_id}.posted"

if [[ -f "${posted_marker}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: ALREADY_POSTED"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GITHUB_JOB_POST_STATUS: AUTH_REQUIRED"
  echo "Reason: gh command is not installed on the VPS."
  exit 0
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "GITHUB_JOB_POST_STATUS: AUTH_REQUIRED"
  echo "Reason: gh is not authenticated for github.com on the VPS."
  exit 0
fi

body="$(
  {
    echo "## VPS job result"
    echo
    grep -E "Generated At|Job ID|Job Type|Repo Name|Repo Path|Plan File|Latest Plan|Check File|Latest Check|Exec File|Latest Exec|CLI Provider|Status Reason|Guard Status|Allowed Hours JST|Current Hour JST|Max Per Hour|Hourly Count|Max Per Day|Daily Count|REPO_CHECK_STATUS|WORKSPACE_SUMMARY_STATUS|AI_PLAN_STATUS|AI_CHECK_STATUS|AI_EXEC_STATUS|JOB_RUNNER_STATUS" "${LATEST_REPORT}" || true
    echo
    echo "Evidence:"
    echo "- VPS latest job report: ${LATEST_REPORT}"
  }
)"

gh issue comment "${issue_number}" --repo "${REPOSITORY}" --body "${body}" >/dev/null

{
  echo "ISSUE_NUMBER=${issue_number}"
  echo "JOB_ID=${job_id}"
  echo "POSTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} > "${posted_marker}"

echo "Posted job result for ${job_id} to Issue #${issue_number}"
echo "GITHUB_JOB_POST_STATUS: OK"
