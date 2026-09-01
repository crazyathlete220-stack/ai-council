#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'sudo rm -rf "${TEST_ROOT}"' EXIT

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

assert_missing() {
  [[ ! -e "$1" ]] || fail "unexpected path: $1"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

make_gh_stub() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/gh" <<'STUB'
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
  chmod +x "${bin_dir}/gh"
}

test_pending_post_flush() {
  local root="${TEST_ROOT}/pending-flush"
  local app="${root}/app"
  local jobs="${root}/jobs"
  local logs="${root}/logs"
  local state="${root}/state"
  local bin="${root}/bin"
  local capture="${root}/gh.log"
  local output="${root}/cycle.log"
  local pending="${logs}/pending-posts/pending-job-report.md"

  mkdir -p "${app}/scripts" "${jobs}" "${logs}/pending-posts"
  cp "${REPO_ROOT}/scripts/run_job_cycle.sh" "${app}/scripts/"
  cp "${REPO_ROOT}/scripts/post_job_result_to_github.sh" "${app}/scripts/"
  chmod +x "${app}/scripts/"*.sh

  cat >"${app}/scripts/run_job_once.sh" <<'STUB'
#!/usr/bin/env bash
touch "${SHOULD_NOT_RUN:?}"
exit 99
STUB
  cat >"${app}/scripts/report_job_result.sh" <<'STUB'
#!/usr/bin/env bash
echo "JOB_REPORT_STATUS: OK"
STUB
  chmod +x "${app}/scripts/run_job_once.sh" "${app}/scripts/report_job_result.sh"

  : >"${capture}"
  make_gh_stub "${bin}"

  cat >"${pending}" <<'EOF'
# AI Council Job Run
- Job ID: pending-flush-job
- Job Type: ai_check
- Repo Name: ai-council
- Request Source: github_issue_555
- Status Reason: completed
AI_CHECK_STATUS: OK
JOB_RUNNER_STATUS: OK
EOF

  SHOULD_NOT_RUN="${root}/runner-called" \
  GH_CAPTURE="${capture}" \
  PATH="${bin}:${PATH}" \
  AI_COUNCIL_APP_DIR="${app}" \
  AI_COUNCIL_JOB_ROOT="${jobs}" \
  AI_COUNCIL_JOB_LOG_DIR="${logs}" \
  AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
  AI_COUNCIL_GITHUB_REPO="owner/repo" \
  bash "${app}/scripts/run_job_cycle.sh" >"${output}" 2>&1

  assert_missing "${root}/runner-called"
  assert_missing "${pending}"
  assert_file "${state}/posted/pending-flush-job.terminal.posted"
  assert_contains "${capture}" "issue comment 555"
  assert_contains "${output}" "JOB_CYCLE_STATUS: IDLE"
  pass "pending result is delivered before any new job and then removed"
}

test_requeue_failed_job() {
  local root="${TEST_ROOT}/requeue"
  local state="${root}/state"
  local jobs="${root}/jobs"
  local logs="${root}/logs"
  local output="${root}/requeue.log"
  local job_id="requeue-failed-job"

  mkdir -p "${state}/imported" "${state}/posted" "${jobs}/failed" "${logs}/pending-posts"
  cat >"${state}/imported/issue-601.imported" <<EOF
ISSUE_NUMBER=601
JOB_ID=${job_id}
JOB_TYPE=ai_exec
REPO_NAME=ai-council-private
EOF
  cat >"${jobs}/failed/${job_id}.job" <<EOF
JOB_ID=${job_id}
JOB_TYPE=ai_exec
REPO_NAME=ai-council-private
REQUEST_SOURCE=github_issue_601
REQUESTED_BY=tester
CREATED_AT=2026-09-01T00:00:00Z
EOF
  : >"${state}/posted/${job_id}.terminal.posted"
  : >"${logs}/pending-posts/${job_id}-old.md"

  sudo env \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_JOB_ROOT="${jobs}" \
    AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    bash "${REPO_ROOT}/scripts/requeue_github_issue.sh" 601 >"${output}" 2>&1

  assert_file "${jobs}/queue/${job_id}.job"
  assert_missing "${jobs}/failed/${job_id}.job"
  assert_contains "${output}" "GITHUB_ISSUE_REQUEUE_STATUS: OK"
  find "${state}/requeue-archive/issue-601" -type f -name "${job_id}.terminal.posted" | grep -q . || fail "posted marker was not archived"
  find "${state}/requeue-archive/issue-601" -type f -name "${job_id}-old.md" | grep -q . || fail "pending report was not archived"
  pass "failed issue job can be requeued without duplicating an active or done job"
}

test_requeue_refuses_active_job() {
  local root="${TEST_ROOT}/requeue-active"
  local state="${root}/state"
  local jobs="${root}/jobs"
  local logs="${root}/logs"
  local output="${root}/requeue.log"
  local job_id="active-job"

  mkdir -p "${state}/imported" "${jobs}/active" "${logs}"
  cat >"${state}/imported/issue-602.imported" <<EOF
ISSUE_NUMBER=602
JOB_ID=${job_id}
JOB_TYPE=ai_exec
REPO_NAME=ai-council
EOF
  : >"${jobs}/active/${job_id}.job"

  set +e
  sudo env \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${state}" \
    AI_COUNCIL_JOB_ROOT="${jobs}" \
    AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    bash "${REPO_ROOT}/scripts/requeue_github_issue.sh" 602 >"${output}" 2>&1
  rc=$?
  set -e

  [[ "${rc}" -ne 0 ]] || fail "active job requeue should fail"
  assert_file "${jobs}/active/${job_id}.job"
  assert_contains "${output}" "GITHUB_ISSUE_REQUEUE_STATUS: ACTIVE"
  pass "active job cannot be duplicated by the requeue utility"
}

test_repo_check_privilege_separation() {
  local script="${REPO_ROOT}/scripts/run_repo_check.sh"

  assert_contains "${script}" 'sudo -H -u "${OPERATOR_USER}" -- "$@"'
  assert_contains "${script}" 'run_as_operator git -C "${REPO_PATH}" status --short'
  assert_contains "${script}" 'run_as_operator npm --prefix "${REPO_PATH}" run'
  assert_contains "${script}" 'run_as_operator python3 --version'

  if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?(npm|node|python3)[[:space:]]' "${script}"; then
    fail "repository-controlled runtime command can execute outside run_as_operator"
  fi

  pass "repo checks execute repository-controlled commands as the unprivileged operator"
}

test_result_filter_is_anchored() {
  local script="${REPO_ROOT}/scripts/post_job_result_to_github.sh"

  assert_contains "${script}" "'^- (Generated At|Job ID|Job Type|Repo Name|Repo Path|Request Source|Requested By|Created At|Plan File|Latest Plan|Check File|Latest Check|Exec File|Latest Exec|CLI Provider|Status Reason|Guard Status|Allowed Hours JST|Current Hour JST|Max Per Hour|Hourly Count Before Run|Max Per Day|Daily Count Before Run|Cycle Log|Retry State|Retry After):|^(REPO_CHECK_STATUS|WORKSPACE_SUMMARY_STATUS|AI_PLAN_STATUS|AI_CHECK_STATUS|AI_EXEC_STATUS|JOB_RUNNER_STATUS):'"
  pass "GitHub result comments cannot include arbitrary matching lines from prompts or CLI output"
}

bash -n "${REPO_ROOT}"/scripts/*.sh

test_pending_post_flush
test_requeue_failed_job
test_requeue_refuses_active_job
test_repo_check_privilege_separation
test_result_filter_is_anchored

echo "RECOVERY_REGRESSION_TEST_STATUS: OK (${pass_count} tests)"
