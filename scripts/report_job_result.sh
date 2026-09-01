#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
SUMMARY_DIR="${LOG_DIR}/summaries"
LATEST_SUMMARY="${LOG_DIR}/latest-summary.md"
REPORT_FILE="${1:-${LOG_DIR}/latest-job-report.md}"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "${LOG_DIR}" "${SUMMARY_DIR}"

if [[ ! -r "${REPORT_FILE}" ]]; then
  echo "ERROR: job report is not readable: ${REPORT_FILE}" >&2
  echo "JOB_REPORT_STATUS: NO_REPORT"
  exit 1
fi

job_id="$(awk -F': ' '/^- Job ID: /{print $2; exit}' "${REPORT_FILE}")"
job_id="${job_id:-unknown-job}"
job_id_safe="$(printf '%s' "${job_id}" | tr -c 'A-Za-z0-9._-' '_')"
SUMMARY_FILE="${SUMMARY_DIR}/${job_id_safe}.md"

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

{
  echo "# AI Council Job Summary"
  echo
  echo "- Generated At: ${generated_at}"
  echo "- Source Report: ${REPORT_FILE}"
  echo
  echo "## Job Signals"
  extract_signals
  echo
  echo "JOB_REPORT_STATUS: OK"
} | tee "${SUMMARY_FILE}" "${LATEST_SUMMARY}"
