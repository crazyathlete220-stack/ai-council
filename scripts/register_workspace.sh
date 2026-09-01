#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${AI_COUNCIL_WORKSPACE_ROOT:-/opt/ai-workspaces}"
LOG_ROOT="${AI_COUNCIL_WORKSPACE_LOG_ROOT:-/var/log/ai-council/workspaces}"
REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"

usage() {
  echo "Usage: sudo bash scripts/register_workspace.sh <REPO_NAME> ${WORKSPACE_ROOT}/<REPO_NAME>" >&2
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root." >&2
  usage
  exit 1
fi

if [[ "$#" -ne 2 ]]; then
  usage
  exit 1
fi

repo_name="$1"
repo_path="$2"

if [[ ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: repo name may contain only letters, numbers, dot, underscore, and dash" >&2
  exit 1
fi

install -d -m 0755 "${WORKSPACE_ROOT}" "${REGISTRY_DIR}" "${LOG_ROOT}"

if [[ ! -d "${repo_path}/.git" ]]; then
  echo "ERROR: repo path is not a Git checkout: ${repo_path}" >&2
  exit 1
fi

workspace_root_real="$(realpath -e "${WORKSPACE_ROOT}")"
repo_path_real="$(realpath -e "${repo_path}")"

if [[ "${repo_path_real}" != "${workspace_root_real}/"* ]]; then
  echo "ERROR: repo path must be located below ${workspace_root_real}: ${repo_path_real}" >&2
  exit 1
fi

config_file="${REGISTRY_DIR}/${repo_name}.env"
log_dir="${LOG_ROOT}/${repo_name}"
config_tmp="${config_file}.tmp.$$"

install -d -m 0755 "${log_dir}"

if [[ -f "${config_file}" ]]; then
  backup_file="${config_file}.bak.$(date -u +'%Y%m%dT%H%M%SZ')"
  cp -a "${config_file}" "${backup_file}"
  chmod 0600 "${backup_file}"
  echo "Existing workspace config backed up: ${backup_file}"
fi

{
  printf "REPO_NAME=%q\n" "${repo_name}"
  printf "REPO_PATH=%q\n" "${repo_path_real}"
  printf "LOG_DIR=%q\n" "${log_dir}"
} >"${config_tmp}"

chown root:root "${config_tmp}"
chmod 0644 "${config_tmp}"
mv -f "${config_tmp}" "${config_file}"

cat <<EOF
Registered workspace:
  REPO_NAME=${repo_name}
  REPO_PATH=${repo_path_real}
  LOG_DIR=${log_dir}

Next confirmation commands:
  bash scripts/workspace_status.sh
  sudo bash scripts/run_repo_check.sh ${repo_name}
EOF
