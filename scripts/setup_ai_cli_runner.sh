#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sudo bash scripts/setup_ai_cli_runner.sh [REPO_NAME]" >&2
}

OPERATOR_USER="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
AI_CLI_STATE_ROOT="${AI_COUNCIL_AI_CLI_STATE_ROOT:-/var/lib/ai-council/ai-cli}"
AI_CLI_LOG_ROOT="${AI_COUNCIL_AI_CLI_LOG_ROOT:-/var/log/ai-council/ai-cli}"
REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
repo_name="${1:-}"

if [[ "${repo_name}" == "--help" || "${repo_name}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root, for example: sudo bash scripts/setup_ai_cli_runner.sh ai-council" >&2
  exit 1
fi

if [[ -n "${repo_name}" && ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: REPO_NAME may contain only letters, numbers, dot, underscore, and hyphen" >&2
  exit 1
fi

if ! id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
  echo "ERROR: Operator user not found: ${OPERATOR_USER}" >&2
  echo "Run first: sudo bash scripts/setup_operator_user.sh" >&2
  exit 1
fi

echo "Creating AI CLI runner directories..."
install -d -m 0755 /var/lib/ai-council
install -d -m 0755 /var/log/ai-council
install -d -o "${OPERATOR_USER}" -g "${OPERATOR_USER}" -m 0750 "${AI_CLI_STATE_ROOT}"
install -d -o "${OPERATOR_USER}" -g "${OPERATOR_USER}" -m 0755 "${AI_CLI_LOG_ROOT}"

repo_path=""
if [[ -n "${repo_name}" ]]; then
  config_file="${REGISTRY_DIR}/${repo_name}.env"
  if [[ ! -r "${config_file}" ]]; then
    echo "ERROR: Workspace config is not readable: ${config_file}" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${config_file}"
  repo_path="${REPO_PATH:-}"

  if [[ -z "${repo_path}" || ! -d "${repo_path}" ]]; then
    echo "ERROR: Registered repo path does not exist: ${repo_path:-not set}" >&2
    exit 1
  fi

  echo "Making workspace writable by ${OPERATOR_USER}: ${repo_path}"
  chown -R "${OPERATOR_USER}:${OPERATOR_USER}" "${repo_path}"
fi

cat <<EOF
AI CLI runner setup finished.

Created or confirmed:
  user: ${OPERATOR_USER}
  ${AI_CLI_STATE_ROOT}
  ${AI_CLI_LOG_ROOT}
EOF

if [[ -n "${repo_path}" ]]; then
  cat <<EOF
  repo: ${repo_name}
  repo path: ${repo_path}
EOF
fi

cat <<EOF

Next confirmation commands:
  bash scripts/ai_cli_status.sh ${repo_name:-ai-council}
  sudo bash scripts/create_job.sh ai_exec ${repo_name:-ai-council}
  sudo bash scripts/run_job_once.sh

Authentication note:
  Configure Codex CLI authentication for ${OPERATOR_USER} on the VPS outside this repository.
  Do not write tokens, SSH private keys, API keys, or passwords into this repository.
EOF
