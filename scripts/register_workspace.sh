#!/usr/bin/env bash
set -euo pipefail

LOG_ROOT="/var/log/ai-council/workspaces"
REGISTRY_DIR="/etc/ai-council/workspaces.d"

usage() {
  echo "Usage: sudo bash scripts/register_workspace.sh <REPO_NAME> /opt/ai-workspaces/<REPO_NAME>" >&2
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root, for example: sudo bash scripts/register_workspace.sh <REPO_NAME> /opt/ai-workspaces/<REPO_NAME>" >&2
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

if [[ ! -d "${repo_path}" ]]; then
  echo "ERROR: repo path does not exist: ${repo_path}" >&2
  exit 1
fi

config_file="${REGISTRY_DIR}/${repo_name}.env"
log_dir="${LOG_ROOT}/${repo_name}"

install -d -m 0755 "${REGISTRY_DIR}"
install -d -m 0755 "${log_dir}"

if [[ -f "${config_file}" ]]; then
  echo "WARNING: existing workspace config will be overwritten: ${config_file}" >&2
fi

{
  printf "REPO_NAME=%q\n" "${repo_name}"
  printf "REPO_PATH=%q\n" "${repo_path}"
  printf "LOG_DIR=%q\n" "${log_dir}"
} >"${config_file}"

chmod 0644 "${config_file}"

cat <<EOF
Registered workspace:
  REPO_NAME=${repo_name}
  REPO_PATH=${repo_path}
  LOG_DIR=${log_dir}

Next confirmation commands:
  bash scripts/workspace_status.sh
  sudo bash scripts/run_repo_check.sh ${repo_name}
EOF
