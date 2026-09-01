#!/usr/bin/env bash
set -u

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
WORKSPACE_ROOT="${AI_COUNCIL_WORKSPACE_ROOT:-/opt/ai-workspaces}"
REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
ALLOWLIST_FILE="${AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE:-/etc/ai-council/github-bridge-allowlist}"
OPERATOR_USER="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
BRIDGE_SERVICE="${AI_COUNCIL_GITHUB_BRIDGE_SERVICE_NAME:-ai-council-github-bridge.service}"
BRIDGE_TIMER="${AI_COUNCIL_GITHUB_BRIDGE_TIMER_NAME:-ai-council-github-bridge.timer}"
RUNNER_SERVICE="${AI_COUNCIL_JOB_RUNNER_SERVICE_NAME:-ai-council-job-runner.service}"
RUNNER_TIMER="${AI_COUNCIL_JOB_RUNNER_TIMER_NAME:-ai-council-job-runner.timer}"
workspace_name="${1:-}"
workspace_repo="${2:-}"
errors=0
warnings=0

usage() {
  cat >&2 <<'USAGE'
Usage:
  sudo bash scripts/recover_github_bridge.sh [WORKSPACE_NAME] [OWNER/REPOSITORY]

Examples:
  sudo bash scripts/recover_github_bridge.sh
  sudo bash scripts/recover_github_bridge.sh ai-council-private crazyathlete220-stack/ai-council-private
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

if [[ "${workspace_name}" == "--help" || "${workspace_name}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root with sudo." >&2
  exit 1
fi

if [[ -n "${workspace_name}" && ! "${workspace_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Unsafe workspace name: ${workspace_name}" >&2
  exit 1
fi

if [[ -n "${workspace_repo}" && ! "${workspace_repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Repository must use OWNER/REPOSITORY format." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

copy_file() {
  local source_path="$1"
  local destination_path="$2"
  local mode="$3"
  local source_real=""
  local destination_real=""

  source_real="$(realpath -m "${source_path}")"
  destination_real="$(realpath -m "${destination_path}")"

  if [[ "${source_real}" == "${destination_real}" ]]; then
    chmod "${mode}" "${destination_path}"
  else
    install -m "${mode}" "${source_path}" "${destination_path}"
  fi
}

echo "# AI Council GitHub Bridge Recovery"
echo
echo "- Generated At: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "- Source Repo: ${REPO_DIR}"
echo "- Runtime App: ${APP_DIR}"
echo "- Optional Workspace: ${workspace_name:-not requested}"
echo

echo "## Install current runtime files"
install -d -m 0755 "${APP_DIR}" "${APP_DIR}/scripts" "${APP_DIR}/systemd"

for source_path in "${REPO_DIR}"/scripts/*.sh; do
  [[ -f "${source_path}" ]] || continue
  copy_file "${source_path}" "${APP_DIR}/scripts/$(basename "${source_path}")" 0755
 done

for unit_name in "${BRIDGE_SERVICE}" "${BRIDGE_TIMER}" "${RUNNER_SERVICE}" "${RUNNER_TIMER}"; do
  source_path="${REPO_DIR}/systemd/${unit_name}"
  if [[ ! -f "${source_path}" ]]; then
    mark_error "missing unit source: ${source_path}"
    continue
  fi
  copy_file "${source_path}" "${APP_DIR}/systemd/${unit_name}" 0644
  copy_file "${source_path}" "/etc/systemd/system/${unit_name}" 0644
 done

if ! bash -n "${APP_DIR}"/scripts/*.sh; then
  mark_error "runtime shell syntax validation failed"
fi

if ! command -v gh >/dev/null 2>&1; then
  mark_error "gh command is missing"
elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
  mark_error "gh authentication is not valid for root"
else
  echo "- gh authentication: OK"
fi

if [[ ! -r "${ALLOWLIST_FILE}" ]]; then
  mark_error "GitHub bridge allowlist is not readable: ${ALLOWLIST_FILE}"
elif ! grep -Eq '^[[:space:]]*[A-Za-z0-9-]+[[:space:]]*(#.*)?$' "${ALLOWLIST_FILE}"; then
  mark_error "GitHub bridge allowlist has no valid username"
else
  echo "- allowlist: readable"
fi

install -d -m 0755 \
  /var/lib/ai-council/github-bridge/imported \
  /var/lib/ai-council/github-bridge/rejected \
  /var/lib/ai-council/github-bridge/posted \
  /var/lib/ai-council/jobs/queue \
  /var/lib/ai-council/jobs/active \
  /var/lib/ai-council/jobs/done \
  /var/lib/ai-council/jobs/failed \
  /var/log/ai-council/github-bridge \
  /var/log/ai-council/jobs

if ! id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
  mark_error "operator user is missing: ${OPERATOR_USER}"
else
  chown -R "${OPERATOR_USER}:${OPERATOR_USER}" /var/lib/ai-council/jobs /var/log/ai-council/jobs
fi

if [[ -n "${workspace_name}" ]]; then
  workspace_path="${WORKSPACE_ROOT}/${workspace_name}"
  config_file="${REGISTRY_DIR}/${workspace_name}.env"

  install -d -m 0755 "${WORKSPACE_ROOT}" "${REGISTRY_DIR}"

  if [[ ! -d "${workspace_path}" ]]; then
    if [[ -z "${workspace_repo}" ]]; then
      mark_error "workspace is missing and no OWNER/REPOSITORY source was supplied: ${workspace_path}"
    elif ! command -v gh >/dev/null 2>&1 || ! gh auth status --hostname github.com >/dev/null 2>&1; then
      mark_error "workspace is missing and authenticated gh is unavailable"
    elif ! gh repo view "${workspace_repo}" >/dev/null 2>&1; then
      mark_error "repository is not accessible through the existing gh authentication: ${workspace_repo}"
    else
      echo "- cloning workspace: ${workspace_repo} -> ${workspace_path}"
      if ! gh repo clone "${workspace_repo}" "${workspace_path}"; then
        mark_error "workspace clone failed: ${workspace_repo}"
      fi
    fi
  fi

  if [[ -d "${workspace_path}" ]]; then
    if [[ ! -d "${workspace_path}/.git" ]]; then
      mark_error "workspace path exists but is not a Git repository: ${workspace_path}"
    else
      if ! bash "${APP_DIR}/scripts/register_workspace.sh" "${workspace_name}" "${workspace_path}"; then
        mark_error "workspace registration failed: ${workspace_name}"
      fi
      if id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
        if ! bash "${APP_DIR}/scripts/setup_ai_cli_runner.sh" "${workspace_name}"; then
          mark_error "AI CLI workspace permission setup failed: ${workspace_name}"
        fi
      fi
      if [[ ! -r "${config_file}" ]]; then
        mark_error "workspace config is still unreadable: ${config_file}"
      fi
    fi
  fi
fi

echo
echo "## Enable and start timers"
systemctl daemon-reload
systemctl reset-failed "${BRIDGE_SERVICE}" "${RUNNER_SERVICE}" >/dev/null 2>&1 || true

if ! systemctl enable --now "${RUNNER_TIMER}"; then
  mark_error "could not enable/start ${RUNNER_TIMER}"
fi
if ! systemctl enable --now "${BRIDGE_TIMER}"; then
  mark_error "could not enable/start ${BRIDGE_TIMER}"
fi

bridge_enabled="$(systemctl is-enabled "${BRIDGE_TIMER}" 2>/dev/null || true)"
bridge_active="$(systemctl is-active "${BRIDGE_TIMER}" 2>/dev/null || true)"
runner_enabled="$(systemctl is-enabled "${RUNNER_TIMER}" 2>/dev/null || true)"
runner_active="$(systemctl is-active "${RUNNER_TIMER}" 2>/dev/null || true)"

echo "- ${BRIDGE_TIMER}: enabled=${bridge_enabled:-unknown}, active=${bridge_active:-unknown}"
echo "- ${RUNNER_TIMER}: enabled=${runner_enabled:-unknown}, active=${runner_active:-unknown}"

if [[ "${bridge_enabled}" != "enabled" || "${bridge_active}" != "active" ]]; then
  mark_error "GitHub bridge timer is not enabled and active"
fi
if [[ "${runner_enabled}" != "enabled" || "${runner_active}" != "active" ]]; then
  mark_error "job runner timer is not enabled and active"
fi

echo
echo "## Run one bridge cycle"
set +e
systemctl start "${BRIDGE_SERVICE}"
bridge_run_rc=$?
set -e

if [[ "${bridge_run_rc}" -ne 0 ]]; then
  mark_warning "bridge service returned non-zero after the recovery run; inspect: journalctl -u ${BRIDGE_SERVICE} -n 100 --no-pager"
fi

bridge_service_state="$(systemctl is-failed "${BRIDGE_SERVICE}" 2>/dev/null || true)"
runner_service_state="$(systemctl is-failed "${RUNNER_SERVICE}" 2>/dev/null || true)"

echo "- bridge service failed state: ${bridge_service_state:-unknown}"
echo "- runner service failed state: ${runner_service_state:-unknown}"
echo "- latest bridge cycle: /var/log/ai-council/github-bridge/latest-cycle.log"
echo "- latest job report: /var/log/ai-council/jobs/latest-job-report.md"
echo "- rejected issues: /var/log/ai-council/github-bridge/rejected-issues.log"
echo

echo "## Result"
echo "- Errors: ${errors}"
echo "- Warnings: ${warnings}"

if [[ "${errors}" -eq 0 ]]; then
  echo "BRIDGE_RECOVERY_STATUS: OK"
  exit 0
fi

echo "BRIDGE_RECOVERY_STATUS: ERROR"
exit 1
