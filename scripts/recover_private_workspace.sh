#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

MODE="${1:---check}"
CONTROL_REPO="${AI_COUNCIL_RECOVERY_CONTROL_REPO:-crazyathlete220-stack/ai-council-private}"
PRIVATE_REPO_NAME="${AI_COUNCIL_RECOVERY_PRIVATE_NAME:-ai-council-private}"
PRIVATE_PATH="${AI_COUNCIL_RECOVERY_PRIVATE_PATH:-/opt/ai-workspaces/ai-council-private}"
RUNTIME_CONFIG="${AI_COUNCIL_RUNTIME_CONFIG:-/etc/ai-council/runtime.env}"
ALLOWLIST_FILE="${AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE:-/etc/ai-council/github-bridge-allowlist}"
OWNER_LOGIN="${AI_COUNCIL_RECOVERY_OWNER:-crazyathlete220-stack}"
TARGET_ISSUE="${AI_COUNCIL_RECOVERY_ISSUE:-91}"
MIN_PUBLIC_COMMIT="${AI_COUNCIL_RECOVERY_MIN_PUBLIC_COMMIT:-0e3445ae03c6f19183534b1a13d2db04bca27fea}"
MIN_PRIVATE_COMMIT="${AI_COUNCIL_RECOVERY_MIN_PRIVATE_COMMIT:-1726398a4602a57c671e76c9bda04da15a6606b5}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "RECOVERY_PRIVATE_WORKSPACE_STATUS: BLOCKED" >&2
  echo "BLOCKER: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

git_in() {
  local directory="$1"
  shift
  git -c safe.directory="${directory}" -C "${directory}" "$@"
}

config_value() {
  local file="$1"
  local key="$2"
  awk -F= -v wanted="${key}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == wanted { sub(/^[^=]*=/, ""); print; exit }
  ' "${file}"
}

replace_or_append_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp="${file}.rewrite.$$"

  awk -F= -v wanted="${key}" -v replacement="${key}=${value}" '
    BEGIN { replaced=0 }
    $1 == wanted {
      if (!replaced) print replacement
      replaced=1
      next
    }
    { print }
    END { if (!replaced) print replacement }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

merge_missing_template_keys() {
  local target="$1"
  local template="$2"
  local key=""
  local value=""

  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    [[ -n "${key}" && "${key}" != \#* ]] || continue
    if ! grep -Eq "^${key}=" "${target}"; then
      printf '%s=%s\n' "${key}" "${value}" >> "${target}"
    fi
  done < "${template}"
}

check_repo_clean() {
  local directory="$1"
  [[ -d "${directory}/.git" ]] || fail "not a Git workspace: ${directory}"
  [[ -z "$(git_in "${directory}" status --porcelain)" ]] || fail "workspace is dirty: ${directory}"
}

check_ancestor() {
  local directory="$1"
  local expected="$2"
  git_in "${directory}" cat-file -e "${expected}^{commit}" >/dev/null 2>&1 || fail "expected commit is not present in ${directory}: ${expected}"
  git_in "${directory}" merge-base --is-ancestor "${expected}" HEAD >/dev/null 2>&1 || fail "workspace HEAD does not contain expected commit: ${expected}"
}

preflight() {
  require_command git
  require_command gh
  require_command awk
  require_command jq
  require_command systemctl

  [[ "${CONTROL_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "unsafe CONTROL_REPO"
  [[ "${PRIVATE_REPO_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe PRIVATE_REPO_NAME"
  [[ "${PRIVATE_PATH}" == /* && "${PRIVATE_PATH}" != *".."* ]] || fail "unsafe PRIVATE_PATH"
  [[ "${TARGET_ISSUE}" =~ ^[0-9]+$ ]] || fail "TARGET_ISSUE must be numeric"
  [[ "${OWNER_LOGIN}" =~ ^[A-Za-z0-9-]+$ ]] || fail "unsafe OWNER_LOGIN"
  [[ "${MIN_PUBLIC_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "invalid MIN_PUBLIC_COMMIT"
  [[ "${MIN_PRIVATE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "invalid MIN_PRIVATE_COMMIT"

  for path in \
    scripts/deploy_runtime.sh \
    scripts/validate_runtime_config.sh \
    scripts/register_workspace.sh \
    scripts/setup_ai_cli_runner.sh \
    scripts/requeue_github_issue.sh \
    scripts/run_ai_check.sh \
    config/runtime.env.example \
    tests/run.sh; do
    [[ -f "${REPO_DIR}/${path}" ]] || fail "required reviewed file is missing: ${path}"
  done

  check_repo_clean "${REPO_DIR}"
  check_ancestor "${REPO_DIR}" "${MIN_PUBLIC_COMMIT}"
  bash "${REPO_DIR}/tests/run.sh" >/dev/null
  AI_COUNCIL_RUNTIME_CONFIG="${RUNTIME_CONFIG}" bash "${REPO_DIR}/scripts/deploy_runtime.sh" --check >/dev/null

  echo "RECOVERY_PREFLIGHT_STATUS: OK"
  echo "PUBLIC_HEAD: $(git_in "${REPO_DIR}" rev-parse HEAD)"
  echo "CONTROL_REPO: ${CONTROL_REPO}"
  echo "PRIVATE_PATH: ${PRIVATE_PATH}"
  echo "TARGET_ISSUE: ${TARGET_ISSUE}"
}

if [[ "${MODE}" != "--check" && "${MODE}" != "check" && "${MODE}" != "--execute" && "${MODE}" != "execute" ]]; then
  fail "usage: bash scripts/recover_private_workspace.sh [--check|--execute]"
fi

preflight

if [[ "${MODE}" == "--check" || "${MODE}" == "check" ]]; then
  echo "RECOVERY_PRIVATE_WORKSPACE_STATUS: CHECK_OK"
  exit 0
fi

[[ "${EUID}" -eq 0 ]] || fail "root is required; use non-interactive sudo"
gh auth status --hostname github.com >/dev/null 2>&1 || fail "root GitHub CLI authentication is unavailable"

runtime_template="${REPO_DIR}/config/runtime.env.example"
runtime_tmp="$(mktemp /etc/ai-council/runtime.env.tmp.XXXXXX)"
audit_body_file=""
clone_tmp=""
cleanup() {
  rm -f "${runtime_tmp}" "${audit_body_file:-}"
  if [[ -n "${clone_tmp}" && -d "${clone_tmp}" ]]; then
    rm -rf "${clone_tmp}"
  fi
}
trap cleanup EXIT

install -d -m 0755 /etc/ai-council /opt/ai-workspaces
if [[ -r "${RUNTIME_CONFIG}" ]]; then
  cp "${RUNTIME_CONFIG}" "${runtime_tmp}"
  merge_missing_template_keys "${runtime_tmp}" "${runtime_template}"
else
  cp "${runtime_template}" "${runtime_tmp}"
fi
replace_or_append_key "${runtime_tmp}" AI_COUNCIL_GITHUB_REPO "${CONTROL_REPO}"
replace_or_append_key "${runtime_tmp}" AI_COUNCIL_GITHUB_JOB_LABEL vps-job
chmod 0644 "${runtime_tmp}"
bash "${REPO_DIR}/scripts/validate_runtime_config.sh" "${runtime_tmp}" >/dev/null
install -m 0644 "${runtime_tmp}" "${RUNTIME_CONFIG}"

allowlist_tmp="$(mktemp /etc/ai-council/github-bridge-allowlist.tmp.XXXXXX)"
if [[ -r "${ALLOWLIST_FILE}" ]]; then
  cp "${ALLOWLIST_FILE}" "${allowlist_tmp}"
else
  : > "${allowlist_tmp}"
fi
if ! awk '{line=$0; sub(/#.*/,"",line); gsub(/[[:space:]]/,"",line); if (tolower(line)==tolower(wanted)) found=1} END {exit(found?0:1)}' wanted="${OWNER_LOGIN}" "${allowlist_tmp}"; then
  printf '%s\n' "${OWNER_LOGIN}" >> "${allowlist_tmp}"
fi
install -m 0644 "${allowlist_tmp}" "${ALLOWLIST_FILE}"
rm -f "${allowlist_tmp}"

bash "${REPO_DIR}/scripts/deploy_runtime.sh" >/dev/null

if [[ -e "${PRIVATE_PATH}" ]]; then
  [[ -d "${PRIVATE_PATH}/.git" ]] || fail "private workspace path exists but is not a Git repository"
  check_repo_clean "${PRIVATE_PATH}"
else
  clone_tmp="${PRIVATE_PATH}.clone.$$"
  [[ ! -e "${clone_tmp}" ]] || fail "temporary clone path already exists"
  gh repo clone "${CONTROL_REPO}" "${clone_tmp}" >/dev/null
  [[ -d "${clone_tmp}/.git" ]] || fail "private repository clone did not create a Git workspace"
  mv "${clone_tmp}" "${PRIVATE_PATH}"
  clone_tmp=""
fi

git_in "${PRIVATE_PATH}" fetch origin main >/dev/null
git_in "${PRIVATE_PATH}" switch main >/dev/null
git_in "${PRIVATE_PATH}" pull --ff-only origin main >/dev/null
check_repo_clean "${PRIVATE_PATH}"
check_ancestor "${PRIVATE_PATH}" "${MIN_PRIVATE_COMMIT}"
private_head="$(git_in "${PRIVATE_PATH}" rev-parse HEAD)"

bash /opt/ai-council/scripts/register_workspace.sh "${PRIVATE_REPO_NAME}" "${PRIVATE_PATH}" >/dev/null
bash /opt/ai-council/scripts/setup_ai_cli_runner.sh "${PRIVATE_REPO_NAME}" >/dev/null
bash /opt/ai-council/scripts/workspace_status.sh >/dev/null
bash /opt/ai-council/scripts/run_repo_check.sh "${PRIVATE_REPO_NAME}" >/dev/null

public_head="$(git_in "${REPO_DIR}" rev-parse HEAD)"
AI_COUNCIL_AUDIT_PROFILE=runtime \
AI_COUNCIL_AUDIT_REPO="${PRIVATE_REPO_NAME}" \
AI_COUNCIL_AUDIT_ISSUES="${TARGET_ISSUE}" \
AI_COUNCIL_AUDIT_EXPECTED_RUNTIME_COMMIT="${public_head}" \
AI_COUNCIL_AUDIT_EXPECTED_PRIVATE_COMMIT="${private_head}" \
bash /opt/ai-council/scripts/run_ai_check.sh ai-council >/var/log/ai-council/recovery-direct-audit.log

gh issue edit "${TARGET_ISSUE}" --repo "${CONTROL_REPO}" --add-label vps-job >/dev/null
bash /opt/ai-council/scripts/requeue_github_issue.sh "${TARGET_ISSUE}" >/dev/null

audit_title="[VPS E2E AUDIT] durable runtime and private workspace"
audit_number="$(gh issue list --repo "${CONTROL_REPO}" --state open --limit 100 --json number,title | jq -r --arg title "${audit_title}" '.[] | select(.title == $title) | .number' | head -n 1)"
if [[ -z "${audit_number}" ]]; then
  audit_body_file="$(mktemp)"
  cat > "${audit_body_file}" <<EOF_AUDIT
JOB_TYPE=ai_check
REPO_NAME=ai-council
AUDIT_PROFILE=runtime
AUDIT_REPO=${PRIVATE_REPO_NAME}
AUDIT_ISSUES=${TARGET_ISSUE}
AUDIT_EXPECTED_RUNTIME_COMMIT=${public_head}
AUDIT_EXPECTED_PRIVATE_COMMIT=${private_head}

Purpose: confirm the deployed durable runtime, registered private workspace, per-job evidence, and Issue ${TARGET_ISSUE} state. This is read-only.
EOF_AUDIT
  audit_url="$(gh issue create --repo "${CONTROL_REPO}" --title "${audit_title}" --body-file "${audit_body_file}" --label vps-job)"
  audit_number="${audit_url##*/}"
fi

systemctl start ai-council-github-bridge.service

issue91_state="UNKNOWN"
if [[ -r "/var/lib/ai-council/github-bridge/imported/issue-${TARGET_ISSUE}.imported" ]]; then
  issue91_state="QUEUED"
elif [[ -r "/var/lib/ai-council/github-bridge/blocked/issue-${TARGET_ISSUE}.blocked" ]]; then
  issue91_state="BLOCKED"
fi

audit_state="UNKNOWN"
if [[ -r "/var/lib/ai-council/github-bridge/imported/issue-${audit_number}.imported" ]]; then
  audit_state="QUEUED"
elif [[ -r "/var/lib/ai-council/github-bridge/blocked/issue-${audit_number}.blocked" ]]; then
  audit_state="BLOCKED"
fi

bridge_timer="$(systemctl is-active ai-council-github-bridge.timer 2>/dev/null || true)/$(systemctl is-enabled ai-council-github-bridge.timer 2>/dev/null || true)"
runner_timer="$(systemctl is-active ai-council-job-runner.timer 2>/dev/null || true)/$(systemctl is-enabled ai-council-job-runner.timer 2>/dev/null || true)"

cat <<EOF_RESULT
RECOVERY_PRIVATE_WORKSPACE_STATUS: FOLLOWUP_QUEUED
RUNTIME_CONFIG_STATUS: OK
CONFIGURED_CONTROL_REPO: ${CONTROL_REPO}
RUNTIME_DEPLOY_STATUS: OK
PRIVATE_WORKSPACE_STATUS: OK
PRIVATE_HEAD: ${private_head}
WORKSPACE_REGISTRATION: OK
DIRECT_AUDIT_LOG: /var/log/ai-council/recovery-direct-audit.log
ISSUE_${TARGET_ISSUE}_REQUEUE: OK
ISSUE_${TARGET_ISSUE}_IMPORT_STATE: ${issue91_state}
E2E_AUDIT_ISSUE: ${audit_number}
E2E_AUDIT_IMPORT_STATE: ${audit_state}
BRIDGE_TIMER: ${bridge_timer}
RUNNER_TIMER: ${runner_timer}
NEXT_SAFE_ACTION: runner timer processes queued follow-up jobs after this recovery job exits
EOF_RESULT
