#!/usr/bin/env bash
set -euo pipefail

required_memory_mb="${AI_COUNCIL_CLAUDE_REQUIRED_MEMORY_MB:-4096}"
operator_user="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
errors=0
warnings=0

mark_error() {
  echo "[ERROR] $1"
  errors=$((errors + 1))
}

mark_warning() {
  echo "[WARN] $1"
  warnings=$((warnings + 1))
}

version_major() {
  sed -E 's/^v?([0-9]+).*/\1/'
}

run_as_operator() {
  if [[ "${EUID}" -eq 0 && -n "${operator_user}" ]] && id -u "${operator_user}" >/dev/null 2>&1; then
    sudo -H -u "${operator_user}" "$@"
  else
    "$@"
  fi
}

auth_user_label() {
  if [[ "${EUID}" -eq 0 && -n "${operator_user}" ]] && id -u "${operator_user}" >/dev/null 2>&1; then
    echo "${operator_user}"
  else
    id -un
  fi
}

echo "AI Council Claude Code readiness"
echo

echo "## Host"
echo "- hostname: $(hostname)"
echo "- operator user: ${operator_user}"
if id -u "${operator_user}" >/dev/null 2>&1; then
  echo "- operator user exists: yes"
else
  mark_warning "operator user does not exist: ${operator_user}"
fi
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "- os: ${PRETTY_NAME:-unknown}"
else
  mark_warning "/etc/os-release is not readable"
fi

memory_mb=0
if [[ -r /proc/meminfo ]]; then
  memory_mb="$(awk '/MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
  echo "- memory mb: ${memory_mb}"
  if [[ "${memory_mb}" -lt "${required_memory_mb}" ]]; then
    mark_warning "memory is below Claude Code guidance: ${memory_mb} MB < ${required_memory_mb} MB"
  fi
else
  mark_warning "/proc/meminfo is not readable"
fi

echo
echo "## Runtime"
if command -v node >/dev/null 2>&1; then
  node_version="$(node --version 2>/dev/null | head -n 1)"
  echo "- node: $(command -v node)"
  echo "- node version: ${node_version}"
  node_major="$(printf "%s" "${node_version}" | version_major)"
  if [[ ! "${node_major}" =~ ^[0-9]+$ || "${node_major}" -lt 18 ]]; then
    mark_error "Node.js 18 or later is required for npm-based Claude Code installation"
  fi
else
  mark_warning "node command is not installed"
fi

if command -v npm >/dev/null 2>&1; then
  echo "- npm: $(command -v npm)"
  echo "- npm version: $(npm --version 2>/dev/null | head -n 1)"
else
  mark_warning "npm command is not installed"
fi

echo
echo "## Claude Code"
claude_ready=0
claude_path=""
if claude_path="$(run_as_operator bash -lc 'command -v claude' 2>/dev/null)"; then
  echo "- claude: ${claude_path}"
  if run_as_operator bash -lc 'claude --version' >/dev/null 2>&1; then
    echo "- claude version: $(run_as_operator bash -lc 'claude --version' 2>/dev/null | head -n 1)"
  else
    mark_warning "claude version check failed"
  fi

  if run_as_operator bash -lc 'claude auth status' >/dev/null 2>&1; then
    echo "- claude auth: ok for $(auth_user_label)"
    claude_ready=1
  else
    mark_warning "claude auth is not confirmed for $(auth_user_label)"
  fi
else
  mark_warning "claude command is not installed for $(auth_user_label)"
fi

echo
echo "## Result"
echo "- errors: ${errors}"
echo "- warnings: ${warnings}"
echo "- claude ready: ${claude_ready}"

if [[ "${errors}" -eq 0 && "${claude_ready}" -eq 1 && "${memory_mb}" -ge "${required_memory_mb}" ]]; then
  echo
  echo "CLAUDE_CODE_READINESS_STATUS: READY"
else
  echo
  echo "CLAUDE_CODE_READINESS_STATUS: NOT_READY"
fi
