#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/app/scripts" "${tmp}/state" "${tmp}/logs" "${tmp}/registry" "${tmp}/jobs/queue"

cat > "${tmp}/bin/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  cat <<'JSON'
[{"number":777,"title":"test","body":"JOB_TYPE=ai_check\nREPO_NAME=missing-repo\n","author":{"login":"test-owner"},"updatedAt":"2026-09-02T00:00:00Z"}]
JSON
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  printf '%s\n' "$*" >> "${GH_CAPTURE_FILE}"
  exit 0
fi
exit 1
SCRIPT
chmod +x "${tmp}/bin/gh"

cat > "${tmp}/app/scripts/create_job.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo called >> "${CREATE_CAPTURE_FILE}"
echo "JOB_ID=test-created-job"
SCRIPT
chmod +x "${tmp}/app/scripts/create_job.sh"
printf 'test-owner\n' > "${tmp}/allowlist"

common_env=(
  PATH="${tmp}/bin:${PATH}"
  GH_CAPTURE_FILE="${tmp}/comments.txt"
  CREATE_CAPTURE_FILE="${tmp}/create.txt"
  AI_COUNCIL_APP_DIR="${tmp}/app"
  AI_COUNCIL_GITHUB_REPO="owner/repo"
  AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${tmp}/state"
  AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR="${tmp}/logs"
  AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE="${tmp}/allowlist"
  AI_COUNCIL_WORKSPACE_REGISTRY_DIR="${tmp}/registry"
)

env "${common_env[@]}" bash "${ROOT_DIR}/scripts/import_github_jobs.sh" >/dev/null
test -f "${tmp}/state/blocked/issue-777.blocked"
test ! -e "${tmp}/create.txt"
grep -q 'WORKSPACE_NOT_REGISTERED' "${tmp}/comments.txt"

printf 'REPO_NAME=missing-repo\nREPO_PATH=/tmp/missing-repo\nLOG_DIR=/tmp/log\n' > "${tmp}/registry/missing-repo.env"
env "${common_env[@]}" bash "${ROOT_DIR}/scripts/import_github_jobs.sh" >/dev/null
test ! -e "${tmp}/state/blocked/issue-777.blocked"
test -f "${tmp}/state/imported/issue-777.imported"
grep -q '^called$' "${tmp}/create.txt"
grep -q 'STATE: QUEUED' "${tmp}/comments.txt"

echo "test_import_workspace_block: OK"
