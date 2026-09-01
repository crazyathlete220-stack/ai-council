#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"
issue_number="${1:-}"

usage() {
  echo "Usage: sudo bash scripts/requeue_github_issue.sh <ISSUE_NUMBER>" >&2
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root with sudo." >&2
  exit 1
fi

if [[ ! "${issue_number}" =~ ^[0-9]+$ ]]; then
  usage
  exit 1
fi

imported_marker="${STATE_ROOT}/imported/issue-${issue_number}.imported"
archive_dir="${STATE_ROOT}/requeue-archive/issue-${issue_number}/$(date -u +'%Y%m%dT%H%M%SZ')"

if [[ ! -r "${imported_marker}" ]]; then
  echo "Issue #${issue_number} has no imported marker."
  echo "If it is open and labeled vps-job, the next bridge cycle can import it normally."
  echo "GITHUB_ISSUE_REQUEUE_STATUS: NOT_IMPORTED"
  exit 0
fi

job_id="$(awk -F= '$1 == "JOB_ID" {print $2; exit}' "${imported_marker}")"
if [[ -z "${job_id}" || ! "${job_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "ERROR: imported marker has an unsafe or missing JOB_ID" >&2
  exit 1
fi

job_base="${job_id}.job"
queue_job="${JOB_ROOT}/queue/${job_base}"
active_job="${JOB_ROOT}/active/${job_base}"
done_job="${JOB_ROOT}/done/${job_base}"
failed_job="${JOB_ROOT}/failed/${job_base}"
deferred_job="${JOB_ROOT}/deferred/${job_base}"

if [[ -f "${active_job}" ]]; then
  echo "ERROR: job is active; refusing to duplicate it: ${active_job}" >&2
  echo "GITHUB_ISSUE_REQUEUE_STATUS: ACTIVE"
  exit 1
fi

if [[ -f "${queue_job}" ]]; then
  echo "Job is already queued: ${queue_job}"
  echo "GITHUB_ISSUE_REQUEUE_STATUS: ALREADY_QUEUED"
  exit 0
fi

if [[ -f "${done_job}" ]]; then
  echo "ERROR: job is already terminal-success/done; create a new Issue for a new execution." >&2
  echo "GITHUB_ISSUE_REQUEUE_STATUS: ALREADY_DONE"
  exit 1
fi

install -d -m 0755 "${archive_dir}"
cp "${imported_marker}" "${archive_dir}/"

if [[ -f "${failed_job}" ]]; then
  mv "${failed_job}" "${queue_job}"
elif [[ -f "${deferred_job}" ]]; then
  mv "${deferred_job}" "${queue_job}"
  rm -f "${JOB_ROOT}/deferred/${job_base}.retry_at"
else
  mv "${imported_marker}" "${archive_dir}/"
  find "${STATE_ROOT}/posted" -maxdepth 1 -type f -name "${job_id}.*.posted" -exec mv {} "${archive_dir}/" \; 2>/dev/null || true
  echo "No job file remained. Imported state was archived so the next bridge cycle can create a new job."
  echo "Archive: ${archive_dir}"
  echo "GITHUB_ISSUE_REQUEUE_STATUS: READY_FOR_REIMPORT"
  exit 0
fi

find "${STATE_ROOT}/posted" -maxdepth 1 -type f -name "${job_id}.*.posted" -exec mv {} "${archive_dir}/" \; 2>/dev/null || true
find "${LOG_DIR}/pending-posts" -maxdepth 1 -type f -name "${job_id}-*.md" -exec mv {} "${archive_dir}/" \; 2>/dev/null || true

echo "Requeued Issue #${issue_number} job: ${queue_job}"
echo "Archive: ${archive_dir}"
echo "GITHUB_ISSUE_REQUEUE_STATUS: OK"
