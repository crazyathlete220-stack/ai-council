#!/usr/bin/env bash
set -euo pipefail

OPERATOR_USER="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
JOB_LOG_DIR="${AI_COUNCIL_JOB_LOG_DIR:-/var/log/ai-council/jobs}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root, for example: sudo bash scripts/setup_operator_user.sh" >&2
  exit 1
fi

if ! id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
  echo "Creating operator user: ${OPERATOR_USER}"
  useradd --system --create-home --shell /bin/bash "${OPERATOR_USER}"
else
  echo "Operator user already exists: ${OPERATOR_USER}"
fi

echo "Creating job inbox and durable result directories..."
install -d -m 0755 /etc/ai-council
install -d -m 0755 /var/lib/ai-council
install -d -m 0775 "${JOB_ROOT}"
install -d -m 0775 "${JOB_ROOT}/queue"
install -d -m 0775 "${JOB_ROOT}/active"
install -d -m 0775 "${JOB_ROOT}/done"
install -d -m 0775 "${JOB_ROOT}/failed"
install -d -m 0775 "${JOB_ROOT}/deferred"
install -d -m 0775 "${JOB_LOG_DIR}"
install -d -m 0775 "${JOB_LOG_DIR}/reports"
install -d -m 0775 "${JOB_LOG_DIR}/pending-posts"

chown -R "${OPERATOR_USER}:${OPERATOR_USER}" "${JOB_ROOT}" "${JOB_LOG_DIR}"

cat <<EOF
Operator setup finished.

Created or confirmed:
  user: ${OPERATOR_USER}
  ${JOB_ROOT}/queue
  ${JOB_ROOT}/active
  ${JOB_ROOT}/done
  ${JOB_ROOT}/failed
  ${JOB_ROOT}/deferred
  ${JOB_LOG_DIR}/reports
  ${JOB_LOG_DIR}/pending-posts

Next confirmation commands:
  bash scripts/job_status.sh
  bash scripts/create_job.sh repo_check <REPO_NAME>
  bash scripts/create_job.sh ai_plan ai-council
  bash scripts/create_job.sh ai_check ai-council
  sudo bash scripts/setup_ai_cli_runner.sh ai-council
  bash scripts/ai_cli_status.sh ai-council
  sudo bash scripts/create_job.sh ai_exec ai-council
  sudo bash scripts/run_job_cycle.sh
EOF
