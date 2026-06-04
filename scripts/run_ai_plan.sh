#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sudo bash scripts/run_ai_plan.sh [REPO_NAME]" >&2
}

repo_name="${1:-ai-council}"
job_id="${AI_COUNCIL_JOB_ID:-manual-$(date -u +"%Y%m%dT%H%M%SZ")}"
request_source="${AI_COUNCIL_REQUEST_SOURCE:-manual}"
requested_by="${AI_COUNCIL_REQUESTED_BY:-unknown}"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log_root="${AI_COUNCIL_AI_WORKER_LOG_ROOT:-/var/log/ai-council/ai-worker}"
registry_dir="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
github_repo="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"

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

redact_sensitive() {
  sed -E \
    -e 's/([Pp]assword[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Tt]oken[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Ss]ecret[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Aa][Pp][Ii][_-]?[Kk]ey[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g'
}

repo_path="not registered"
repo_exists="no"
git_status="not checked"
git_branch="not checked"
package_files="none detected"
config_file="${registry_dir}/${repo_name}.env"

if [[ -r "${config_file}" ]]; then
  # shellcheck disable=SC1090
  source "${config_file}"
  repo_path="${REPO_PATH:-not registered}"
fi

if [[ "${repo_path}" != "not registered" && -d "${repo_path}" ]]; then
  repo_exists="yes"
  if git -C "${repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch="$(git -C "${repo_path}" branch --show-current 2>/dev/null || true)"
    git_branch="${git_branch:-detached-or-unknown}"
    if [[ -z "$(git -C "${repo_path}" status --short 2>/dev/null)" ]]; then
      git_status="clean"
    else
      git_status="dirty"
    fi
  else
    git_status="not a git repository"
  fi

  detected_files=()
  for candidate in package.json pyproject.toml requirements.txt Makefile; do
    if [[ -f "${repo_path}/${candidate}" ]]; then
      detected_files+=("${candidate}")
    fi
  done
  if [[ "${#detected_files[@]}" -gt 0 ]]; then
    package_files="${detected_files[*]}"
  fi
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

plan_dir="${log_root}/${job_id}"
plan_file="${plan_dir}/plan.md"
latest_plan="${log_root}/latest-plan.md"

install -d -m 0755 "${plan_dir}"

{
  echo "# AI Council AI Plan"
  echo
  echo "- Generated At: ${generated_at}"
  echo "- Hostname: $(hostname)"
  echo "- Job ID: ${job_id}"
  echo "- Job Type: ai_plan"
  echo "- Repo Name: ${repo_name}"
  echo "- Repo Path: ${repo_path}"
  echo "- Repo Exists: ${repo_exists}"
  echo "- Git Branch: ${git_branch}"
  echo "- Git Status: ${git_status}"
  echo "- Detected Project Files: ${package_files}"
  echo "- Request Source: ${request_source}"
  echo "- Requested By: ${requested_by}"
  echo "- Issue URL: ${issue_url:-not available}"
  echo "- Plan File: ${plan_file}"
  echo "- Latest Plan: ${latest_plan}"
  echo
  echo "## Request Snapshot"
  echo
  echo "- Issue Title: ${issue_title}"
  echo
  echo "\`\`\`text"
  printf "%s\n" "${issue_excerpt}"
  echo "\`\`\`"
  echo
  echo "## Safety Boundary"
  echo
  echo "- This job only creates a plan report."
  echo "- This job does not edit files."
  echo "- This job does not run build, test, install, push, or PR creation commands."
  echo "- Free-form Issue text is not executed as shell."
  echo "- AI CLI execution on the VPS is not confirmed in this phase."
  echo
  echo "## Suggested Plan"
  echo
  echo "1. Confirm the request scope and target repository."
  echo "2. Read the relevant repository docs and current workspace status."
  echo "3. Identify the smallest safe next job type: ai_check, ai_exec, ai_patch, or ai_pr."
  echo "4. Record expected verification commands before any future code change."
  echo "5. Ask for human approval before moving from planning to patch or PR creation."
  echo
  echo "## Suggested Verification"
  echo
  echo "- bash -n scripts/*.sh"
  echo "- bash /opt/ai-council/scripts/job_status.sh"
  echo "- sudo bash /opt/ai-council/scripts/run_repo_check.sh ${repo_name}"
  echo
  echo "## Recovery"
  echo
  echo "- Re-run ai_plan with a new Issue if the request changes."
  echo "- Use repo_check before any future ai_patch job."
  echo "- Keep secrets out of Issues and logs."
  echo
  echo "## Unconfirmed"
  echo
  echo "- VPS AI CLI execution is confirmed only after an ai_exec job reports AI_EXEC_STATUS: OK."
  echo "- Code editing on the VPS is not enabled by this job."
  echo "- Git push and PR creation from the VPS are not enabled by this job."
  echo
  echo "AI_PLAN_STATUS: OK"
} > "${plan_file}"

cp "${plan_file}" "${latest_plan}"

cat "${plan_file}"
