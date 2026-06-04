#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: bash scripts/github_bridge_timer.sh <status|enable|disable>

Commands:
  status    Show current GitHub bridge timer state.
  enable    Enable and start the GitHub bridge timer. Requires root.
  disable   Disable and stop the GitHub bridge timer. Requires root.
USAGE
}

TIMER_NAME="${AI_COUNCIL_GITHUB_BRIDGE_TIMER_NAME:-ai-council-github-bridge.timer}"
SERVICE_NAME="${AI_COUNCIL_GITHUB_BRIDGE_SERVICE_NAME:-ai-council-github-bridge.service}"
action="${1:-status}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this action as root, for example: sudo bash scripts/github_bridge_timer.sh ${action}" >&2
    exit 1
  fi
}

show_status() {
  local enabled="unknown"
  local active="unknown"
  local next_run="not listed"
  local status="PARTIAL"

  enabled="$(systemctl is-enabled "${TIMER_NAME}" 2>/dev/null || true)"
  active="$(systemctl is-active "${TIMER_NAME}" 2>/dev/null || true)"
  next_run="$(systemctl list-timers --all "${TIMER_NAME}" --no-pager 2>/dev/null | awk 'NR==2 {print $1 " " $2 " " $3 " " $4 " " $5}' || true)"
  enabled="${enabled:-unknown}"
  active="${active:-unknown}"
  next_run="${next_run:-not listed}"

  echo "AI Council GitHub bridge timer"
  echo
  echo "- timer: ${TIMER_NAME}"
  echo "- service: ${SERVICE_NAME}"
  echo "- enabled: ${enabled}"
  echo "- active: ${active}"
  echo "- next: ${next_run}"
  echo
  systemctl status "${TIMER_NAME}" --no-pager 2>/dev/null || true
  echo

  if [[ "${enabled}" == "enabled" && "${active}" == "active" ]]; then
    status="ON"
  elif [[ "${enabled}" == "disabled" && "${active}" == "inactive" ]]; then
    status="OFF"
  fi

  echo "GITHUB_BRIDGE_TIMER_STATUS: ${status}"
}

case "${action}" in
  status)
    show_status
    ;;
  enable | on)
    require_root
    systemctl enable --now "${TIMER_NAME}"
    show_status
    ;;
  disable | off)
    require_root
    systemctl disable --now "${TIMER_NAME}"
    show_status
    ;;
  --help | -h)
    usage
    ;;
  *)
    echo "ERROR: Unsupported action: ${action}" >&2
    usage
    exit 1
    ;;
esac
