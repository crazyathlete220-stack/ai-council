#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
RUNTIME_CONFIG="${AI_COUNCIL_RUNTIME_CONFIG:-/etc/ai-council/runtime.env}"
BRIDGE_TIMER="${AI_COUNCIL_GITHUB_BRIDGE_TIMER_NAME:-ai-council-github-bridge.timer}"
RUNNER_TIMER="${AI_COUNCIL_JOB_RUNNER_TIMER_NAME:-ai-council-job-runner.timer}"
BRIDGE_SERVICE="${AI_COUNCIL_GITHUB_BRIDGE_SERVICE_NAME:-ai-council-github-bridge.service}"
RUNNER_SERVICE="${AI_COUNCIL_JOB_RUNNER_SERVICE_NAME:-ai-council-job-runner.service}"
MODE="${1:-deploy}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_CONFIG_TEMPLATE="${REPO_DIR}/config/runtime.env.example"

case "${MODE}" in
  deploy) ;;
  --check | check) MODE="check" ;;
  *)
    echo "ERROR: usage: bash scripts/deploy_runtime.sh [--check]" >&2
    exit 1
    ;;
esac

required_scripts=(
  healthcheck.sh
  report_status.sh
  setup_workspaces.sh
  register_workspace.sh
  workspace_status.sh
  run_repo_check.sh
  report_workspaces.sh
  setup_operator_user.sh
  create_job.sh
  run_job_once.sh
  run_job_cycle.sh
  job_status.sh
  extract_job_signals.sh
  report_job_result.sh
  run_ai_plan.sh
  run_ai_check_core.sh
  run_runtime_audit.sh
  run_ai_check.sh
  setup_ai_cli_runner.sh
  ai_cli_status.sh
  run_ai_exec.sh
  github_bridge_timer.sh
  claude_code_readiness.sh
  import_github_jobs.sh
  post_job_result_to_github.sh
  requeue_github_issue.sh
  deploy_runtime.sh
)
required_docs=(
  vps-operations.md
  runbook.md
  vps-workspace-operations.md
  vps-phase2-workspace-setup.md
  vps-ai-operator.md
  vps-job-inbox.md
  vps-github-bridge.md
  mobile-vps-jobs.md
  vps-ai-worker.md
  vps-ai-cli-runner.md
  vps-codex-direct.md
  vps-claude-code.md
  durable-job-lifecycle.md
  runtime-audit-profile.md
)
required_units=(
  ai-council-github-bridge.service
  ai-council-github-bridge.timer
  ai-council-job-runner.service
  ai-council-job-runner.timer
)
required_config_keys=(
  AI_COUNCIL_GITHUB_REPO
  AI_COUNCIL_GITHUB_JOB_LABEL
  AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE
  AI_COUNCIL_WORKSPACE_REGISTRY_DIR
  AI_COUNCIL_JOB_ROOT
  AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT
  AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR
  AI_COUNCIL_JOB_LOG_DIR
  AI_COUNCIL_AI_WORKER_LOG_ROOT
)

config_value() {
  local file="$1"
  local wanted="$2"
  awk -F= -v wanted="${wanted}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == wanted {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "${file}"
}

validate_runtime_config() {
  local file="$1"
  local line=""
  local key=""
  local value=""
  local repo=""
  local label=""
  local -A seen=()

  if [[ ! -r "${file}" ]]; then
    echo "ERROR: runtime config is not readable: ${file}" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "${line}" =~ ^([A-Z0-9_]+)=([^[:space:]]+)$ ]]; then
      echo "ERROR: invalid runtime config line in ${file}" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -n "${seen[${key}]:-}" ]]; then
      echo "ERROR: duplicate runtime config key: ${key}" >&2
      return 1
    fi
    seen["${key}"]=1
    if [[ "${key}" =~ (TOKEN|PASSWORD|SECRET|PRIVATE_KEY|COOKIE) ]]; then
      echo "ERROR: secrets are not allowed in runtime config: ${key}" >&2
      return 1
    fi
    if [[ -z "${value}" ]]; then
      echo "ERROR: blank runtime config value: ${key}" >&2
      return 1
    fi
  done < "${file}"

  for key in "${required_config_keys[@]}"; do
    if [[ -z "${seen[${key}]:-}" ]]; then
      echo "ERROR: missing runtime config key: ${key}" >&2
      return 1
    fi
  done

  repo="$(config_value "${file}" AI_COUNCIL_GITHUB_REPO)"
  label="$(config_value "${file}" AI_COUNCIL_GITHUB_JOB_LABEL)"

  if [[ ! "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: unsafe AI_COUNCIL_GITHUB_REPO in ${file}" >&2
    return 1
  fi
  if [[ ! "${label}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: unsafe AI_COUNCIL_GITHUB_JOB_LABEL in ${file}" >&2
    return 1
  fi

  for key in \
    AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE \
    AI_COUNCIL_WORKSPACE_REGISTRY_DIR \
    AI_COUNCIL_JOB_ROOT \
    AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT \
    AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR \
    AI_COUNCIL_JOB_LOG_DIR \
    AI_COUNCIL_AI_WORKER_LOG_ROOT; do
    value="$(config_value "${file}" "${key}")"
    if [[ "${value}" != /* || "${value}" == *".."* ]]; then
      echo "ERROR: ${key} must be a safe absolute path" >&2
      return 1
    fi
  done

  echo "RUNTIME_CONFIG_STATUS: OK"
  echo "RUNTIME_CONFIG_REPO: ${repo}"
  echo "RUNTIME_CONFIG_LABEL: ${label}"
}

preflight() {
  local file=""
  local unit=""
  local config_source=""

  [[ -f "${RUNTIME_CONFIG_TEMPLATE}" ]] || { echo "ERROR: missing config/runtime.env.example" >&2; return 1; }

  for file in "${required_scripts[@]}"; do
    [[ -f "${REPO_DIR}/scripts/${file}" ]] || { echo "ERROR: missing scripts/${file}" >&2; return 1; }
  done
  for file in "${required_docs[@]}"; do
    [[ -f "${REPO_DIR}/docs/${file}" ]] || { echo "ERROR: missing docs/${file}" >&2; return 1; }
  done
  for file in "${required_units[@]}"; do
    [[ -f "${REPO_DIR}/systemd/${file}" ]] || { echo "ERROR: missing systemd/${file}" >&2; return 1; }
  done

  bash -n "${REPO_DIR}"/scripts/*.sh
  validate_runtime_config "${RUNTIME_CONFIG_TEMPLATE}" >/dev/null

  for unit in ai-council-github-bridge.service ai-council-job-runner.service; do
    if ! grep -Fxq "EnvironmentFile=${RUNTIME_CONFIG}" "${REPO_DIR}/systemd/${unit}"; then
      echo "ERROR: ${unit} does not require ${RUNTIME_CONFIG}" >&2
      return 1
    fi
  done

  if [[ -e "${RUNTIME_CONFIG}" ]]; then
    validate_runtime_config "${RUNTIME_CONFIG}" >/dev/null
    config_source="existing"
  else
    config_source="template-will-be-installed"
  fi

  echo "DEPLOY_RUNTIME_PREFLIGHT: OK"
  echo "PREFLIGHT_SCRIPTS: ${#required_scripts[@]}"
  echo "PREFLIGHT_DOCS: ${#required_docs[@]}"
  echo "PREFLIGHT_UNITS: ${#required_units[@]}"
  echo "PREFLIGHT_CONFIG_SOURCE: ${config_source}"
}

preflight

if [[ "${MODE}" == "check" ]]; then
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root: sudo bash scripts/deploy_runtime.sh" >&2
  exit 1
fi

install -d -m 0755 /etc/ai-council
if [[ ! -e "${RUNTIME_CONFIG}" ]]; then
  install -m 0644 "${RUNTIME_CONFIG_TEMPLATE}" "${RUNTIME_CONFIG}"
fi
validate_runtime_config "${RUNTIME_CONFIG}"

install -d -m 0755 "${APP_DIR}/scripts" "${APP_DIR}/docs" "${APP_DIR}/systemd" "${APP_DIR}/config"

# Copy every runtime dependency from the same reviewed checkout. Dependencies
# are installed before systemd units are reloaded, preventing mixed versions.
for file in "${required_scripts[@]}"; do
  install -m 0755 "${REPO_DIR}/scripts/${file}" "${APP_DIR}/scripts/${file}"
done
for file in "${required_docs[@]}"; do
  install -m 0644 "${REPO_DIR}/docs/${file}" "${APP_DIR}/docs/${file}"
done
install -m 0644 "${RUNTIME_CONFIG_TEMPLATE}" "${APP_DIR}/config/runtime.env.example"
for file in "${required_units[@]}"; do
  install -m 0644 "${REPO_DIR}/systemd/${file}" "${APP_DIR}/systemd/${file}"
  install -m 0644 "${REPO_DIR}/systemd/${file}" "/etc/systemd/system/${file}"
done

copy_mismatch=0
for file in "${required_scripts[@]}"; do
  cmp -s "${REPO_DIR}/scripts/${file}" "${APP_DIR}/scripts/${file}" || copy_mismatch=$((copy_mismatch + 1))
done
for file in "${required_docs[@]}"; do
  cmp -s "${REPO_DIR}/docs/${file}" "${APP_DIR}/docs/${file}" || copy_mismatch=$((copy_mismatch + 1))
done
for file in "${required_units[@]}"; do
  cmp -s "${REPO_DIR}/systemd/${file}" "/etc/systemd/system/${file}" || copy_mismatch=$((copy_mismatch + 1))
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
bridge_execstart="$(systemctl show "${BRIDGE_SERVICE}" -p ExecStart --value 2>/dev/null || true)"
runner_execstart="$(systemctl show "${RUNNER_SERVICE}" -p ExecStart --value 2>/dev/null || true)"
bridge_mode="UNKNOWN"
runner_mode="UNKNOWN"
[[ "${bridge_execstart}" == *"/scripts/import_github_jobs.sh"* ]] && bridge_mode="IMPORT_ONLY"
[[ "${runner_execstart}" == *"/scripts/run_job_cycle.sh"* ]] && runner_mode="DURABLE_CYCLE"

cat <<EOF_REPORT
AI Council runtime deployment
- app dir: ${APP_DIR}
- runtime config: ${RUNTIME_CONFIG}
- configured repository: $(config_value "${RUNTIME_CONFIG}" AI_COUNCIL_GITHUB_REPO)
- configured label: $(config_value "${RUNTIME_CONFIG}" AI_COUNCIL_GITHUB_JOB_LABEL)
- installed scripts: ${#required_scripts[@]}
- installed docs: ${#required_docs[@]}
- installed unit files: ${#required_units[@]}
- copy mismatches: ${copy_mismatch}
- bridge mode: ${bridge_mode}
- bridge timer: ${bridge_timer_active:-unknown} / ${bridge_timer_enabled:-unknown}
- runner mode: ${runner_mode}
- runner timer: ${runner_timer_active:-unknown} / ${runner_timer_enabled:-unknown}
- bridge service start status: ${bridge_start_status}
- runner service start status: ${runner_start_status}
- bridge log: journalctl -u ${BRIDGE_SERVICE} -n 100 --no-pager
- runner log: journalctl -u ${RUNNER_SERVICE} -n 100 --no-pager
EOF_REPORT

if [[ "${copy_mismatch}" -eq 0 && "${bridge_mode}" == "IMPORT_ONLY" && "${runner_mode}" == "DURABLE_CYCLE" && "${bridge_timer_active}" == "active" && "${runner_timer_active}" == "active" && "${bridge_timer_enabled}" == "enabled" && "${runner_timer_enabled}" == "enabled" && "${bridge_start_status}" -eq 0 && "${runner_start_status}" -eq 0 ]]; then
  echo "DEPLOY_RUNTIME_STATUS: OK"
  exit 0
fi

echo "DEPLOY_RUNTIME_STATUS: ERROR" >&2
exit 1
