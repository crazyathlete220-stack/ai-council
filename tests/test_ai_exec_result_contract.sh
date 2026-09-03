#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="${ROOT_DIR}/scripts/classify_ai_exec_result.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

assert_exit() {
  local expected="$1"
  local file="$2"
  local output_file="$3"
  local status=0

  set +e
  bash "${CLASSIFIER}" "${file}" > "${output_file}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq "${expected}" ]]
}

printf 'done\nAI_EXEC_RESULT: SUCCESS\n' > "${tmp}/success.md"
assert_exit 0 "${tmp}/success.md" "${tmp}/success.out"
grep -q '^AI_EXEC_RESULT_CONTRACT_STATUS: VERIFIED_SUCCESS$' "${tmp}/success.out"

printf 'blocked\nAI_EXEC_RESULT: BLOCKED\n' > "${tmp}/blocked.md"
assert_exit 20 "${tmp}/blocked.md" "${tmp}/blocked.out"
grep -q '^AI_EXEC_RESULT_CONTRACT_STATUS: VERIFIED_BLOCKED$' "${tmp}/blocked.out"

printf 'failed\nAI_EXEC_RESULT: FAILED\n' > "${tmp}/failed.md"
assert_exit 21 "${tmp}/failed.md" "${tmp}/failed.out"
grep -q '^AI_EXEC_RESULT_CONTRACT_STATUS: VERIFIED_FAILED$' "${tmp}/failed.out"

printf 'no marker\n' > "${tmp}/missing.md"
assert_exit 22 "${tmp}/missing.md" "${tmp}/missing.out"
grep -q '^AI_EXEC_RESULT_REASON: required_marker_missing$' "${tmp}/missing.out"

printf 'AI_EXEC_RESULT: SUCCESS\nAI_EXEC_RESULT: BLOCKED\n' > "${tmp}/multiple.md"
assert_exit 22 "${tmp}/multiple.md" "${tmp}/multiple.out"
grep -q '^AI_EXEC_RESULT_MARKER: MULTIPLE$' "${tmp}/multiple.out"

printf 'AI_EXEC_RESULT: SUCCESS\ntrailing text\n' > "${tmp}/not-final.md"
assert_exit 22 "${tmp}/not-final.md" "${tmp}/not-final.out"
grep -q '^AI_EXEC_RESULT_MARKER: NOT_FINAL$' "${tmp}/not-final.out"

run_cycle_case() {
  local name="$1"
  local marker_text="$2"
  local expected_exit="$3"
  local expected_ai_status="$4"
  local expected_job_dir="$5"
  local case_root="${tmp}/${name}"
  local app="${case_root}/app"
  local jobs="${case_root}/jobs"
  local logs="${case_root}/logs"
  local job_id="contract-${name}"
  local report="${logs}/reports/${job_id}.md"
  local last_message="${logs}/last-${name}.md"
  local status=0

  mkdir -p "${app}/scripts" "${jobs}/done" "${jobs}/failed" "${logs}/reports"
  cp "${CLASSIFIER}" "${app}/scripts/classify_ai_exec_result.sh"
  cp "${ROOT_DIR}/scripts/run_job_cycle.sh" "${app}/scripts/run_job_cycle.sh"

  printf 'result\n%s\n' "${marker_text}" > "${last_message}"
  cat > "${report}" <<EOF_REPORT
# AI Council Job Run

- Job ID: ${job_id}
- Job Type: ai_exec
- Request Source: github_issue_900
- Last Message: ${last_message}

AI_EXEC_STATUS: OK
JOB_RUNNER_STATUS: OK
EOF_REPORT
  printf 'JOB_ID=%s\nJOB_TYPE=ai_exec\n' "${job_id}" > "${jobs}/done/${job_id}.job"

  cat > "${app}/scripts/run_job_once.sh" <<EOF_RUNNER
#!/usr/bin/env bash
echo "JOB_REPORT_FILE: ${report}"
echo "JOB_RUNNER_STATUS: OK"
exit 0
EOF_RUNNER
  chmod +x "${app}/scripts/run_job_once.sh"

  cat > "${app}/scripts/report_job_result.sh" <<'EOF_STUB'
#!/usr/bin/env bash
exit 0
EOF_STUB
  cat > "${app}/scripts/post_job_result_to_github.sh" <<'EOF_STUB'
#!/usr/bin/env bash
exit 0
EOF_STUB
  chmod +x "${app}/scripts/report_job_result.sh" "${app}/scripts/post_job_result_to_github.sh"

  set +e
  AI_COUNCIL_APP_DIR="${app}" \
  AI_COUNCIL_JOB_ROOT="${jobs}" \
  AI_COUNCIL_JOB_LOG_DIR="${logs}" \
    bash "${app}/scripts/run_job_cycle.sh" > "${case_root}/cycle.out" 2>&1
  status=$?
  set -e

  [[ "${status}" -eq "${expected_exit}" ]]
  grep -q "^AI_EXEC_STATUS: ${expected_ai_status}$" "${report}"
  test -f "${jobs}/${expected_job_dir}/${job_id}.job"
}

run_cycle_case success 'AI_EXEC_RESULT: SUCCESS' 0 OK done
run_cycle_case blocked 'AI_EXEC_RESULT: BLOCKED' 1 BLOCKED failed
run_cycle_case failed 'AI_EXEC_RESULT: FAILED' 1 FAILED failed
run_cycle_case missing 'no machine marker' 1 INDETERMINATE failed
run_cycle_case notfinal $'AI_EXEC_RESULT: SUCCESS\ntrailing text' 1 INDETERMINATE failed

echo "test_ai_exec_result_contract: OK"
