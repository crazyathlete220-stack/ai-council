#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sudo bash scripts/run_ai_check.sh [REPO_NAME]" >&2
}

repo_name="${1:-ai-council}"
job_id="${AI_COUNCIL_JOB_ID:-manual-$(date -u +"%Y%m%dT%H%M%SZ")}"
request_source="${AI_COUNCIL_REQUEST_SOURCE:-manual}"
requested_by="${AI_COUNCIL_REQUESTED_BY:-unknown}"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log_root="${AI_COUNCIL_AI_WORKER_LOG_ROOT:-/var/log/ai-council/ai-worker}"
registry_dir="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
github_repo="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
errors=0
warnings=0

if [[ "${repo_name}" == "--help" || "${repo_name}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Unsafe REPO_NAME: ${repo_name}" >&2
  exit 1
fi

if [[ ! "${job_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "ERROR: Unsafe AI_COUNCIL_JOB_ID: ${job_id}" >&2
  exit 1
fi

if [[ ! "${request_source}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  echo "ERROR: Unsafe AI_COUNCIL_REQUEST_SOURCE: ${request_source}" >&2
  exit 1
fi

if [[ ! "${requested_by}" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
  echo "ERROR: Unsafe AI_COUNCIL_REQUESTED_BY: ${requested_by}" >&2
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

redact_sensitive() {
  sed -E \
    -e 's/([Pp]assword[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Tt]oken[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Ss]ecret[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Aa][Pp][Ii][_-]?[Kk]ey[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g'
}

check_required_ai_council_files() {
  local missing=0
  local required_files=(
    "README.md"
    "docs/vps-ai-worker.md"
    "scripts/bootstrap_vps.sh"
    "scripts/create_job.sh"
    "scripts/run_job_once.sh"
    "scripts/run_ai_plan.sh"
    "scripts/run_ai_check.sh"
  )

  for path in "${required_files[@]}"; do
    if [[ -f "${repo_path}/${path}" ]]; then
      echo "- ${path}: found"
    else
      echo "- ${path}: missing"
      missing=1
    fi
  done

  return "${missing}"
}

check_shell_syntax() {
  if compgen -G "${repo_path}/scripts/*.sh" >/dev/null; then
    (cd "${repo_path}" && bash -n scripts/*.sh)
  else
    echo "No scripts/*.sh files found."
    return 0
  fi
}

show_package_scripts_without_running() {
  if [[ ! -f "${repo_path}/package.json" ]]; then
    mark_skip "package.json not found"
    return 0
  fi

  echo "- package.json: found"
  if command -v node >/dev/null 2>&1; then
    (cd "${repo_path}" && node -e 'const fs = require("fs"); const pkg = JSON.parse(fs.readFileSync("package.json", "utf8")); const scripts = Object.keys(pkg.scripts || {}); if (scripts.length === 0) { console.log("- npm scripts: none"); } else { for (const script of scripts) console.log(`- npm script: ${script}`); }')
  else
    mark_warning "node is missing, so package.json scripts were not inspected"
  fi

  echo "- npm install: not run"
  echo "- npm ci: not run"
  echo "- npm script execution: not run by ai_check"
}

repo_path="not registered"
repo_exists="no"
git_status="not checked"
git_branch="not checked"
config_file="${registry_dir}/${repo_name}.env"

if [[ -r "${config_file}" ]]; then
  # shellcheck disable=SC1090
  source "${config_file}"
  repo_path="${REPO_PATH:-not registered}"
else
  mark_error "workspace config is not readable: ${config_file}"
fi

if [[ "${repo_path}" != "not registered" && -d "${repo_path}" ]]; then
  repo_exists="yes"
fi

issue_number=""
issue_url=""
issue_title="not available"
issue_excerpt="not available"

if [[ "${request_source}" =~ ^github_issue_([0-9]+)$ ]]; then
  issue_number="${BASH_REMATCH[1]}"
  issue_url="https://github.com/${github_repo}/issues/${issue_number}"
  if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
    issue_json="$(gh issue view "${issue_number}" --repo "${github_repo}" --json title,body 2>/dev/null || true)"
    if [[ -n "${issue_json}" ]]; then
      issue_title="$(printf "%s" "${issue_json}" | jq -r '.title // "not available"')"
      issue_excerpt="$(printf "%s" "${issue_json}" | jq -r '.body // ""' | redact_sensitive | sed -n '1,40p')"
      issue_excerpt="${issue_excerpt:-not available}"
    fi
  fi
fi

check_dir="${log_root}/${job_id}"
check_file="${check_dir}/check.md"
latest_check="${log_root}/latest-check.md"

install -d -m 0755 "${check_dir}"

{
  echo "# AI Council AI Check"
  echo
  echo "- Generated At: ${generated_at}"
  echo "- Hostname: $(hostname)"
  echo "- Job ID: ${job_id}"
  echo "- Job Type: ai_check"
  echo "- Repo Name: ${repo_name}"
  echo "- Repo Path: ${repo_path}"
  echo "- Repo Exists: ${repo_exists}"
  echo "- Request Source: ${request_source}"
  echo "- Requested By: ${requested_by}"
  echo "- Issue URL: ${issue_url:-not available}"
  echo "- Check File: ${check_file}"
  echo "- Latest Check: ${latest_check}"
  echo
  echo "## Request Snapshot"
  echo
  echo "- Issue Title: ${issue_title}"
  echo
  echo '```text'
  printf "%s\n" "${issue_excerpt}"
  echo '```'
  echo
  echo "## Safety Boundary"
  echo
  echo "- This job runs bounded checks only."
  echo "- This job does not edit files."
  echo "- This job does not run install commands."
  echo "- This job does not push branches or create PRs."
  echo "- Free-form Issue text is not executed as shell."
  echo "- AI CLI execution on the VPS is not confirmed in this phase."
  echo

  if [[ "${repo_exists}" != "yes" ]]; then
    mark_error "repo path does not exist: ${repo_path}"
  else
    echo "## Workspace"
    echo
    echo "- config: ${config_file}"
    echo "- repo path: ${repo_path}"

    echo
    echo "## Git"
    if command -v git >/dev/null 2>&1 && git -C "${repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git_branch="$(git -C "${repo_path}" branch --show-current 2>/dev/null || true)"
      git_branch="${git_branch:-detached-or-unknown}"
      git_status="$(git -C "${repo_path}" status --short 2>/dev/null || true)"
      echo "- Branch: ${git_branch}"
      if [[ -z "${git_status}" ]]; then
        echo "- Working Tree: clean"
      else
        echo "- Working Tree: dirty"
        echo
        printf "%s\n" "${git_status}"
        mark_warning "working tree has uncommitted changes"
      fi
      run_step "git diff --check" git -C "${repo_path}" diff --check
    else
      mark_skip "git repository metadata not found"
    fi

    if [[ "${repo_name}" == "ai-council" ]]; then
      run_step "required ai-council files" check_required_ai_council_files
    fi

    run_step "bash -n scripts/*.sh" check_shell_syntax

    echo
    echo "## Package Scripts"
    show_package_scripts_without_running
  fi

  echo
  echo "## Result"
  echo
  echo "- Errors: ${errors}"
  echo "- Warnings: ${warnings}"

  if [[ "${errors}" -eq 0 ]]; then
    echo
    echo "AI_CHECK_STATUS: OK"
  else
    echo
    echo "AI_CHECK_STATUS: ERROR"
  fi
} > "${check_file}" 2>&1

cp "${check_file}" "${latest_check}"
cat "${check_file}"

if [[ "${errors}" -eq 0 ]]; then
  exit 0
fi

exit 1
