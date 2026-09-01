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
  sudo test -f "$1" || fail "expected file: $1"
}

assert_missing() {
  sudo test ! -e "$1" || fail "unexpected path: $1"
}

assert_contains() {
  sudo grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

make_fixture() {
  local root="$1"
  local bin="${root}/bin"
  local app="${root}/app"

  sudo mkdir -p "${bin}" "${app}/scripts" "${root}/jobs/queue" "${root}/state" "${root}/logs"

  sudo tee "${bin}/gh" >/dev/null <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  cat "${GH_ISSUES_FILE:?}"
  exit 0
fi
exit 1
STUB
  sudo chmod +x "${bin}/gh"

  sudo tee "${app}/scripts/create_job.sh" >/dev/null <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
job_type="$1"
repo_name="$2"
issue_number="${AI_COUNCIL_REQUEST_SOURCE#github_issue_}"
job_id="fixture-${issue_number}-${job_type}-${repo_name}"
job_file="${AI_COUNCIL_JOB_ROOT}/queue/${job_id}.job"
cat >"${job_file}" <<EOF
JOB_ID=${job_id}
JOB_TYPE=${job_type}
REPO_NAME=${repo_name}
REQUEST_SOURCE=${AI_COUNCIL_REQUEST_SOURCE}
REQUESTED_BY=${AI_COUNCIL_REQUESTED_BY}
CREATED_AT=2026-09-01T00:00:00Z
EOF
echo "JOB_ID=${job_id}"
STUB
  sudo chmod +x "${app}/scripts/create_job.sh"

  sudo tee "${root}/allowlist" >/dev/null <<'EOF'
tester
EOF
  sudo chmod 0644 "${root}/allowlist"
}

write_workspace_config() {
  local root="$1"
  local mode="${2:-0644}"
  local workspace="${root}/workspaces/ai-council-private"
  local registry="${root}/registry"

  sudo mkdir -p "${workspace}/.git" "${registry}" "${root}/workspace-logs"
  sudo tee "${registry}/ai-council-private.env" >/dev/null <<EOF
REPO_NAME=ai-council-private
REPO_PATH=${workspace}
LOG_DIR=${root}/workspace-logs
EOF
  sudo chown root:root "${registry}/ai-council-private.env"
  sudo chmod "${mode}" "${registry}/ai-council-private.env"
}

run_importer() {
  local root="$1"
  local issues_file="$2"
  local output_file="$3"
  local scan_limit="${4:-1000}"
  local import_limit="${5:-20}"

  sudo env \
    PATH="${root}/bin:${PATH}" \
    GH_ISSUES_FILE="${issues_file}" \
    AI_COUNCIL_APP_DIR="${root}/app" \
    AI_COUNCIL_GITHUB_REPO="owner/repo" \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${root}/state" \
    AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR="${root}/logs" \
    AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE="${root}/allowlist" \
    AI_COUNCIL_WORKSPACE_REGISTRY_DIR="${root}/registry" \
    AI_COUNCIL_WORKSPACE_ROOT="${root}/workspaces" \
    AI_COUNCIL_JOB_ROOT="${root}/jobs" \
    AI_COUNCIL_GITHUB_SCAN_LIMIT="${scan_limit}" \
    AI_COUNCIL_GITHUB_IMPORT_LIMIT="${import_limit}" \
    bash "${REPO_ROOT}/scripts/import_github_jobs.sh" >"${output_file}" 2>&1
}

test_missing_workspace_blocks_then_recovers() {
  local root="${TEST_ROOT}/workspace-recovery"
  local issues="${root}/issues.json"
  local first_output="${root}/first.log"
  local second_output="${root}/second.log"

  make_fixture "${root}"
  sudo tee "${issues}" >/dev/null <<'EOF'
[
  {
    "number": 701,
    "title": "workspace check",
    "body": "JOB_TYPE=ai_check\nREPO_NAME=ai-council-private",
    "author": {"login": "tester"},
    "updatedAt": "2026-09-01T00:00:00Z"
  }
]
EOF

  run_importer "${root}" "${issues}" "${first_output}"
  assert_contains "${first_output}" "Blocking issue #701: WORKSPACE_NOT_REGISTERED"
  assert_file "${root}/state/blocked/issue-701-WORKSPACE_NOT_REGISTERED.blocked"
  assert_missing "${root}/state/imported/issue-701.imported"
  assert_missing "${root}/jobs/queue/fixture-701-ai_check-ai-council-private.job"

  write_workspace_config "${root}" 0644
  run_importer "${root}" "${issues}" "${second_output}"
  assert_file "${root}/state/imported/issue-701.imported"
  assert_file "${root}/jobs/queue/fixture-701-ai_check-ai-council-private.job"
  assert_missing "${root}/state/blocked/issue-701-WORKSPACE_NOT_REGISTERED.blocked"
  pass "missing workspace blocks before queue creation and imports automatically after repair"
}

test_scan_limit_does_not_starve_unimported_issue() {
  local root="${TEST_ROOT}/scan-starvation"
  local issues="${root}/issues.json"
  local output="${root}/import.log"
  local i=""

  make_fixture "${root}"
  write_workspace_config "${root}" 0644

  sudo bash -c '
    printf "[" >"$1"
    for i in $(seq 1 25); do
      if [[ "$i" -gt 1 ]]; then printf "," >>"$1"; fi
      printf "{\"number\":%s,\"title\":\"issue %s\",\"body\":\"JOB_TYPE=ai_check\\nREPO_NAME=ai-council-private\",\"author\":{\"login\":\"tester\"},\"updatedAt\":\"2026-09-01T00:00:00Z\"}" "$i" "$i" >>"$1"
    done
    printf "]" >>"$1"
  ' bash "${issues}"

  sudo mkdir -p "${root}/state/imported"
  for i in $(seq 1 20); do
    sudo tee "${root}/state/imported/issue-${i}.imported" >/dev/null <<EOF
ISSUE_NUMBER=${i}
JOB_ID=old-${i}
JOB_TYPE=ai_check
REPO_NAME=ai-council-private
EOF
  done

  run_importer "${root}" "${issues}" "${output}" 1000 1
  assert_file "${root}/state/imported/issue-21.imported"
  assert_file "${root}/jobs/queue/fixture-21-ai_check-ai-council-private.job"
  assert_contains "${output}" "Scanned: 25/1000"
  assert_contains "${output}" "Imported: 1/1"
  pass "already imported open issues do not starve later eligible issues"
}

test_unsafe_workspace_config_is_blocked() {
  local root="${TEST_ROOT}/unsafe-config"
  local issues="${root}/issues.json"
  local output="${root}/import.log"

  make_fixture "${root}"
  write_workspace_config "${root}" 0666
  sudo tee "${issues}" >/dev/null <<'EOF'
[
  {
    "number": 702,
    "title": "unsafe config",
    "body": "JOB_TYPE=ai_check\nREPO_NAME=ai-council-private",
    "author": {"login": "tester"},
    "updatedAt": "2026-09-01T00:00:00Z"
  }
]
EOF

  run_importer "${root}" "${issues}" "${output}"
  assert_file "${root}/state/blocked/issue-702-WORKSPACE_CONFIG_UNSAFE.blocked"
  assert_missing "${root}/state/imported/issue-702.imported"
  pass "group/world-writable workspace registry files are rejected before sourcing"
}

test_invalid_job_type_is_rejected() {
  local root="${TEST_ROOT}/invalid-job"
  local issues="${root}/issues.json"
  local output="${root}/import.log"

  make_fixture "${root}"
  sudo tee "${issues}" >/dev/null <<'EOF'
[
  {
    "number": 703,
    "title": "invalid job",
    "body": "JOB_TYPE=root_shell\nREPO_NAME=ai-council",
    "author": {"login": "tester"},
    "updatedAt": "2026-09-01T00:00:00Z"
  }
]
EOF

  run_importer "${root}" "${issues}" "${output}"
  assert_file "${root}/state/rejected/issue-703-UNSUPPORTED_JOB_TYPE.rejected"
  assert_missing "${root}/state/imported/issue-703.imported"
  pass "unsupported job types are persistently rejected instead of retried silently"
}

bash -n "${REPO_ROOT}/scripts/import_github_jobs.sh"

test_missing_workspace_blocks_then_recovers
test_scan_limit_does_not_starve_unimported_issue
test_unsafe_workspace_config_is_blocked
test_invalid_job_type_is_rejected

echo "IMPORTER_PREFLIGHT_TEST_STATUS: OK (${pass_count} tests)"
