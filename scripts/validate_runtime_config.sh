#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

CONFIG_FILE="${1:-}"

if [[ -z "${CONFIG_FILE}" || ! -r "${CONFIG_FILE}" ]]; then
  echo "ERROR: readable runtime config path is required" >&2
  exit 1
fi

if [[ -L "${CONFIG_FILE}" ]]; then
  echo "ERROR: runtime config must not be a symbolic link: ${CONFIG_FILE}" >&2
  exit 1
fi

config_size="$(wc -c < "${CONFIG_FILE}" | tr -d '[:space:]')"
if [[ ! "${config_size}" =~ ^[0-9]+$ || "${config_size}" -gt 16384 ]]; then
  echo "ERROR: runtime config is unexpectedly large" >&2
  exit 1
fi

config_mode="$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || true)"
if [[ -n "${config_mode}" && "${config_mode}" =~ ^[0-7]{3,4}$ ]]; then
  config_mode_value=$((8#${config_mode}))
  if (( config_mode_value & 0022 )); then
    echo "ERROR: runtime config must not be group- or world-writable: mode ${config_mode}" >&2
    exit 1
  fi
fi

required_keys=(
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

declare -A allowed=()
declare -A seen=()
declare -A values=()
for key in "${required_keys[@]}"; do
  allowed["${key}"]=1
done

line=""
key=""
value=""
line_number=0

while IFS= read -r line || [[ -n "${line}" ]]; do
  line_number=$((line_number + 1))
  [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue

  if [[ ! "${line}" =~ ^([A-Z0-9_]+)=([^[:space:]]+)$ ]]; then
    echo "ERROR: invalid runtime config syntax at line ${line_number}" >&2
    exit 1
  fi

  key="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"

  if [[ -z "${allowed[${key}]:-}" ]]; then
    echo "ERROR: unsupported runtime config key: ${key}" >&2
    exit 1
  fi
  if [[ -n "${seen[${key}]:-}" ]]; then
    echo "ERROR: duplicate runtime config key: ${key}" >&2
    exit 1
  fi
  if [[ "${key}" =~ (TOKEN|PASSWORD|SECRET|PRIVATE_KEY|COOKIE) ]]; then
    echo "ERROR: secret-bearing keys are prohibited: ${key}" >&2
    exit 1
  fi

  seen["${key}"]=1
  values["${key}"]="${value}"
done < "${CONFIG_FILE}"

for key in "${required_keys[@]}"; do
  if [[ -z "${seen[${key}]:-}" ]]; then
    echo "ERROR: missing runtime config key: ${key}" >&2
    exit 1
  fi
done

repo="${values[AI_COUNCIL_GITHUB_REPO]}"
label="${values[AI_COUNCIL_GITHUB_JOB_LABEL]}"

if [[ ! "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "ERROR: unsafe AI_COUNCIL_GITHUB_REPO" >&2
  exit 1
fi
if [[ ! "${label}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: unsafe AI_COUNCIL_GITHUB_JOB_LABEL" >&2
  exit 1
fi

path_keys=(
  AI_COUNCIL_GITHUB_ALLOWED_USERS_FILE
  AI_COUNCIL_WORKSPACE_REGISTRY_DIR
  AI_COUNCIL_JOB_ROOT
  AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT
  AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR
  AI_COUNCIL_JOB_LOG_DIR
  AI_COUNCIL_AI_WORKER_LOG_ROOT
)

for key in "${path_keys[@]}"; do
  value="${values[${key}]}"
  if [[ "${value}" != /* || "${value}" == *".."* || "${value}" == *"//"* ]]; then
    echo "ERROR: ${key} must be a normalized absolute path" >&2
    exit 1
  fi
done

echo "RUNTIME_CONFIG_STATUS: OK"
echo "RUNTIME_CONFIG_REPO: ${repo}"
echo "RUNTIME_CONFIG_LABEL: ${label}"
echo "RUNTIME_CONFIG_MODE: ${config_mode:-UNKNOWN}"
