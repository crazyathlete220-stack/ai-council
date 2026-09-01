#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

app="${tmp}/app"
public_workspace="${tmp}/public-workspace"
private_workspace="${tmp}/private-workspace"
registry="${tmp}/registry"
jobs="${tmp}/jobs"
bridge_state="${tmp}/bridge-state"
bin="${tmp}/bin"

mkdir -p \
  "${app}/scripts" "${app}/docs" \
  "${public_workspace}/scripts" "${public_workspace}/docs" \
  "${private_workspace}" "${registry}" "${bin}" \
  "${jobs}/queue" "${jobs}/active" "${jobs}/done" "${jobs}/failed" \
  "${bridge_state}/imported" "${bridge_state}/blocked" \
  "${bridge_state}/rejected" "${bridge_state}/posted"

runtime_files=(
  "scripts/import_github_jobs.sh"
  "scripts/run_job_once.sh"
  "scripts/run_job_cycle.sh"
  "scripts/report_job_result.sh"
  "scripts/post_job_result_to_github.sh"
  "scripts/requeue_github_issue.sh"
  "scripts/deploy_runtime.sh"
  "scripts/run_runtime_audit.sh"
  "docs/durable-job-lifecycle.md"
)

for relative in "${runtime_files[@]}"; do
  mkdir -p "$(dirname "${public_workspace}/${relative}")" "$(dirname "${app}/${relative}")"
  if [[ "${relative}" == "scripts/run_runtime_audit.sh" ]]; then
    cp "${ROOT_DIR}/${relative}" "${public_workspace}/${relative}"
  else
    printf 'test runtime file: %s\n' "${relative}" > "${public_workspace}/${relative}"
  fi
  cp "${public_workspace}/${relative}" "${app}/${relative}"
done

git -C "${public_workspace}" init -q
git -C "${public_workspace}" config user.name test
git -C "${public_workspace}" config user.email test@example.com
git -C "${public_workspace}" add .
git -C "${public_workspace}" commit -qm "runtime fixture"
public_head="$(git -C "${public_workspace}" rev-parse HEAD)"

git -C "${private_workspace}" init -q
git -C "${private_workspace}" config user.name test
git -C "${private_workspace}" config user.email test@example.com
printf 'private fixture\n' > "${private_workspace}/README.md"
git -C "${private_workspace}" add README.md
git -C "${private_workspace}" commit -qm "private fixture"
private_head="$(git -C "${private_workspace}" rev-parse HEAD)"

cat > "${registry}/ai-council.env" <<EOF_PUBLIC
REPO_NAME=ai-council
REPO_PATH=${public_workspace}
LOG_DIR=${tmp}/public-log
EOF_PUBLIC

cat > "${registry}/ai-council-private.env" <<EOF_PRIVATE
REPO_NAME=ai-council-private
REPO_PATH=${private_workspace}
LOG_DIR=${tmp}/private-log
EOF_PRIVATE

job_id="test-job-91"
cat > "${bridge_state}/imported/issue-91.imported" <<EOF_MARKER
ISSUE_NUMBER=91
JOB_ID=${job_id}
STATE=QUEUED
EOF_MARKER
printf 'JOB_ID=%s\n' "${job_id}" > "${jobs}/done/${job_id}.job"
printf 'POSTED=1\n' > "${bridge_state}/posted/${job_id}-OK.posted"

cat > "${bin}/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
unit="${2:-}"
case "${command_name}" in
  is-active)
    case "${unit}" in
      *.timer) echo active; exit 0 ;;
      *.service) echo inactive; exit 3 ;;
    esac
    ;;
  is-enabled)
    case "${unit}" in
      *.timer) echo enabled; exit 0 ;;
      *.service) echo static; exit 0 ;;
    esac
    ;;
  show)
    case "${unit}" in
      ai-council-github-bridge.service)
        echo "{ path=${AI_COUNCIL_APP_DIR}/scripts/import_github_jobs.sh ; }"
        exit 0
        ;;
      ai-council-job-runner.service)
        echo "{ path=${AI_COUNCIL_APP_DIR}/scripts/run_job_cycle.sh ; }"
        exit 0
        ;;
    esac
    ;;
esac
exit 1
SCRIPT
chmod +x "${bin}/systemctl"

cat > "${bin}/journalctl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SCRIPT
chmod +x "${bin}/journalctl"

cat > "${bin}/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
exit 1
SCRIPT
chmod +x "${bin}/gh"

cat > "${bin}/sudo" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then
  exit 0
fi
exit 1
SCRIPT
chmod +x "${bin}/sudo"

run_audit() {
  PATH="${bin}:${PATH}" \
  AI_COUNCIL_APP_DIR="${app}" \
  AI_COUNCIL_WORKSPACE_REGISTRY_DIR="${registry}" \
  AI_COUNCIL_JOB_ROOT="${jobs}" \
  AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT="${bridge_state}" \
  AI_COUNCIL_PUBLIC_WORKSPACE="${public_workspace}" \
  bash "${ROOT_DIR}/scripts/run_runtime_audit.sh" \
    ai-council-private \
    91 \
    "${public_head}" \
    "${private_head}"
}

healthy_output="$(run_audit)"
printf '%s\n' "${healthy_output}"

grep -q '^MERGED_RUNTIME_PRESENT: YES$' <<< "${healthy_output}"
grep -q '^EXPECTED_RUNTIME_RELATION: EXACT$' <<< "${healthy_output}"
grep -q '^BRIDGE_RUNTIME_MODE: IMPORT_ONLY$' <<< "${healthy_output}"
grep -q '^BRIDGE_TIMER: active, enabled$' <<< "${healthy_output}"
grep -q '^RUNNER_RUNTIME_MODE: DURABLE_CYCLE$' <<< "${healthy_output}"
grep -q '^RUNNER_TIMER: active, enabled$' <<< "${healthy_output}"
grep -q '^PRIVATE_CONFIG: EXISTS$' <<< "${healthy_output}"
grep -q '^PRIVATE_WORKSPACE: OK$' <<< "${healthy_output}"
grep -q '^PRIVATE_EXPECTED_RELATION: EXACT$' <<< "${healthy_output}"
grep -q '^ISSUE_91_STATE: DONE$' <<< "${healthy_output}"
grep -q '^ISSUE_91_POSTED: YES$' <<< "${healthy_output}"
grep -q '^RUNTIME_RECOVERY_STATUS: READY$' <<< "${healthy_output}"
grep -q '^RUNTIME_AUDIT_STATUS: COMPLETE$' <<< "${healthy_output}"

rm -rf "${private_workspace}"
blocked_output="$(run_audit)"
printf '%s\n' "${blocked_output}"
grep -q '^PRIVATE_WORKSPACE: MISSING$' <<< "${blocked_output}"
grep -q '^RUNTIME_RECOVERY_STATUS: BLOCKED_PRIVATE_WORKSPACE$' <<< "${blocked_output}"
grep -q '^RUNTIME_AUDIT_STATUS: COMPLETE$' <<< "${blocked_output}"

echo "test_runtime_audit: OK"
