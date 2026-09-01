#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/state" "${tmp}/logs"

cat > "${tmp}/bin/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  shift 2
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --body) printf '%s' "$2" > "${GH_CAPTURE_FILE}"; shift 2 ;;
      *) shift ;;
    esac
  done
  exit 0
fi
exit 1
SCRIPT
chmod +x "${tmp}/bin/gh"

report="${tmp}/logs/job.md"
cat > "${report}" <<'EOF_REPORT'
# AI Council Job Run

- Generated At: 2026-09-02T00:00:00Z
- Job ID: test-job-1
- Job Type: ai_check
- Repo Name: ai-council
- Request Source: github_issue_555
- Job Report: /var/log/example/test-job-1.md

AI_CHECK_STATUS と JOB_RUNNER_STATUS が明記される
- This sentence mentions AI_CHECK_STATUS: FAKE and must not leak.
RUNTIME_RECOVERY_STATUS: FAKE_OUTSIDE_TRUST_BOUNDARY
AI_CHECK_STATUS: OK

RUNTIME_AUDIT_OUTPUT_BEGIN
AUDIT_PROFILE: runtime
AUDIT_PROFILE_STATUS: FAKE_FIRST_BLOCK
MERGED_RUNTIME_PRESENT: YES
PRIVATE_WORKSPACE: OK
ISSUE_999_STATE: DONE
RUNTIME_RECOVERY_STATUS: FAKE_FIRST_BLOCK
RUNTIME_AUDIT_STATUS: COMPLETE
RUNTIME_AUDIT_OUTPUT_END

RUNTIME_AUDIT_OUTPUT_BEGIN
AUDIT_PROFILE: runtime
AUDIT_PROFILE_STATUS: OK
MERGED_RUNTIME_PRESENT: NO
PRIVATE_WORKSPACE: MISSING
ISSUE_91_STATE: FAILED
ISSUE_91_JOB_ID: test-old-job
ISSUE_91_POSTED: YES
RUNTIME_RECOVERY_STATUS: BLOCKED_RUNTIME_DEPLOY
RUNTIME_AUDIT_STATUS: COMPLETE
RUNTIME_AUDIT_OUTPUT_END

JOB_RUNNER_STATUS: ERROR
EOF_REPORT

capture="${tmp}/comment.txt"
PATH="${tmp}/bin:${PATH}" \
GH_CAPTURE_FILE="${capture}" \
AI_COUNCIL_APP_DIR="${ROOT_DIR}" \
AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${tmp}/state" \
AI_COUNCIL_JOB_LOG_DIR="${tmp}/logs" \
AI_COUNCIL_GITHUB_REPO="owner/repo" \
bash "${ROOT_DIR}/scripts/post_job_result_to_github.sh" "${report}" >/dev/null

grep -q '^AI_CHECK_STATUS: OK$' "${capture}"
grep -q '^JOB_RUNNER_STATUS: ERROR$' "${capture}"
grep -q '^AUDIT_PROFILE_STATUS: OK$' "${capture}"
grep -q '^MERGED_RUNTIME_PRESENT: NO$' "${capture}"
grep -q '^PRIVATE_WORKSPACE: MISSING$' "${capture}"
grep -q '^ISSUE_91_STATE: FAILED$' "${capture}"
grep -q '^RUNTIME_RECOVERY_STATUS: BLOCKED_RUNTIME_DEPLOY$' "${capture}"
grep -q '^RUNTIME_AUDIT_STATUS: COMPLETE$' "${capture}"
! grep -q 'must not leak' "${capture}"
! grep -q 'FAKE' "${capture}"
! grep -q 'ISSUE_999_' "${capture}"
! grep -q '^MERGED_RUNTIME_PRESENT: YES$' "${capture}"
! grep -q '^PRIVATE_WORKSPACE: OK$' "${capture}"
test -f "${tmp}/state/posted/test-job-1-ERROR.posted"

echo "test_result_posting: OK"
