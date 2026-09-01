#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

app="${tmp}/app"
jobs="${tmp}/jobs"
logs="${tmp}/logs"
mkdir -p "${app}/scripts" "${jobs}/queue" "${jobs}/active" "${jobs}/done" "${jobs}/failed" "${logs}"

cat > "${app}/scripts/run_ai_exec.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "- Repo Path: /tmp/test-workspace"
echo "AI_EXEC_STATUS: OUT_OF_HOURS"
exit 1
SCRIPT
chmod +x "${app}/scripts/run_ai_exec.sh"

job_id="20260902T000000Z-ai_exec-ai-council-1"
cat > "${jobs}/queue/${job_id}.job" <<EOF_JOB
JOB_ID=${job_id}
JOB_TYPE=ai_exec
REPO_NAME=ai-council
REQUEST_SOURCE=github_issue_123
REQUESTED_BY=test-owner
CREATED_AT=2026-09-02T00:00:00Z
EOF_JOB

output="$(AI_COUNCIL_APP_DIR="${app}" AI_COUNCIL_JOB_ROOT="${jobs}" AI_COUNCIL_JOB_LOG_DIR="${logs}" AI_COUNCIL_JOB_RUNNER_LOCK_FILE="${tmp}/runner.lock" AI_COUNCIL_JOB_DEFER_SECONDS=3600 bash "${ROOT_DIR}/scripts/run_job_once.sh")"
printf '%s\n' "${output}"

test -f "${jobs}/queue/${job_id}.job"
test ! -e "${jobs}/failed/${job_id}.job"
grep -q '^NOT_BEFORE_EPOCH=' "${jobs}/queue/${job_id}.job"
grep -q '^DEFER_COUNT=1$' "${jobs}/queue/${job_id}.job"
grep -q '^JOB_RUNNER_STATUS: DEFERRED$' "${logs}/reports/${job_id}.md"

sed -i 's/^NOT_BEFORE_EPOCH=.*/NOT_BEFORE_EPOCH=0/' "${jobs}/queue/${job_id}.job"
cat > "${app}/scripts/run_ai_exec.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "- Repo Path: /tmp/test-workspace"
echo "AI_EXEC_STATUS: OK"
exit 0
SCRIPT
chmod +x "${app}/scripts/run_ai_exec.sh"

AI_COUNCIL_APP_DIR="${app}" AI_COUNCIL_JOB_ROOT="${jobs}" AI_COUNCIL_JOB_LOG_DIR="${logs}" AI_COUNCIL_JOB_RUNNER_LOCK_FILE="${tmp}/runner.lock" bash "${ROOT_DIR}/scripts/run_job_once.sh" >/dev/null

test -f "${jobs}/done/${job_id}.job"
grep -q '^JOB_RUNNER_STATUS: OK$' "${logs}/reports/${job_id}.md"

# A permanent execution error must be visible both in filesystem state and in
# the shell exit code. This guards systemd from reporting a false success.
cat > "${app}/scripts/run_ai_exec.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "- Repo Path: /tmp/test-workspace"
echo "AI_EXEC_STATUS: ERROR"
exit 7
SCRIPT
chmod +x "${app}/scripts/run_ai_exec.sh"

hard_fail_job="20260902T010000Z-ai_exec-ai-council-2"
cat > "${jobs}/queue/${hard_fail_job}.job" <<EOF_JOB
JOB_ID=${hard_fail_job}
JOB_TYPE=ai_exec
REPO_NAME=ai-council
REQUEST_SOURCE=github_issue_124
REQUESTED_BY=test-owner
CREATED_AT=2026-09-02T01:00:00Z
EOF_JOB

set +e
AI_COUNCIL_APP_DIR="${app}" AI_COUNCIL_JOB_ROOT="${jobs}" AI_COUNCIL_JOB_LOG_DIR="${logs}" AI_COUNCIL_JOB_RUNNER_LOCK_FILE="${tmp}/runner.lock" bash "${ROOT_DIR}/scripts/run_job_once.sh" >/dev/null 2>&1
hard_fail_status=$?
set -e

test "${hard_fail_status}" -ne 0
test -f "${jobs}/failed/${hard_fail_job}.job"
test ! -e "${jobs}/done/${hard_fail_job}.job"
grep -q '^AI_EXEC_STATUS: ERROR$' "${logs}/reports/${hard_fail_job}.md"
grep -q '^JOB_RUNNER_STATUS: ERROR$' "${logs}/reports/${hard_fail_job}.md"

echo "test_job_lifecycle: OK"
