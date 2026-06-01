#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ai-council"
LOG_DIR="/var/log/ai-council"
SERVICE_NAME="ai-council-healthcheck.service"
TIMER_NAME="ai-council-healthcheck.timer"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root, for example: sudo bash scripts/bootstrap_vps.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Installing minimum packages..."
apt-get update
apt-get install -y git curl jq ca-certificates

echo "Creating application and log directories..."
install -d -m 0755 "${APP_DIR}"
install -d -m 0755 "${APP_DIR}/docs"
install -d -m 0755 "${APP_DIR}/scripts"
install -d -m 0755 "${APP_DIR}/systemd"
install -d -m 0755 "${LOG_DIR}"

echo "Copying scripts and systemd units..."
install -m 0644 "${REPO_DIR}/README.md" "${APP_DIR}/README.md"
install -m 0644 "${REPO_DIR}/docs/vps-operations.md" "${APP_DIR}/docs/vps-operations.md"
install -m 0644 "${REPO_DIR}/docs/runbook.md" "${APP_DIR}/docs/runbook.md"
install -m 0755 "${REPO_DIR}/scripts/healthcheck.sh" "${APP_DIR}/scripts/healthcheck.sh"
install -m 0755 "${REPO_DIR}/scripts/report_status.sh" "${APP_DIR}/scripts/report_status.sh"
install -m 0644 "${REPO_DIR}/systemd/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"
install -m 0644 "${REPO_DIR}/systemd/${TIMER_NAME}" "/etc/systemd/system/${TIMER_NAME}"

echo "Reloading systemd and enabling timer..."
systemctl daemon-reload
systemctl enable --now "${TIMER_NAME}"

cat <<EOF
Setup finished.

Next confirmation commands:
  sudo systemctl status ${TIMER_NAME}
  sudo systemctl list-timers ${TIMER_NAME}
  sudo systemctl start ${SERVICE_NAME}
  sudo cat ${LOG_DIR}/latest-report.md
  sudo journalctl -u ${SERVICE_NAME} -n 100 --no-pager
EOF
