#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ai-council"
LOG_DIR="/var/log/ai-council"
RUNTIME_CONFIG="/etc/ai-council/runtime.env"
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
apt-get install -y git curl jq ca-certificates util-linux

echo "Creating application, config, and log directories..."
install -d -m 0755 "${APP_DIR}" "${APP_DIR}/docs" "${APP_DIR}/scripts" "${APP_DIR}/systemd" "${APP_DIR}/config"
install -d -m 0755 /etc/ai-council
install -d -m 0755 "${LOG_DIR}"

echo "Copying scripts, docs, config template, and systemd units..."
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
  "vps-codex-direct.md"
  "vps-claude-code.md"
  "durable-job-lifecycle.md"
  "runtime-audit-profile.md"
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
  "run_job_cycle.sh"
  "job_status.sh"
  "extract_job_signals.sh"
  "report_job_result.sh"
  "run_ai_plan.sh"
  "run_ai_check_core.sh"
  "run_runtime_audit.sh"
  "run_ai_check.sh"
  "setup_ai_cli_runner.sh"
  "ai_cli_status.sh"
  "run_ai_exec.sh"
  "github_bridge_timer.sh"
  "claude_code_readiness.sh"
  "import_github_jobs.sh"
  "post_job_result_to_github.sh"
  "requeue_github_issue.sh"
  "deploy_runtime.sh"
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
install -m 0644 "${REPO_DIR}/config/runtime.env.example" "${APP_DIR}/config/runtime.env.example"
if [[ ! -e "${RUNTIME_CONFIG}" ]]; then
  install -m 0644 "${REPO_DIR}/config/runtime.env.example" "${RUNTIME_CONFIG}"
fi
for systemd_file in "${SYSTEMD_FILES[@]}"; do
  install -m 0644 "${REPO_DIR}/systemd/${systemd_file}" "${APP_DIR}/systemd/${systemd_file}"
  install -m 0644 "${REPO_DIR}/systemd/${systemd_file}" "/etc/systemd/system/${systemd_file}"
done

bash "${APP_DIR}/scripts/deploy_runtime.sh" --check

systemctl daemon-reload
systemctl enable --now "${TIMER_NAME}"

cat <<EOF_REPORT
Setup finished.

Initial confirmation:
  sudo systemctl status ${TIMER_NAME}
  sudo systemctl start ${SERVICE_NAME}
  sudo cat ${LOG_DIR}/latest-report.md

Runtime source of truth:
  ${RUNTIME_CONFIG}
  This file must contain only non-secret paths, repository, and label settings.
  Tokens, passwords, cookies, private keys, and other secrets are prohibited.

Workspace and operator setup:
  sudo bash ${APP_DIR}/scripts/setup_operator_user.sh
  sudo bash ${APP_DIR}/scripts/setup_workspaces.sh
  sudo bash ${APP_DIR}/scripts/register_workspace.sh <REPO_NAME> /opt/ai-workspaces/<REPO_NAME>
  bash ${APP_DIR}/scripts/workspace_status.sh
  sudo bash ${APP_DIR}/scripts/setup_ai_cli_runner.sh ai-council
  bash ${APP_DIR}/scripts/ai_cli_status.sh ai-council

GitHub bridge setup, after gh authentication and allowlist configuration:
  printf '%s\n' '<GITHUB_USERNAME>' | sudo tee /etc/ai-council/github-bridge-allowlist >/dev/null
  sudo chmod 0644 /etc/ai-council/github-bridge-allowlist
  sudo bash ${APP_DIR}/scripts/deploy_runtime.sh

Durable evidence:
  /var/log/ai-council/jobs/reports/<JOB_ID>.md
  /var/log/ai-council/jobs/summaries/<JOB_ID>.md
  /var/lib/ai-council/github-bridge/{imported,blocked,posted}/

Runtime audit:
  Create an ai_check Issue with AUDIT_PROFILE=runtime
  See ${APP_DIR}/docs/runtime-audit-profile.md

Claude Code readiness:
  bash ${APP_DIR}/scripts/claude_code_readiness.sh
EOF_REPORT
