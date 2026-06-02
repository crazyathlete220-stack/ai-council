#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="/opt/ai-workspaces"
LOG_ROOT="/var/log/ai-council/workspaces"
REGISTRY_DIR="/etc/ai-council/workspaces.d"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root, for example: sudo bash scripts/setup_workspaces.sh" >&2
  exit 1
fi

echo "Creating AI workspace directories..."
install -d -m 0755 "${WORKSPACE_ROOT}"
install -d -m 0755 "${LOG_ROOT}"
install -d -m 0755 "${REGISTRY_DIR}"

cat <<EOF
Workspace setup finished.

Created or confirmed:
  ${WORKSPACE_ROOT}
  ${LOG_ROOT}
  ${REGISTRY_DIR}

Next confirmation commands:
  sudo bash scripts/register_workspace.sh <REPO_NAME> ${WORKSPACE_ROOT}/<REPO_NAME>
  bash scripts/workspace_status.sh
  bash scripts/run_repo_check.sh <REPO_NAME>
  bash scripts/report_workspaces.sh
EOF
