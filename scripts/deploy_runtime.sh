#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
BRIDGE_TIMER="${AI_COUNCIL_GITHUB_BRIDGE_TIMER_NAME:-ai-council-github-bridge.timer}"
RUNNER_TIMER="${AI_COUNCIL_JOB_RUNNER_TIMER_NAME:-ai-council-job-runner.timer}"
BRIDGE_SERVICE="${AI_COUNCIL_GITHUB_BRIDGE_SERVICE_NAME:-ai-council-github-bridge.service}"
RUNNER_SERVICE="${AI_COUNCIL_JOB_RUNNER_SERVICE_NAME:-ai-council-job-runner.service}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root: sudo bash scripts/deploy_runtime.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

required_scripts=(
  import_github_jobs.sh
  run_job_once.sh
  run_job_cycle.sh
  report_job_result.sh
  post_job_result_to_github.sh
  requeue_github_issue.sh
)
required_units=(
  ai-council-github-bridge.service
  ai-council-github-bridge.timer
  ai-council-job-runner.service
  ai-council-job-runner.timer
)

for file in "${required_scripts[@]}"; do
  [[ -f "${REPO_DIR}/scripts/${file}" ]] || { echo "ERROR: missing scripts/${file}" >&2; exit 1; }
done
for file in "${required_units[@]}"; do
  [[ -f "${REPO_DIR}/systemd/${file}" ]] || { echo "ERROR: missing systemd/${file}" >&2; exit 1; }
done

bash -n "${REPO_DIR}"/scripts/*.sh
install -d -m 0755 "${APP_DIR}/scripts" "${APP_DIR}/systemd"

for file in "${required_scripts[@]}"; do
  install -m 0755 "${REPO_DIR}/scripts/${file}" "${APP_DIR}/scripts/${file}"
done
for file in "${required_units[@]}"; do
  install -m 0644 "${REPO_DIR}/systemd/${file}" "${APP_DIR}/systemd/${file}"
  install -m 0644 "${REPO_DIR}/systemd/${file}" "/etc/systemd/system/${file}"
done

systemctl daemon-reload
systemctl enable --now "${BRIDGE_TIMER}" "${RUNNER_TIMER}"

bridge_start_status=0
runner_start_status=0
systemctl start "${BRIDGE_SERVICE}" || bridge_start_status=$?
systemctl start "${RUNNER_SERVICE}" || runner_start_status=$?

bridge_timer_active="$(systemctl is-active "${BRIDGE_TIMER}" 2>/dev/null || true)"
runner_timer_active="$(systemctl is-active "${RUNNER_TIMER}" 2>/dev/null || true)"
bridge_timer_enabled="$(systemctl is-enabled "${BRIDGE_TIMER}" 2>/dev/null || true)"
runner_timer_enabled="$(systemctl is-enabled "${RUNNER_TIMER}" 2>/dev/null || true)"

cat <<EOF_REPORT
AI Council runtime deployment
- app dir: ${APP_DIR}
- bridge timer: ${bridge_timer_active:-unknown} / ${bridge_timer_enabled:-unknown}
- runner timer: ${runner_timer_active:-unknown} / ${runner_timer_enabled:-unknown}
- bridge service start status: ${bridge_start_status}
- runner service start status: ${runner_start_status}
- bridge log: journalctl -u ${BRIDGE_SERVICE} -n 100 --no-pager
- runner log: journalctl -u ${RUNNER_SERVICE} -n 100 --no-pager
EOF_REPORT

if [[ "${bridge_timer_active}" == "active" && "${runner_timer_active}" == "active" && "${bridge_timer_enabled}" == "enabled" && "${runner_timer_enabled}" == "enabled" ]]; then
  echo "DEPLOY_RUNTIME_STATUS: OK"
  exit 0
fi

echo "DEPLOY_RUNTIME_STATUS: ERROR" >&2
exit 1
