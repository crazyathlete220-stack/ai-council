#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: bash scripts/ai_cli_status.sh [REPO_NAME]" >&2
}

OPERATOR_USER="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
AI_CLI_LOG_ROOT="${AI_COUNCIL_AI_CLI_LOG_ROOT:-/var/log/ai-council/ai-cli}"
repo_name="${1:-ai-council}"
errors=0
warnings=0

if [[ "${repo_name}" == "--help" || "${repo_name}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: REPO_NAME may contain only letters, numbers, dot, underscore, and hyphen" >&2
  exit 1
fi

mark_error() {
  echo "[ERROR] $1"
  errors=$((errors + 1))
}

mark_warning() {
  echo "[WARN] $1"
  warnings=$((warnings + 1))
}

run_as_operator() {
  if [[ "${EUID}" -eq 0 && -n "${OPERATOR_USER}" ]] && id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
    sudo -H -u "${OPERATOR_USER}" "$@"
  else
    "$@"
  fi
}

auth_user_label() {
  if [[ "${EUID}" -eq 0 && -n "${OPERATOR_USER}" ]] && id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
    echo "${OPERATOR_USER}"
  else
    id -un
  fi
}

check_cli() {
  local name="$1"
  local auth_command="$2"
  local cli_path=""

  if cli_path="$(command -v "${name}" 2>/dev/null)"; then
    echo "- ${name}: ${cli_path}"
    if "${name}" --version >/dev/null 2>&1; then
      echo "- ${name} version: $("${name}" --version 2>/dev/null | head -n 1)"
    else
      mark_warning "${name} version check failed"
    fi

    if run_as_operator bash -lc "${auth_command}" >/dev/null 2>&1; then
      echo "- ${name} auth: ok for $(auth_user_label)"
      return 0
    fi

    mark_warning "${name} auth is not confirmed for $(auth_user_label)"
    return 1
  fi

  mark_warning "${name} command is not installed"
  return 1
}

repo_path="not registered"
repo_writable="no"
config_file="${REGISTRY_DIR}/${repo_name}.env"

echo "AI Council AI CLI status"
echo
echo "- operator user: ${OPERATOR_USER}"

if id -u "${OPERATOR_USER}" >/dev/null 2>&1; then
  echo "- operator user exists: yes"
else
  mark_error "operator user does not exist: ${OPERATOR_USER}"
fi

if [[ -r "${config_file}" ]]; then
  # shellcheck disable=SC1090
  source "${config_file}"
  repo_path="${REPO_PATH:-not registered}"
else
  mark_error "workspace config is not readable: ${config_file}"
fi

echo "- repo name: ${repo_name}"
echo "- repo path: ${repo_path}"

if [[ "${repo_path}" != "not registered" && -d "${repo_path}" ]]; then
  echo "- repo path exists: yes"
  if run_as_operator test -w "${repo_path}" >/dev/null 2>&1; then
    repo_writable="yes"
    echo "- repo writable by ${OPERATOR_USER}: yes"
  else
    mark_error "repo is not writable by ${OPERATOR_USER}: ${repo_path}"
  fi
else
  mark_error "repo path does not exist: ${repo_path}"
fi

echo "- ai cli log root: ${AI_CLI_LOG_ROOT}"
if [[ -d "${AI_CLI_LOG_ROOT}" ]]; then
  echo "- ai cli log root exists: yes"
else
  mark_warning "ai cli log root does not exist yet"
fi

echo
echo "## CLI"
codex_ready=0
claude_ready=0

if check_cli "codex" "codex login status"; then
  codex_ready=1
fi

if check_cli "claude" "claude auth status"; then
  claude_ready=1
fi

echo
echo "## Result"
echo "- errors: ${errors}"
echo "- warnings: ${warnings}"
echo "- codex ready: ${codex_ready}"
echo "- claude ready: ${claude_ready}"
echo "- repo writable: ${repo_writable}"

if [[ "${errors}" -eq 0 && "${repo_writable}" == "yes" && "${codex_ready}" -eq 1 ]]; then
  echo
  echo "AI_CLI_STATUS: READY"
else
  echo
  echo "AI_CLI_STATUS: NOT_READY"
  exit 1
fi
