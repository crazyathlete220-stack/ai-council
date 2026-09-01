#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
POSTED_DIR="${STATE_ROOT}/posted"
REPORT_FILE="${AI_COUNCIL_JOB_REPORT_FILE:-${LOG_DIR}/latest-job-report.md}"

mkdir -p "${POSTED_DIR}"

if [[ ! -r "${REPORT_FILE}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_REPORT"
  echo "Report: ${REPORT_FILE}"
  exit 0
fi

job_id="$(awk -F': ' '/^- Job ID:/{print $2; exit}' "${REPORT_FILE}")"
request_source="$(awk -F': ' '/^- Request Source:/{print $2; exit}' "${REPORT_FILE}")"
runner_status="$(awk -F': ' '/^JOB_RUNNER_STATUS:/{print $2}' "${REPORT_FILE}" | tail -n 1 | tr -d '[:space:]')"
runner_status="${runner_status:-UNKNOWN}"

if [[ -z "${job_id}" || -z "${request_source}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_ISSUE_SOURCE"
  exit 0
fi

if [[ ! "${job_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "GITHUB_JOB_POST_STATUS: INVALID_REPORT" >&2
  echo "Reason: unsafe Job ID in report." >&2
  exit 1
fi

if [[ ! "${request_source}" =~ ^github_issue_([0-9]+)$ ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_ISSUE_SOURCE"
  exit 0
fi

issue_number="${BASH_REMATCH[1]}"
post_class="terminal"
if [[ "${runner_status}" == "DEFERRED" ]]; then
  post_class="deferred"
fi
posted_marker="${POSTED_DIR}/${job_id}.${post_class}.posted"

if [[ -f "${posted_marker}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: ALREADY_POSTED"
  echo "Post Class: ${post_class}"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GITHUB_JOB_POST_STATUS: AUTH_REQUIRED" >&2
  echo "Reason: gh command is not installed on the VPS." >&2
  exit 1
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "GITHUB_JOB_POST_STATUS: AUTH_REQUIRED" >&2
  echo "Reason: gh is not authenticated for github.com on the VPS." >&2
  exit 1
fi

heading="VPS job result"
if [[ "${post_class}" == "deferred" ]]; then
  heading="VPS job deferred"
fi

body="$(
  {
    echo "## ${heading}"
    echo
    grep -E \
      '^- (Generated At|Job ID|Job Type|Repo Name|Repo Path|Request Source|Requested By|Created At|Plan File|Latest Plan|Check File|Latest Check|Exec File|Latest Exec|CLI Provider|Status Reason|Guard Status|Allowed Hours JST|Current Hour JST|Max Per Hour|Hourly Count Before Run|Max Per Day|Daily Count Before Run|Cycle Log|Retry State|Retry After):|^(REPO_CHECK_STATUS|WORKSPACE_SUMMARY_STATUS|AI_PLAN_STATUS|AI_CHECK_STATUS|AI_EXEC_STATUS|JOB_RUNNER_STATUS):' \
      "${REPORT_FILE}" || true
    echo
    echo "Evidence:"
    echo "- VPS job report: ${REPORT_FILE}"
  }
)"

if ! gh issue comment "${issue_number}" --repo "${REPOSITORY}" --body "${body}" >/dev/null; then
  echo "GITHUB_JOB_POST_STATUS: POST_FAILED" >&2
  echo "Issue: #${issue_number}" >&2
  exit 1
fi

{
  echo "ISSUE_NUMBER=${issue_number}"
  echo "JOB_ID=${job_id}"
  echo "POST_CLASS=${post_class}"
  echo "REPORT_FILE=${REPORT_FILE}"
  echo "POSTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} > "${posted_marker}"

echo "Posted ${post_class} result for ${job_id} to Issue #${issue_number}"
echo "GITHUB_JOB_POST_STATUS: OK"
