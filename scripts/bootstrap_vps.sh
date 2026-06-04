#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ai-council"
LOG_DIR="/var/log/ai-council"
SERVICE_NAME="ai-council-healthcheck.service"
TIMER_NAME="ai-council-healthcheck.timer"
JOB_SERVICE_NAME="ai-council-job-runner.service"
JOB_TIMER_NAME="ai-council-job-runner.timer"
GITHUB_BRIDGE_SERVICE_NAME="ai-council-github-bridge.service"
GITHUB_BRIDGE_TIMER_NAME="ai-council-github-bridge.timer"

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

DOC_FILES=(
  "vps-operations.md"
  "runbook.md"
  "vps-workspace-operations.md"
  "vps-phase2-workspace-setup.md"
  "vps-ai-operator.md"
  "vps-job-inbox.md"
  "vps-github-bridge.md"
  "mobile-vps-jobs.md"
  "vps-ai-worker.md"
  "vps-ai-cli-runner.md"
)

SCRIPT_FILES=(
  "healthcheck.sh"
  "report_status.sh"
  "setup_workspaces.sh"
  "register_workspace.sh"
  "workspace_status.sh"
  "run_repo_check.sh"
  "report_workspaces.sh"
  "setup_operator_user.sh"
  "create_job.sh"
  "run_job_once.sh"
  "job_status.sh"
  "report_job_result.sh"
  "run_ai_plan.sh"
  "run_ai_check.sh"
  "setup_ai_cli_runner.sh"
  "ai_cli_status.sh"
  "run_ai_exec.sh"
  "import_github_jobs.sh"
  "post_job_result_to_github.sh"
)

SYSTEMD_FILES=(
  "${SERVICE_NAME}"
  "${TIMER_NAME}"
  "${JOB_SERVICE_NAME}"
  "${JOB_TIMER_NAME}"
  "${GITHUB_BRIDGE_SERVICE_NAME}"
  "${GITHUB_BRIDGE_TIMER_NAME}"
)

for doc_file in "${DOC_FILES[@]}"; do
  install -m 0644 "${REPO_DIR}/docs/${doc_file}" "${APP_DIR}/docs/${doc_file}"
done

for script_file in "${SCRIPT_FILES[@]}"; do
  install -m 0755 "${REPO_DIR}/scripts/${script_file}" "${APP_DIR}/scripts/${script_file}"
done

for systemd_file in "${SYSTEMD_FILES[@]}"; do
  install -m 0644 "${REPO_DIR}/systemd/${systemd_file}" "/etc/systemd/system/${systemd_file}"
done

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

Phase 3 operator commands, after review:
  sudo bash ${APP_DIR}/scripts/setup_operator_user.sh
  bash ${APP_DIR}/scripts/job_status.sh
  bash ${APP_DIR}/scripts/create_job.sh repo_check <REPO_NAME>
  bash ${APP_DIR}/scripts/create_job.sh ai_plan ai-council
  bash ${APP_DIR}/scripts/create_job.sh ai_check ai-council
  sudo bash ${APP_DIR}/scripts/setup_ai_cli_runner.sh ai-council
  bash ${APP_DIR}/scripts/ai_cli_status.sh ai-council
  bash ${APP_DIR}/scripts/create_job.sh ai_exec ai-council
  sudo bash ${APP_DIR}/scripts/run_job_once.sh
  sudo bash ${APP_DIR}/scripts/report_job_result.sh
  sudo systemctl enable --now ${JOB_TIMER_NAME}

GitHub bridge commands, after gh authentication is configured on the VPS:
  sudo bash ${APP_DIR}/scripts/import_github_jobs.sh
  sudo bash ${APP_DIR}/scripts/post_job_result_to_github.sh
  sudo systemctl enable --now ${GITHUB_BRIDGE_TIMER_NAME}
EOF
