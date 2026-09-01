#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

app="${tmp}/app"
logs="${tmp}/logs"
bin="${tmp}/bin"
mkdir -p "${app}/scripts" "${logs}" "${bin}"

cat > "${app}/scripts/run_ai_check_core.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
job_id="${AI_COUNCIL_JOB_ID}"
check_dir="${AI_COUNCIL_AI_WORKER_LOG_ROOT}/${job_id}"
mkdir -p "${check_dir}"
cat > "${check_dir}/check.md" <<EOF_CHECK
# Stub generic check
- Job ID: ${job_id}
RUNTIME_RECOVERY_STATUS: FAKE_CORE_VALUE
AI_CHECK_STATUS: OK
EOF_CHECK
cp "${check_dir}/check.md" "${AI_COUNCIL_AI_WORKER_LOG_ROOT}/latest-check.md"
cat "${check_dir}/check.md"
SCRIPT
chmod +x "${app}/scripts/run_ai_check_core.sh"

cat > "${app}/scripts/run_runtime_audit.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${AUDIT_ARG_CAPTURE}"
printf 'called\n' >> "${AUDIT_CALL_CAPTURE}"
echo "MERGED_RUNTIME_PRESENT: YES"
echo "PRIVATE_WORKSPACE: MISSING"
echo "ISSUE_91_STATE: FAILED"
echo "RUNTIME_RECOVERY_STATUS: BLOCKED_PRIVATE_WORKSPACE"
echo "RUNTIME_AUDIT_STATUS: COMPLETE"
SCRIPT
chmod +x "${app}/scripts/run_runtime_audit.sh"

cat > "${bin}/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  cat "${GH_ISSUE_JSON_FILE}"
  exit 0
fi
exit 1
SCRIPT
chmod +x "${bin}/gh"

valid_json="${tmp}/valid.json"
cat > "${valid_json}" <<'JSON'
{"body":"JOB_TYPE=ai_check\nREPO_NAME=ai-council\nAUDIT_PROFILE=runtime\nAUDIT_REPO=ai-council-private\nAUDIT_ISSUES=91,98,101\nAUDIT_EXPECTED_RUNTIME_COMMIT=2ed27b67ff01edbbd5ec1fd6504dcd6c74309bd5\nAUDIT_EXPECTED_PRIVATE_COMMIT=1726398a4602a57c671e76c9bda04da15a6606b5\nRUNTIME_RECOVERY_STATUS=FAKE_ISSUE_VALUE\nDANGEROUS_COMMAND=touch /tmp/never-run\n"}
JSON

audit_args="${tmp}/audit-args.txt"
audit_calls="${tmp}/audit-calls.txt"
output="$(
  PATH="${bin}:${PATH}" \
  GH_ISSUE_JSON_FILE="${valid_json}" \
  AUDIT_ARG_CAPTURE="${audit_args}" \
  AUDIT_CALL_CAPTURE="${audit_calls}" \
  AI_COUNCIL_APP_DIR="${app}" \
  AI_COUNCIL_AI_WORKER_LOG_ROOT="${logs}" \
  AI_COUNCIL_GITHUB_REPO="owner/repo" \
  AI_COUNCIL_JOB_ID="test-wrapper-1" \
  AI_COUNCIL_REQUEST_SOURCE="github_issue_321" \
  bash "${ROOT_DIR}/scripts/run_ai_check.sh" ai-council
)"
printf '%s\n' "${output}"

grep -q '^# Stub generic check$' <<< "${output}"
grep -q '^RUNTIME_AUDIT_OUTPUT_BEGIN$' <<< "${output}"
grep -q '^AUDIT_PROFILE_STATUS: OK$' <<< "${output}"
grep -q '^MERGED_RUNTIME_PRESENT: YES$' <<< "${output}"
grep -q '^PRIVATE_WORKSPACE: MISSING$' <<< "${output}"
grep -q '^RUNTIME_RECOVERY_STATUS: BLOCKED_PRIVATE_WORKSPACE$' <<< "${output}"
grep -q '^RUNTIME_AUDIT_STATUS: COMPLETE$' <<< "${output}"
grep -q '^RUNTIME_AUDIT_OUTPUT_END$' <<< "${output}"

mapfile -t captured_args < "${audit_args}"
test "${captured_args[0]}" = "ai-council-private"
test "${captured_args[1]}" = "91,98,101"
test "${captured_args[2]}" = "2ed27b67ff01edbbd5ec1fd6504dcd6c74309bd5"
test "${captured_args[3]}" = "1726398a4602a57c671e76c9bda04da15a6606b5"
test "$(wc -l < "${audit_calls}" | tr -d '[:space:]')" = "1"

grep -q '^RUNTIME_AUDIT_OUTPUT_BEGIN$' "${logs}/test-wrapper-1/check.md"
grep -q '^RUNTIME_AUDIT_STATUS: COMPLETE$' "${logs}/test-wrapper-1/check.md"

invalid_json="${tmp}/invalid.json"
cat > "${invalid_json}" <<'JSON'
{"body":"JOB_TYPE=ai_check\nREPO_NAME=ai-council\nAUDIT_PROFILE=runtime\nAUDIT_REPO=bad;touch-never\nAUDIT_ISSUES=91\n"}
JSON

set +e
invalid_output="$(
  PATH="${bin}:${PATH}" \
  GH_ISSUE_JSON_FILE="${invalid_json}" \
  AUDIT_ARG_CAPTURE="${audit_args}" \
  AUDIT_CALL_CAPTURE="${audit_calls}" \
  AI_COUNCIL_APP_DIR="${app}" \
  AI_COUNCIL_AI_WORKER_LOG_ROOT="${logs}" \
  AI_COUNCIL_GITHUB_REPO="owner/repo" \
  AI_COUNCIL_JOB_ID="test-wrapper-2" \
  AI_COUNCIL_REQUEST_SOURCE="github_issue_322" \
  bash "${ROOT_DIR}/scripts/run_ai_check.sh" ai-council 2>&1
)"
invalid_status=$?
set -e

printf '%s\n' "${invalid_output}"
test "${invalid_status}" -ne 0
grep -q '^AUDIT_PROFILE_STATUS: ERROR$' <<< "${invalid_output}"
grep -q '^RUNTIME_AUDIT_STATUS: ERROR$' <<< "${invalid_output}"
grep -q 'unsafe AUDIT_REPO' <<< "${invalid_output}"
test "$(wc -l < "${audit_calls}" | tr -d '[:space:]')" = "1"

echo "test_ai_check_audit_wrapper: OK"
