#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
POSTED_DIR="${STATE_ROOT}/posted"
REPORT_FILE="${1:-${LOG_DIR}/latest-job-report.md}"

mkdir -p "${POSTED_DIR}"

if [[ ! -r "${REPORT_FILE}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_REPORT"
  echo "Reason: job report is not readable: ${REPORT_FILE}"
  exit 1
fi

job_id="$(awk -F': ' '/^- Job ID: /{print $2; exit}' "${REPORT_FILE}")"
request_source="$(awk -F': ' '/^- Request Source: /{print $2; exit}' "${REPORT_FILE}")"
job_runner_status="$(awk -F': ' '/^JOB_RUNNER_STATUS: /{value=$2} END {print value}' "${REPORT_FILE}")"

if [[ -z "${job_id}" || -z "${request_source}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_ISSUE_SOURCE"
  exit 0
fi

if [[ ! "${request_source}" =~ ^github_issue_([0-9]+)$ ]]; then
  echo "GITHUB_JOB_POST_STATUS: NO_ISSUE_SOURCE"
  exit 0
fi

issue_number="${BASH_REMATCH[1]}"
status_key="${job_runner_status:-UNKNOWN}"
status_key="$(printf '%s' "${status_key}" | tr -c 'A-Za-z0-9._-' '_')"
posted_marker="${POSTED_DIR}/${job_id}-${status_key}.posted"

if [[ -f "${posted_marker}" ]]; then
  echo "GITHUB_JOB_POST_STATUS: ALREADY_POSTED"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GITHUB_JOB_POST_STATUS: AUTH_REQUIRED"
  echo "Reason: gh command is not installed on the VPS."
  exit 1
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "GITHUB_JOB_POST_STATUS: AUTH_REQUIRED"
  echo "Reason: gh is not authenticated for github.com on the VPS."
  exit 1
fi

extract_signals() {
  awk '
    BEGIN {
      na=split("Generated At|Hostname|Job ID|Job Type|Repo Name|Repo Path|Request Source|Requested By|Job Log|Job Report|Plan File|Latest Plan|Check File|Latest Check|Exec File|Latest Exec|CLI Provider|Result Marker|Status Reason|Guard Status|Commit Status|Commit|Changed File Count|Changed File Bytes|Failed Change Stash|Allowed Hours JST|Current Hour JST|Max Per Hour|Hourly Count Before Run|Max Per Day|Daily Count Before Run|Deferred Reason|Retry Not Before Epoch|Defer Count|Max Defer Count", a, "|")
      for (i in a) allowed_meta[a[i]]=1
      nb=split("REPO_CHECK_STATUS|WORKSPACE_SUMMARY_STATUS|AI_PLAN_STATUS|AI_CHECK_STATUS|AI_EXEC_STATUS|JOB_RUNNER_STATUS", b, "|")
      for (i in b) allowed_status[b[i]]=1
    }
    /^- / {
      key=$0
      sub(/^- /, "", key)
      sub(/:.*/, "", key)
      if (allowed_meta[key] && !seen["m:" key]++) print
      next
    }
    /^[A-Z_]+: / {
      key=$0
      sub(/:.*/, "", key)
      if (allowed_status[key]) status[key]=$0
    }
    END {
      for (i=1; i<=nb; i++) if (status[b[i]] != "") print status[b[i]]
    }
  ' "${REPORT_FILE}"
}

body="$(
  {
    echo "## VPS job result"
    echo
    extract_signals
    echo
    echo "Evidence:"
    echo "- VPS per-job report: ${REPORT_FILE}"
  }
)"

gh issue comment "${issue_number}" --repo "${REPOSITORY}" --body "${body}" >/dev/null

{
  echo "ISSUE_NUMBER=${issue_number}"
  echo "JOB_ID=${job_id}"
  echo "JOB_RUNNER_STATUS=${job_runner_status:-UNKNOWN}"
  echo "REPORT_FILE=${REPORT_FILE}"
  echo "POSTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} > "${posted_marker}"

echo "Posted ${job_runner_status:-UNKNOWN} result for ${job_id} to Issue #${issue_number}"
echo "GITHUB_JOB_POST_STATUS: OK"
