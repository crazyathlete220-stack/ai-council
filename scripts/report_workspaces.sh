#!/usr/bin/env bash
set -euo pipefail

REGISTRY_DIR="/etc/ai-council/workspaces.d"
LOG_ROOT="/var/log/ai-council/workspaces"
SUMMARY_FILE="${LOG_ROOT}/latest-summary.md"
errors=0

mark_error() {
  echo "[ERROR] $1"
  errors=$((errors + 1))
}

if ! mkdir -p "${LOG_ROOT}"; then
  echo "ERROR: could not create summary log directory: ${LOG_ROOT}" >&2
  echo "Try rerunning with sudo." >&2
  exit 1
fi

if ! : >"${SUMMARY_FILE}"; then
  echo "ERROR: could not write summary file: ${SUMMARY_FILE}" >&2
  echo "Try rerunning with sudo." >&2
  exit 1
fi

exec > >(tee "${SUMMARY_FILE}") 2>&1

echo "# AI Council Workspace Summary"
echo
echo "- Generated At: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "- Hostname: $(hostname)"
echo

if [[ ! -d "${REGISTRY_DIR}" ]]; then
  mark_error "registry directory missing: ${REGISTRY_DIR}"
else
  shopt -s nullglob
  config_files=("${REGISTRY_DIR}"/*.env)

  if [[ "${#config_files[@]}" -eq 0 ]]; then
    mark_error "no workspace configs found in ${REGISTRY_DIR}"
  fi

  for config_file in "${config_files[@]}"; do
    REPO_NAME=""
    REPO_PATH=""
    LOG_DIR=""

    if [[ ! -r "${config_file}" ]]; then
      mark_error "workspace config is not readable: ${config_file}"
      continue
    fi

    # shellcheck source=/dev/null
    . "${config_file}"

    latest_report="${LOG_DIR}/latest-report.md"

    echo "## ${REPO_NAME:-unknown}"
    echo "- config: ${config_file}"
    echo "- repo path: ${REPO_PATH:-unset}"
    echo "- latest-report.md: ${latest_report}"

    if [[ -f "${latest_report}" ]]; then
      echo "- latest-report exists: yes"
      echo "- latest-report updated: $(stat -c "%y" "${latest_report}" 2>/dev/null || echo unknown)"
    else
      echo "- latest-report exists: no"
      mark_error "latest report missing for ${REPO_NAME:-unknown}"
    fi

    echo
  done
fi

if [[ "${errors}" -eq 0 ]]; then
  echo "WORKSPACE_SUMMARY_STATUS: OK"
else
  echo "WORKSPACE_SUMMARY_STATUS: ERROR"
  exit 1
fi
