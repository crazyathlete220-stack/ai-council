#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

pass_count=0

pass() {
  echo "PASS: $1"
  pass_count=$((pass_count + 1))
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "${pattern}" "${file}" || fail "expected '${pattern}' in ${file}"
}

make_gh_stub() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -u

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit "${GH_AUTH_RC:-0}"
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  printf '%s\n' "$*" >>"${GH_CAPTURE:?}"
  exit "${GH_COMMENT_RC:-0}"
fi

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  exit "${GH_REPO_VIEW_RC:-0}"
fi

if [[ "${1:-}" == "repo" && "${2:-}" == "clone" ]]; then
  exit "${GH_REPO_CLONE_RC:-1}"
fi

exit 0
STUB
  chmod +x "${bin_dir}/gh"
}

setup_app() {
  local app_dir="$1"
  mkdir -p "${app_dir}/scripts"
  cp "${REPO_ROOT}/scripts/run_job_cycle.sh" "${app_dir}/scripts/"
  cp "${REPO_ROOT}/scripts/run_github_bridge_once.sh" "${app_dir}/scripts/"
  cp "${REPO_ROOT}/scripts/post_job_result_to_github.sh" "${app_dir}/scripts/"
  chmod +x "${app_dir}/scripts/"*.sh
}

test_post_classes() {
  local root="${TEST_ROOT}/post-classes"
  local bin="${root}/bin"
  local state="${root}/state"
  local logs="${root}/logs"
  local capture="${root}/gh-capture.log"
  local deferred_report="${root}/deferred.md"
  local terminal_report="${root}/terminal.md"

  mkdir -p "${logs}"
  : >"${capture}"
  make_gh_stub "${bin}"

  cat >"${deferred_report}" <<'EOF'
# Report
- Job ID: test-job-1
- Job Type: ai_exec
- Repo Name: ai-council
- Request Source: github_issue_123
- Status Reason: hourly limit
AI_EXEC_STATUS: HOURLY_LIMIT
JOB_RUNNER_STATUS: DEFERRED
EOF

  GH_CAPTURE="${capture}" PATH="${bin}:${PATH}" \
    AI_COUNCIL_GITHUB_REPO="owner/repo" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    AI_COUNCIL_JOB_REPORT_FILE="${deferred_report}" \
    bash "${REPO_ROOT}/scripts/post_job_result_to_github.sh" >"${root}/deferred.out"

  assert_file "${state}/posted/test-job-1.deferred.posted"
  assert_contains "${root}/deferred.out" "GITHUB_JOB_POST_STATUS: OK"

  cat >"${terminal_report}" <<'EOF'
# Report
- Job ID: test-job-1
- Job Type: ai_exec
- Repo Name: ai-council
- Request Source: github_issue_123
- Status Reason: completed
AI_EXEC_STATUS: OK
JOB_RUNNER_STATUS: OK
EOF

  GH_CAPTURE="${capture}" PATH="${bin}:${PATH}" \
    AI_COUNCIL_GITHUB_REPO="owner/repo" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    AI_COUNCIL_JOB_REPORT_FILE="${terminal_report}" \
    bash "${REPO_ROOT}/scripts/post_job_result_to_github.sh" >"${root}/terminal.out"

  assert_file "${state}/posted/test-job-1.terminal.posted"
  assert_contains "${capture}" "issue comment 123"
  pass "deferred and terminal result comments use separate durable markers"
}

test_job_error_is_reported() {
  local root="${TEST_ROOT}/job-error"
  local app="${root}/app"
  local jobs="${root}/jobs"
  local logs="${root}/logs"
  local state="${root}/state"
  local bin="${root}/bin"
  local capture="${root}/gh-capture.log"
  local output="${root}/cycle.out"
  local job_id="test-error-job"

  setup_app "${app}"
  mkdir -p "${jobs}/queue" "${jobs}/failed" "${logs}"
  : >"${capture}"
  make_gh_stub "${bin}"

  cat >"${jobs}/queue/${job_id}.job" <<EOF
JOB_ID=${job_id}
JOB_TYPE=ai_check
REPO_NAME=ai-council
REQUEST_SOURCE=github_issue_201
REQUESTED_BY=tester
CREATED_AT=2026-09-01T00:00:00Z
EOF

  cat >"${app}/scripts/run_job_once.sh" <<'STUB'
#!/usr/bin/env bash
set -u
job_file="$(find "${AI_COUNCIL_JOB_ROOT}/queue" -name '*.job' | head -n 1)"
job_base="$(basename "${job_file}")"
mv "${job_file}" "${AI_COUNCIL_JOB_ROOT}/failed/${job_base}"
cat >"${AI_COUNCIL_JOB_LOG_DIR}/latest-job-report.md" <<EOF
# AI Council Job Run
- Job ID: test-error-job
- Job Type: ai_check
- Repo Name: ai-council
- Request Source: github_issue_201
- Status Reason: bounded test failure
AI_CHECK_STATUS: ERROR
JOB_RUNNER_STATUS: ERROR
EOF
echo "JOB_RUNNER_STATUS: ERROR"
exit 1
STUB

  cat >"${app}/scripts/report_job_result.sh" <<'STUB'
#!/usr/bin/env bash
echo "JOB_REPORT_STATUS: OK"
STUB
  chmod +x "${app}/scripts/run_job_once.sh" "${app}/scripts/report_job_result.sh"

  GH_CAPTURE="${capture}" PATH="${bin}:${PATH}" \
    AI_COUNCIL_APP_DIR="${app}" \
    AI_COUNCIL_JOB_ROOT="${jobs}" \
    AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_GITHUB_REPO="owner/repo" \
    bash "${app}/scripts/run_job_cycle.sh" >"${output}" 2>&1

  assert_contains "${output}" "JOB_CYCLE_STATUS: JOB_ERROR_REPORTED"
  assert_file "${state}/posted/${job_id}.terminal.posted"
  assert_no_file "${logs}/pending-posts/${job_id}-"'*.md'
  pass "job failure still produces a terminal GitHub result"
}

test_transient_error_is_deferred() {
  local root="${TEST_ROOT}/job-deferred"
  local app="${root}/app"
  local jobs="${root}/jobs"
  local logs="${root}/logs"
  local state="${root}/state"
  local bin="${root}/bin"
  local capture="${root}/gh-capture.log"
  local output="${root}/cycle.out"
  local job_id="test-deferred-job"

  setup_app "${app}"
  mkdir -p "${jobs}/queue" "${jobs}/failed" "${logs}"
  : >"${capture}"
  make_gh_stub "${bin}"

  cat >"${jobs}/queue/${job_id}.job" <<EOF
JOB_ID=${job_id}
JOB_TYPE=ai_exec
REPO_NAME=ai-council
REQUEST_SOURCE=github_issue_202
REQUESTED_BY=tester
CREATED_AT=2026-09-01T00:00:00Z
EOF

  cat >"${app}/scripts/run_job_once.sh" <<'STUB'
#!/usr/bin/env bash
set -u
job_file="$(find "${AI_COUNCIL_JOB_ROOT}/queue" -name '*.job' | head -n 1)"
job_base="$(basename "${job_file}")"
mv "${job_file}" "${AI_COUNCIL_JOB_ROOT}/failed/${job_base}"
cat >"${AI_COUNCIL_JOB_LOG_DIR}/latest-job-report.md" <<EOF
# AI Council Job Run
- Job ID: test-deferred-job
- Job Type: ai_exec
- Repo Name: ai-council
- Request Source: github_issue_202
- Status Reason: hourly limit reached
AI_EXEC_STATUS: HOURLY_LIMIT
JOB_RUNNER_STATUS: ERROR
EOF
echo "JOB_RUNNER_STATUS: ERROR"
exit 1
STUB

  cat >"${app}/scripts/report_job_result.sh" <<'STUB'
#!/usr/bin/env bash
echo "JOB_REPORT_STATUS: OK"
STUB
  chmod +x "${app}/scripts/run_job_once.sh" "${app}/scripts/report_job_result.sh"

  GH_CAPTURE="${capture}" PATH="${bin}:${PATH}" \
    AI_COUNCIL_APP_DIR="${app}" \
    AI_COUNCIL_JOB_ROOT="${jobs}" \
    AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_GITHUB_REPO="owner/repo" \
    bash "${app}/scripts/run_job_cycle.sh" >"${output}" 2>&1

  assert_contains "${output}" "JOB_CYCLE_STATUS: DEFERRED"
  assert_file "${jobs}/deferred/${job_id}.job"
  assert_file "${jobs}/deferred/${job_id}.job.retry_at"
  assert_file "${state}/posted/${job_id}.deferred.posted"
  pass "rate and schedule limits defer rather than permanently lose ai_exec jobs"
}

test_auth_failure_preserves_pending_post() {
  local root="${TEST_ROOT}/post-blocked"
  local app="${root}/app"
  local jobs="${root}/jobs"
  local logs="${root}/logs"
  local state="${root}/state"
  local bin="${root}/bin"
  local capture="${root}/gh-capture.log"
  local pending="${logs}/pending-posts/pending-auth.md"
  local output="${root}/cycle.out"

  setup_app "${app}"
  mkdir -p "${jobs}" "${logs}/pending-posts"
  : >"${capture}"
  make_gh_stub "${bin}"

  cat >"${pending}" <<'EOF'
# Report
- Job ID: pending-auth-job
- Request Source: github_issue_203
JOB_RUNNER_STATUS: OK
EOF

  set +e
  GH_CAPTURE="${capture}" GH_AUTH_RC=1 PATH="${bin}:${PATH}" \
    AI_COUNCIL_APP_DIR="${app}" \
    AI_COUNCIL_JOB_ROOT="${jobs}" \
    AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_GITHUB_REPO="owner/repo" \
    bash "${app}/scripts/run_job_cycle.sh" >"${output}" 2>&1
  rc=$?
  set -e

  [[ "${rc}" -ne 0 ]] || fail "auth failure should block the cycle"
  assert_contains "${output}" "JOB_CYCLE_STATUS: POST_BLOCKED"
  assert_file "${pending}"
  pass "GitHub auth outage preserves pending reports and blocks invisible new work"
}

test_bridge_entry_block() {
  local root="${TEST_ROOT}/bridge-entry-block"
  local app="${root}/app"
  local state="${root}/state"
  local logs="${root}/bridge-logs"
  local output="${root}/bridge.out"

  setup_app "${app}"
  mkdir -p "${state}/imported"

  cat >"${app}/scripts/import_github_jobs.sh" <<'STUB'
#!/usr/bin/env bash
echo "GITHUB_JOB_IMPORT_STATUS: AUTH_REQUIRED"
exit 0
STUB
  cat >"${app}/scripts/run_job_cycle.sh" <<'STUB'
#!/usr/bin/env bash
touch "${SHOULD_NOT_RUN:?}"
STUB
  chmod +x "${app}/scripts/import_github_jobs.sh" "${app}/scripts/run_job_cycle.sh"

  set +e
  SHOULD_NOT_RUN="${root}/job-cycle-called" \
    AI_COUNCIL_APP_DIR="${app}" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR="${logs}" \
    bash "${app}/scripts/run_github_bridge_once.sh" >"${output}" 2>&1
  rc=$?
  set -e

  [[ "${rc}" -ne 0 ]] || fail "AUTH_REQUIRED should fail the bridge cycle"
  assert_contains "${output}" "GITHUB_BRIDGE_CYCLE_STATUS: ENTRY_BLOCKED"
  assert_no_file "${root}/job-cycle-called"
  pass "bridge detects importer statuses that historically exited zero"
}

test_bridge_posts_queue_state() {
  local root="${TEST_ROOT}/bridge-queued"
  local app="${root}/app"
  local state="${root}/state"
  local logs="${root}/bridge-logs"
  local bin="${root}/bin"
  local capture="${root}/gh-capture.log"
  local output="${root}/bridge.out"

  setup_app "${app}"
  mkdir -p "${state}/imported"
  : >"${capture}"
  make_gh_stub "${bin}"

  cat >"${app}/scripts/import_github_jobs.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p "${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT}/imported"
cat >"${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT}/imported/issue-321.imported" <<EOF
ISSUE_NUMBER=321
JOB_ID=queue-state-job
JOB_TYPE=ai_check
REPO_NAME=ai-council
EOF
echo "GITHUB_JOB_IMPORT_STATUS: OK"
STUB
  cat >"${app}/scripts/run_job_cycle.sh" <<'STUB'
#!/usr/bin/env bash
echo "JOB_CYCLE_STATUS: IDLE"
exit 0
STUB
  chmod +x "${app}/scripts/import_github_jobs.sh" "${app}/scripts/run_job_cycle.sh"

  GH_CAPTURE="${capture}" PATH="${bin}:${PATH}" \
    AI_COUNCIL_APP_DIR="${app}" \
    AI_COUNCIL_GITHUB_REPO="owner/repo" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR="${logs}" \
    bash "${app}/scripts/run_github_bridge_once.sh" >"${output}" 2>&1

  assert_contains "${output}" "GITHUB_BRIDGE_CYCLE_STATUS: OK"
  assert_contains "${capture}" "VPS_STATE: **QUEUED**"
  assert_contains "${capture}" "queue-state-job"
  pass "newly imported jobs leave a visible QUEUED state on the source issue"
}

bash -n "${REPO_ROOT}"/scripts/*.sh

test_post_classes
test_job_error_is_reported
test_transient_error_is_deferred
test_auth_failure_preserves_pending_post
test_bridge_entry_block
test_bridge_posts_queue_state

echo "BRIDGE_RECOVERY_TEST_STATUS: OK (${pass_count} tests)"
