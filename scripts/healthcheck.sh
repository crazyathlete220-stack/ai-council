#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/ai-council"
LOG_DIR="/var/log/ai-council"
failures=0

print_command_status() {
  local command_name="$1"

  printf -- "- %s: " "${command_name}"
  if command -v "${command_name}" >/dev/null 2>&1; then
    printf "OK (%s)\\n" "$(command -v "${command_name}")"
  else
    failures=$((failures + 1))
    printf "ERROR (missing)\\n"
  fi
}

print_directory_status() {
  local directory_path="$1"

  printf -- "- %s: " "${directory_path}"
  if [[ -d "${directory_path}" ]]; then
    printf "OK\\n"
  else
    failures=$((failures + 1))
    printf "ERROR (missing)\\n"
  fi
}

echo "# AI Council Healthcheck"
echo
echo "- Generated At: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "- Hostname: $(hostname)"
echo
echo "## OS"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "- Name: ${PRETTY_NAME:-unknown}"
else
  echo "- Name: unknown"
fi
echo
echo "## Disk"
df -h /
echo
echo "## Memory"
free -h
echo
echo "## Commands"
print_command_status git
print_command_status curl
echo
echo "## Directories"
print_directory_status "${APP_DIR}"
print_directory_status "${LOG_DIR}"

if [[ "${failures}" -gt 0 ]]; then
  exit 1
fi
