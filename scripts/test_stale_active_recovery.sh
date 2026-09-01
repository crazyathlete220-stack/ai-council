#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

APP_DIR="${TEST_ROOT}/app"
JOB_ROOT="${TEST_ROOT}/jobs"
LOG_DIR="${TEST_ROOT}/logs"
STATE_ROOT="${TEST_ROOT}/state"
BIN_DIR="${TEST_ROOT}/bin"
CAPTURE="${TEST_ROOT}/gh.log"
OUTPUT="${TEST_ROOT}/cycle.log"
JOB_ID="stale-active-job"

mkdir -p "${APP_DIR}/scripts" "${JOB_ROOT}/active" "${LOG_DIR}" "${BIN_DIR}"
cp "${REPO_ROOT}/scripts/run_job_cycle.sh" "${APP_DIR}/scripts/"
cp "${REPO_ROOT}/scripts/post_job_result_to_github.sh" "${APP_DIR}/scripts/"

cat >"${APP_DIR}/scripts/run_job_once.sh" <<'STUB'
#!/usr/bin/env bash
touch "${SHOULD_NOT_RUN:?}"
exit 99
STUB
cat >"${APP_DIR}/scripts/report_job_result.sh" <<'STUB'
#!/usr/bin/env bash
echo "JOB_REPORT_STATUS: OK"
STUB
cat >"${BIN_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  printf '%s\n' "$*" >>"${GH_CAPTURE:?}"
  exit 0
fi
exit 0
STUB
chmod +x "${APP_DIR}/scripts/"*.sh "${BIN_DIR}/gh"

cat >"${JOB_ROOT}/active/${JOB_ID}.job" <<EOF
JOB_ID=${JOB_ID}
JOB_TYPE=ai_exec
REPO_NAME=ai-council
REQUEST_SOURCE=github_issue_777
REQUESTED_BY=tester
CREATED_AT=2026-09-01T00:00:00Z
EOF
touch -d '2 hours ago' "${JOB_ROOT}/active/${JOB_ID}.job"
: >"${CAPTURE}"

SHOULD_NOT_RUN="${TEST_ROOT}/runner-called" \
GH_CAPTURE="${CAPTURE}" \
PATH="${BIN_DIR}:${PATH}" \
AI_COUNCIL_APP_DIR="${APP_DIR}" \
AI_COUNCIL_JOB_ROOT="${JOB_ROOT}" \
AI_COUNCIL_JOB_LOG_DIR="${LOG_DIR}" \
AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${STATE_ROOT}" \
AI_COUNCIL_GITHUB_REPO="owner/repo" \
AI_COUNCIL_STALE_ACTIVE_SECONDS=10 \
bash "${APP_DIR}/scripts/run_job_cycle.sh" >"${OUTPUT}" 2>&1

[[ ! -e "${TEST_ROOT}/runner-called" ]]
[[ ! -e "${JOB_ROOT}/active/${JOB_ID}.job" ]]
[[ -f "${JOB_ROOT}/failed/${JOB_ID}.job" ]]
[[ -f "${STATE_ROOT}/posted/${JOB_ID}.terminal.posted" ]]
! compgen -G "${LOG_DIR}/pending-posts/*.md" >/dev/null
grep -Fq "Recovered stale active job to failed" "${OUTPUT}"
grep -Fq "automatic re-execution was refused" "${CAPTURE}"

echo "STALE_ACTIVE_RECOVERY_TEST_STATUS: OK"
