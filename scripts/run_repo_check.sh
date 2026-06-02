#!/usr/bin/env bash
set -euo pipefail

REGISTRY_DIR="/etc/ai-council/workspaces.d"
errors=0

usage() {
  echo "Usage: sudo bash scripts/run_repo_check.sh <REPO_NAME>" >&2
}

mark_error() {
  echo "[ERROR] $1"
  errors=$((errors + 1))
}

mark_skip() {
  echo "[SKIP] $1"
}

run_step() {
  local label="$1"
  shift

  echo
  echo "### ${label}"
  if "$@"; then
    echo "RESULT: OK"
  else
    local status="$?"
    echo "RESULT: ERROR (${status})"
    errors=$((errors + 1))
  fi
}

has_npm_script() {
  local script_name="$1"

  node -e 'const fs = require("fs"); const script = process.argv[1]; const pkg = JSON.parse(fs.readFileSync("package.json", "utf8")); const scripts = pkg.scripts || {}; process.exit(Object.prototype.hasOwnProperty.call(scripts, script) ? 0 : 1);' "${script_name}"
}

show_npm_scripts() {
  echo
  echo "### npm run script list"
  if npm run; then
    echo "RESULT: OK"
  else
    echo "RESULT: SKIP_OR_EMPTY"
  fi
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 1
fi

requested_repo="$1"

if [[ ! "${requested_repo}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: repo name may contain only letters, numbers, dot, underscore, and dash" >&2
  exit 1
fi

config_file="${REGISTRY_DIR}/${requested_repo}.env"
if [[ ! -r "${config_file}" ]]; then
  echo "ERROR: workspace config is not readable: ${config_file}" >&2
  echo "Try: sudo bash scripts/register_workspace.sh ${requested_repo} /opt/ai-workspaces/${requested_repo}" >&2
  echo "Then: sudo bash scripts/run_repo_check.sh ${requested_repo}" >&2
  exit 1
fi

REPO_NAME=""
REPO_PATH=""
LOG_DIR=""
# shellcheck source=/dev/null
. "${config_file}"

if [[ "${REPO_NAME}" != "${requested_repo}" ]]; then
  echo "ERROR: config repo name mismatch: expected ${requested_repo}, got ${REPO_NAME}" >&2
  exit 1
fi

if [[ ! -d "${REPO_PATH}" ]]; then
  echo "ERROR: repo path does not exist: ${REPO_PATH}" >&2
  exit 1
fi

run_timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
report_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
run_dir="${LOG_DIR}/runs"
run_log="${run_dir}/${run_timestamp}.log"
latest_report="${LOG_DIR}/latest-report.md"

if ! mkdir -p "${run_dir}"; then
  echo "ERROR: could not create run log directory: ${run_dir}" >&2
  echo "Try rerunning with sudo." >&2
  exit 1
fi

if ! : >"${run_log}"; then
  echo "ERROR: could not write run log: ${run_log}" >&2
  echo "Try rerunning with sudo." >&2
  exit 1
fi

if ! : >"${latest_report}"; then
  echo "ERROR: could not write latest report: ${latest_report}" >&2
  echo "Try rerunning with sudo." >&2
  exit 1
fi

exec > >(tee "${run_log}" "${latest_report}") 2>&1

echo "# AI Council Repo Check"
echo
echo "- Generated At: ${report_timestamp}"
echo "- Hostname: $(hostname)"
echo "- Repo Name: ${REPO_NAME}"
echo "- Repo Path: ${REPO_PATH}"
echo "- Run Log: ${run_log}"
echo

cd "${REPO_PATH}"

echo "## Git"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "- Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  git_status="$(git status --short)"
  if [[ -z "${git_status}" ]]; then
    echo "- Working Tree: clean"
  else
    echo "- Working Tree: dirty"
    echo
    echo "${git_status}"
    mark_error "working tree has uncommitted changes"
  fi
else
  mark_skip "git repository metadata not found"
fi

echo
echo "## Node.js"
if [[ -f package.json ]]; then
  echo "- package.json: found"
  if command -v npm >/dev/null 2>&1; then
    echo "- npm: $(command -v npm)"
    show_npm_scripts

    if command -v node >/dev/null 2>&1; then
      if has_npm_script lint; then
        run_step "npm run lint" npm run lint
      else
        mark_skip "npm script lint not found"
      fi

      if has_npm_script test; then
        run_step "npm test" npm test
      else
        mark_skip "npm script test not found"
      fi

      if has_npm_script build; then
        run_step "npm run build" npm run build
      else
        mark_skip "npm script build not found"
      fi
    else
      mark_error "node is missing, so package.json scripts cannot be inspected"
    fi
  else
    mark_error "npm is missing while package.json exists"
  fi
else
  mark_skip "package.json not found"
fi

echo
echo "## Python"
if [[ -f pyproject.toml || -f requirements.txt ]]; then
  if command -v python3 >/dev/null 2>&1; then
    echo "- python3: $(command -v python3)"
    python3 --version
    if python3 -m pytest --version >/dev/null 2>&1; then
      echo "- pytest candidate: python3 -m pytest"
      echo "- pytest execution: optional in this phase"
    else
      mark_skip "pytest is not available"
    fi
    echo "- pip install: not run in this phase"
  else
    mark_error "python3 is missing while Python project files exist"
  fi
else
  mark_skip "pyproject.toml and requirements.txt not found"
fi

echo
if [[ "${errors}" -eq 0 ]]; then
  echo "REPO_CHECK_STATUS: OK"
else
  echo "REPO_CHECK_STATUS: ERROR"
  exit 1
fi
