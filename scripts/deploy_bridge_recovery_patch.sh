#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
WORKSPACE_ROOT="${AI_COUNCIL_WORKSPACE_ROOT:-/opt/ai-workspaces}"
REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
OPERATOR_USER="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
BRIDGE_REPOSITORY="${1:-${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council-private}}"
WORKSPACE_NAME="${2:-ai-council-private}"
WORKSPACE_REPOSITORY="${3:-crazyathlete220-stack/ai-council-private}"
BRIDGE_SERVICE="ai-council-github-bridge.service"
BRIDGE_TIMER="ai-council-github-bridge.timer"
RUNNER_SERVICE="ai-council-job-runner.service"
RUNNER_TIMER="ai-council-job-runner.timer"
DEPLOY_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
BACKUP_DIR="/var/backups/ai-council-recovery/${DEPLOY_STAMP}"
REPORT_DIR="/var/log/ai-council/recovery"
REPORT_FILE="${REPORT_DIR}/bridge-recovery-${DEPLOY_STAMP}.log"
errors=0
warnings=0
deployment_complete=0
bridge_timer_was_enabled=0
runner_timer_was_enabled=0
bridge_timer_was_active=0
runner_timer_was_active=0

usage() {
  cat >&2 <<'USAGE'
Usage:
  sudo bash scripts/deploy_bridge_recovery_patch.sh \
    [BRIDGE_OWNER/REPO] [WORKSPACE_NAME] [WORKSPACE_OWNER/REPO]
USAGE
}

mark_error() {
  echo "[ERROR] $1"
  errors=$((errors + 1))
}

mark_warning() {
  echo "[WARN] $1"
  warnings=$((warnings + 1))
}

fail_now() {
  mark_error "$1"
  echo "BRIDGE_PATCH_DEPLOY_STATUS: ERROR"
  exit 1
}

is_enabled() {
  systemctl is-enabled "$1" >/dev/null 2>&1
}

is_active() {
  systemctl is-active "$1" >/dev/null 2>&1
}

restore_previous_timers() {
  local rc="$?"
  trap - EXIT

  if [[ "${deployment_complete}" -eq 0 ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true

    if [[ "${runner_timer_was_enabled}" -eq 1 || "${runner_timer_was_active}" -eq 1 ]]; then
      systemctl enable --now "${RUNNER_TIMER}" >/dev/null 2>&1 || true
    else
      systemctl disable --now "${RUNNER_TIMER}" >/dev/null 2>&1 || true
    fi

    if [[ "${bridge_timer_was_enabled}" -eq 1 || "${bridge_timer_was_active}" -eq 1 ]]; then
      systemctl enable --now "${BRIDGE_TIMER}" >/dev/null 2>&1 || true
    else
      systemctl disable --now "${BRIDGE_TIMER}" >/dev/null 2>&1 || true
    fi
  fi

  exit "${rc}"
}

wait_for_service_idle() {
  local service_name="$1"
  local attempts=0
  local state=""

  while [[ "${attempts}" -lt 60 ]]; do
    state="$(systemctl is-active "${service_name}" 2>/dev/null || true)"
    case "${state}" in
      active | activating | deactivating)
        sleep 2
        attempts=$((attempts + 1))
        ;;
      *)
        return 0
        ;;
    esac
  done

  return 1
}

backup_path() {
  local source_path="$1"

  if [[ -e "${source_path}" || -L "${source_path}" ]]; then
    cp -a --parents -- "${source_path}" "${BACKUP_DIR}"
  fi
}

sha_or_missing() {
  local path="$1"

  if [[ -f "${path}" ]]; then
    sha256sum "${path}" | awk '{print $1}'
  else
    echo "MISSING"
  fi
}

ensure_command_package() {
  local command_name="$1"
  local package_name="$2"

  if command -v "${command_name}" >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    mark_error "${command_name} is missing and apt-get is unavailable"
    return 1
  fi

  echo "Installing required package: ${package_name}"
  if ! apt-get update >/dev/null || ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${package_name}" >/dev/null; then
    mark_error "could not install ${package_name}"
    return 1
  fi

  command -v "${command_name}" >/dev/null 2>&1
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root with sudo." >&2
  exit 1
fi

for repo_value in "${BRIDGE_REPOSITORY}" "${WORKSPACE_REPOSITORY}"; do
  if [[ ! "${repo_value}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: Repository values must use OWNER/REPOSITORY format." >&2
    usage
    exit 1
  fi
done

if [[ ! "${WORKSPACE_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Unsafe workspace name: ${WORKSPACE_NAME}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PATCH_SCRIPTS=(
  import_github_jobs.sh
  post_job_result_to_github.sh
  run_job_cycle.sh
  run_github_bridge_once.sh
  requeue_github_issue.sh
  job_status.sh
  run_repo_check.sh
  register_workspace.sh
  setup_ai_cli_runner.sh
  setup_operator_user.sh
)

PROTECTED_SCRIPTS=(
  run_ai_exec.sh
  run_ai_check.sh
  run_ai_plan.sh
  run_job_once.sh
  create_job.sh
  report_job_result.sh
)

SYSTEMD_UNITS=(
  "${BRIDGE_SERVICE}"
  "${BRIDGE_TIMER}"
  "${RUNNER_SERVICE}"
  "${RUNNER_TIMER}"
)

for script_name in "${PATCH_SCRIPTS[@]}"; do
  [[ -f "${SOURCE_ROOT}/scripts/${script_name}" ]] || {
    echo "ERROR: missing patch source: scripts/${script_name}" >&2
    exit 1
  }
done
for unit_name in "${SYSTEMD_UNITS[@]}"; do
  [[ -f "${SOURCE_ROOT}/systemd/${unit_name}" ]] || {
    echo "ERROR: missing systemd source: systemd/${unit_name}" >&2
    exit 1
  }
done

bash -n "${SOURCE_ROOT}/scripts/"*.sh || {
  echo "ERROR: source shell syntax validation failed" >&2
  exit 1
}

install -d -m 0755 "${REPORT_DIR}" "${BACKUP_DIR}"
exec > >(tee "${REPORT_FILE}") 2>&1
trap restore_previous_timers EXIT

echo "# AI Council bridge recovery patch deployment"
echo
echo "- Generated At: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "- Source Root: ${SOURCE_ROOT}"
echo "- Runtime Root: ${APP_DIR}"
echo "- Bridge Repository: ${BRIDGE_REPOSITORY}"
echo "- Workspace: ${WORKSPACE_NAME}"
echo "- Workspace Repository: ${WORKSPACE_REPOSITORY}"
echo "- Backup: ${BACKUP_DIR}"
echo "- Report: ${REPORT_FILE}"
echo

echo "## Host prerequisites"
for command_name in bash git jq realpath systemctl sudo sha256sum tar; do
  if command -v "${command_name}" >/dev/null 2>&1; then
    echo "- ${command_name}: present"
  else
    mark_error "required command is missing: ${command_name}"
  fi
done
ensure_command_package flock util-linux || true
ensure_command_package bwrap bubblewrap || true

if ! command -v gh >/dev/null 2>&1; then
  mark_error "GitHub CLI is missing"
elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
  mark_error "root GitHub CLI authentication is invalid"
else
  echo "- root gh authentication: OK"
fi

if ! command -v codex >/dev/null 2>&1; then
  mark_error "Codex CLI is missing"
else
  echo "- Codex CLI: present"
fi

if [[ "${errors}" -gt 0 ]]; then
  fail_now "host prerequisites are incomplete"
fi

for path in /opt /var/lib /var/log; do
  available_kb="$(df -Pk "${path}" | awk 'NR == 2 {print $4}')"
  echo "- free space ${path}: ${available_kb:-unknown} KB"
  if [[ "${available_kb}" =~ ^[0-9]+$ && "${available_kb}" -lt 131072 ]]; then
    fail_now "less than 128 MB free under ${path}"
  elif [[ "${available_kb}" =~ ^[0-9]+$ && "${available_kb}" -lt 524288 ]]; then
    mark_warning "less than 512 MB free under ${path}"
  fi
done

if is_enabled "${BRIDGE_TIMER}"; then bridge_timer_was_enabled=1; fi
if is_enabled "${RUNNER_TIMER}"; then runner_timer_was_enabled=1; fi
if is_active "${BRIDGE_TIMER}"; then bridge_timer_was_active=1; fi
if is_active "${RUNNER_TIMER}"; then runner_timer_was_active=1; fi

echo
echo "## Quiesce timers without killing active jobs"
systemctl stop "${BRIDGE_TIMER}" "${RUNNER_TIMER}" >/dev/null 2>&1 || true
if ! wait_for_service_idle "${BRIDGE_SERVICE}"; then
  fail_now "bridge service did not become idle within 120 seconds"
fi
if ! wait_for_service_idle "${RUNNER_SERVICE}"; then
  fail_now "job runner service did not become idle within 120 seconds"
fi

echo "- timers stopped"
echo "- oneshot services idle"

echo
echo "## Back up runtime and preserve production-specific executors"
install -d -m 0755 "${APP_DIR}/scripts" "${APP_DIR}/systemd" /etc/ai-council

for script_name in "${PATCH_SCRIPTS[@]}" "${PROTECTED_SCRIPTS[@]}"; do
  backup_path "${APP_DIR}/scripts/${script_name}"
done
for unit_name in "${SYSTEMD_UNITS[@]}"; do
  backup_path "/etc/systemd/system/${unit_name}"
  backup_path "${APP_DIR}/systemd/${unit_name}"
done
backup_path /etc/ai-council/github-bridge.env
backup_path /etc/ai-council/github-bridge-allowlist

protected_hashes_before="${BACKUP_DIR}/protected-hashes-before.txt"
protected_hashes_after="${BACKUP_DIR}/protected-hashes-after.txt"
: >"${protected_hashes_before}"
for script_name in "${PROTECTED_SCRIPTS[@]}"; do
  printf '%s  %s\n' "$(sha_or_missing "${APP_DIR}/scripts/${script_name}")" "${script_name}" >>"${protected_hashes_before}"
done
cat "${protected_hashes_before}"

echo
echo "## Install bridge-only patch"
for script_name in "${PATCH_SCRIPTS[@]}"; do
  install -m 0755 "${SOURCE_ROOT}/scripts/${script_name}" "${APP_DIR}/scripts/${script_name}"
  echo "- installed script: ${script_name}"
done
for unit_name in "${SYSTEMD_UNITS[@]}"; do
  install -m 0644 "${SOURCE_ROOT}/systemd/${unit_name}" "${APP_DIR}/systemd/${unit_name}"
  install -m 0644 "${SOURCE_ROOT}/systemd/${unit_name}" "/etc/systemd/system/${unit_name}"
  echo "- installed unit: ${unit_name}"
done
if [[ -f "${SOURCE_ROOT}/docs/vps-bridge-recovery.md" ]]; then
  install -d -m 0755 "${APP_DIR}/docs"
  install -m 0644 "${SOURCE_ROOT}/docs/vps-bridge-recovery.md" "${APP_DIR}/docs/vps-bridge-recovery.md"
fi

bridge_env_tmp="/etc/ai-council/github-bridge.env.tmp.$$"
{
  printf 'AI_COUNCIL_GITHUB_REPO=%s\n' "${BRIDGE_REPOSITORY}"
  printf 'AI_COUNCIL_GITHUB_JOB_LABEL=vps-job\n'
  printf 'AI_COUNCIL_GITHUB_SCAN_LIMIT=1000\n'
  printf 'AI_COUNCIL_GITHUB_IMPORT_LIMIT=20\n'
} >"${bridge_env_tmp}"
chown root:root "${bridge_env_tmp}"
chmod 0644 "${bridge_env_tmp}"
mv -f "${bridge_env_tmp}" /etc/ai-council/github-bridge.env

echo "- explicit bridge repository environment: configured"

if ! bash -n "${APP_DIR}/scripts/"*.sh; then
  fail_now "runtime shell syntax validation failed after patch installation"
fi

echo
echo "## Operator, state, and allowlist"
if ! bash "${APP_DIR}/scripts/setup_operator_user.sh"; then
  fail_now "operator user/state setup failed"
fi

install -d -m 0755 \
  /var/lib/ai-council/github-bridge/imported \
  /var/lib/ai-council/github-bridge/rejected \
  /var/lib/ai-council/github-bridge/blocked \
  /var/lib/ai-council/github-bridge/posted \
  /var/lib/ai-council/github-bridge/state-events \
  /var/lib/ai-council/github-bridge/state-events-posted \
  /var/lib/ai-council/github-bridge/requeue-archive \
  /var/log/ai-council/github-bridge

if [[ ! -r /etc/ai-council/github-bridge-allowlist ]]; then
  fail_now "GitHub bridge allowlist is missing or unreadable"
fi
if ! grep -Eq '^[[:space:]]*[A-Za-z0-9-]+[[:space:]]*(#.*)?$' /etc/ai-council/github-bridge-allowlist; then
  fail_now "GitHub bridge allowlist has no valid username"
fi

echo "- operator user: ${OPERATOR_USER}"
echo "- allowlist: readable and non-empty"

echo
echo "## Private workspace placement and registration"
workspace_path="${WORKSPACE_ROOT}/${WORKSPACE_NAME}"
install -d -m 0755 "${WORKSPACE_ROOT}" "${REGISTRY_DIR}"

if [[ -d "${workspace_path}" && ! -d "${workspace_path}/.git" ]]; then
  if find "${workspace_path}" -mindepth 1 -print -quit | grep -q .; then
    fail_now "workspace path exists but is not an empty Git checkout: ${workspace_path}"
  fi
  rmdir "${workspace_path}"
fi

if [[ ! -d "${workspace_path}/.git" ]]; then
  if ! gh repo view "${WORKSPACE_REPOSITORY}" >/dev/null 2>&1; then
    fail_now "workspace repository is not accessible through existing root gh authentication"
  fi
  if ! gh repo clone "${WORKSPACE_REPOSITORY}" "${workspace_path}"; then
    fail_now "private workspace clone failed"
  fi
  echo "- workspace cloned: ${workspace_path}"
else
  echo "- existing Git workspace found: ${workspace_path}"
fi

origin_url="$(git -C "${workspace_path}" remote get-url origin 2>/dev/null || true)"
case "${origin_url}" in
  "https://github.com/${WORKSPACE_REPOSITORY}" | \
  "https://github.com/${WORKSPACE_REPOSITORY}.git" | \
  "git@github.com:${WORKSPACE_REPOSITORY}" | \
  "git@github.com:${WORKSPACE_REPOSITORY}.git")
    ;;
  *)
    fail_now "workspace origin does not match the requested repository"
    ;;
esac

if ! bash "${APP_DIR}/scripts/register_workspace.sh" "${WORKSPACE_NAME}" "${workspace_path}"; then
  fail_now "workspace registration failed"
fi
if ! bash "${APP_DIR}/scripts/setup_ai_cli_runner.sh" "${WORKSPACE_NAME}"; then
  fail_now "workspace ownership/operator setup failed"
fi

dirty_state="$(sudo -H -u "${OPERATOR_USER}" git -C "${workspace_path}" status --porcelain 2>/dev/null || true)"
if [[ -n "${dirty_state}" ]]; then
  stash_message="pre-bridge-recovery-${DEPLOY_STAMP}"
  if ! sudo -H -u "${OPERATOR_USER}" git -C "${workspace_path}" stash push --include-untracked -m "${stash_message}"; then
    fail_now "workspace had changes and could not be safely stashed"
  fi
  mark_warning "existing private workspace changes were preserved in git stash: ${stash_message}"
fi

if [[ -n "$(sudo -H -u "${OPERATOR_USER}" git -C "${workspace_path}" status --porcelain 2>/dev/null || true)" ]]; then
  fail_now "private workspace is still dirty after preservation attempt"
fi

if ! sudo -H -u "${OPERATOR_USER}" codex login status >/dev/null 2>&1; then
  fail_now "Codex CLI authentication is unavailable for ${OPERATOR_USER}"
fi

if ! bash "${APP_DIR}/scripts/ai_cli_status.sh" "${WORKSPACE_NAME}"; then
  fail_now "AI CLI workspace readiness check failed"
fi

echo "- private workspace: registered, clean, writable, Codex-authenticated"

echo
echo "## Verify protected runtime remained unchanged"
: >"${protected_hashes_after}"
for script_name in "${PROTECTED_SCRIPTS[@]}"; do
  printf '%s  %s\n' "$(sha_or_missing "${APP_DIR}/scripts/${script_name}")" "${script_name}" >>"${protected_hashes_after}"
done
cat "${protected_hashes_after}"
if ! cmp -s "${protected_hashes_before}" "${protected_hashes_after}"; then
  fail_now "one or more protected production executor scripts changed"
fi

echo "- protected executor hashes: unchanged"

echo
echo "## Reload systemd and start recovery cycle"
systemctl daemon-reload
systemctl reset-failed "${BRIDGE_SERVICE}" "${RUNNER_SERVICE}" >/dev/null 2>&1 || true

if ! systemctl enable --now "${RUNNER_TIMER}"; then
  fail_now "could not enable/start ${RUNNER_TIMER}"
fi
if ! systemctl enable --now "${BRIDGE_TIMER}"; then
  fail_now "could not enable/start ${BRIDGE_TIMER}"
fi

if ! systemctl start "${BRIDGE_SERVICE}"; then
  mark_error "first bridge cycle returned non-zero"
fi

bridge_timer_enabled="$(systemctl is-enabled "${BRIDGE_TIMER}" 2>/dev/null || true)"
bridge_timer_active="$(systemctl is-active "${BRIDGE_TIMER}" 2>/dev/null || true)"
runner_timer_enabled="$(systemctl is-enabled "${RUNNER_TIMER}" 2>/dev/null || true)"
runner_timer_active="$(systemctl is-active "${RUNNER_TIMER}" 2>/dev/null || true)"

echo "- ${BRIDGE_TIMER}: enabled=${bridge_timer_enabled:-unknown}, active=${bridge_timer_active:-unknown}"
echo "- ${RUNNER_TIMER}: enabled=${runner_timer_enabled:-unknown}, active=${runner_timer_active:-unknown}"

if [[ "${bridge_timer_enabled}" != "enabled" || "${bridge_timer_active}" != "active" ]]; then
  mark_error "bridge timer is not enabled and active"
fi
if [[ "${runner_timer_enabled}" != "enabled" || "${runner_timer_active}" != "active" ]]; then
  mark_error "runner timer is not enabled and active"
fi

latest_cycle="/var/log/ai-council/github-bridge/latest-cycle.log"
if [[ ! -r "${latest_cycle}" ]]; then
  mark_error "latest bridge cycle log is missing"
else
  grep -E '^(IMPORT_GITHUB_JOBS_STATUS|STATE_COMMENT_STATUS|RUN_JOB_CYCLE_EXIT|GITHUB_BRIDGE_CYCLE_STATUS):' "${latest_cycle}" || true
  if ! grep -Fq 'GITHUB_BRIDGE_CYCLE_STATUS: OK' "${latest_cycle}"; then
    mark_error "latest bridge cycle did not complete with OK"
  fi
fi

pending_result_count="$(find /var/log/ai-council/jobs/pending-posts -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')"
pending_state_count="$(find /var/lib/ai-council/github-bridge/state-events -maxdepth 1 -type f -name '*.event' 2>/dev/null | wc -l | tr -d '[:space:]')"
echo "- pending result comments: ${pending_result_count}"
echo "- pending state comments: ${pending_state_count}"
if [[ "${pending_result_count}" -gt 0 || "${pending_state_count}" -gt 0 ]]; then
  mark_error "one or more GitHub comments remain undelivered"
fi

echo
echo "## Evidence"
echo "- backup: ${BACKUP_DIR}"
echo "- deployment report: ${REPORT_FILE}"
echo "- latest bridge cycle: ${latest_cycle}"
echo "- latest job report: /var/log/ai-council/jobs/latest-job-report.md"
echo "- job-specific reports: /var/log/ai-council/jobs/reports/"
echo "- rejected issues: /var/log/ai-council/github-bridge/rejected-issues.log"
echo "- blocked issues: /var/log/ai-council/github-bridge/blocked-issues.log"
echo

echo "## Result"
echo "- Errors: ${errors}"
echo "- Warnings: ${warnings}"

if [[ "${errors}" -gt 0 ]]; then
  echo "BRIDGE_PATCH_DEPLOY_STATUS: ERROR"
  exit 1
fi

deployment_complete=1
echo "BRIDGE_PATCH_DEPLOY_STATUS: OK"
