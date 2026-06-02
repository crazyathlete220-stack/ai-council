#!/usr/bin/env bash
set -euo pipefail

REGISTRY_DIR="/etc/ai-council/workspaces.d"
errors=0

mark_error() {
  echo "[ERROR] $1"
  errors=$((errors + 1))
}

mark_info() {
  echo "[INFO] $1"
}

print_presence() {
  local label="$1"
  local path="$2"

  if [[ -e "${path}" ]]; then
    echo "- ${label}: yes"
  else
    echo "- ${label}: no"
  fi
}

echo "AI Council workspace registry status"
echo

if [[ ! -d "${REGISTRY_DIR}" ]]; then
  mark_error "registry directory missing: ${REGISTRY_DIR}"
  echo
  echo "WORKSPACE_REGISTRY_STATUS: ERROR"
  exit 1
fi

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

  echo "## ${REPO_NAME:-unknown}"
  echo "- config: ${config_file}"
  echo "- repo path: ${REPO_PATH:-unset}"

  if [[ -z "${REPO_NAME}" || -z "${REPO_PATH}" || -z "${LOG_DIR}" ]]; then
    mark_error "workspace config is incomplete: ${config_file}"
    echo
    continue
  fi

  if [[ -d "${REPO_PATH}" ]]; then
    echo "- repo path exists: yes"
  else
    echo "- repo path exists: no"
    mark_error "repo path missing for ${REPO_NAME}: ${REPO_PATH}"
  fi

  print_presence ".git" "${REPO_PATH}/.git"
  print_presence "package.json" "${REPO_PATH}/package.json"
  print_presence "pyproject.toml" "${REPO_PATH}/pyproject.toml"
  print_presence "requirements.txt" "${REPO_PATH}/requirements.txt"
  print_presence "latest-report.md" "${LOG_DIR}/latest-report.md"
  echo
done

if [[ "${errors}" -eq 0 ]]; then
  mark_info "workspace registry readable"
  echo "WORKSPACE_REGISTRY_STATUS: OK"
else
  echo "WORKSPACE_REGISTRY_STATUS: ERROR"
  exit 1
fi
