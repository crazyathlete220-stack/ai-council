#!/usr/bin/env bash
set -euo pipefail

REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
REPORT_FILE="${1:-${AI_COUNCIL_JOB_REPORT_FILE:-}}"

usage() {
  echo "Usage: sudo bash scripts/publish_ai_exec_result.sh <JOB_REPORT_FILE>" >&2
}

append_report_once() {
  local line="$1"
  if ! grep -Fqx -- "${line}" "${REPORT_FILE}" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${REPORT_FILE}"
  fi
}

finish_status() {
  local status="$1"
  local message="$2"

  [[ -n "${message}" ]] && echo "${message}"
  echo "PUBLISH_STATUS: ${status}"
  printf '%s\n' "PUBLISH_STATUS: ${status}" >>"${REPORT_FILE}"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root so the existing root gh authentication can publish a dedicated branch." >&2
  exit 1
fi

if [[ -z "${REPORT_FILE}" || ! -r "${REPORT_FILE}" || ! -w "${REPORT_FILE}" ]]; then
  usage
  echo "ERROR: report file must be readable and writable" >&2
  exit 1
fi

existing_publish_status="$(awk -F': ' '/^PUBLISH_STATUS:/{print $2}' "${REPORT_FILE}" | tail -n 1 | tr -d '[:space:]')"
case "${existing_publish_status}" in
  OK | NO_COMMIT | NOT_APPLICABLE)
    echo "Publication already reached a terminal state: ${existing_publish_status}"
    echo "PUBLISH_STATUS: ${existing_publish_status}"
    exit 0
    ;;
esac

job_id="$(awk -F': ' '/^- Job ID:/{print $2; exit}' "${REPORT_FILE}")"
job_type="$(awk -F': ' '/^- Job Type:/{print $2; exit}' "${REPORT_FILE}")"
repo_name="$(awk -F': ' '/^- Repo Name:/{print $2; exit}' "${REPORT_FILE}")"
commit_sha="$(awk -F': ' '/^- Commit:/{print $2; exit}' "${REPORT_FILE}" | tr -d '[:space:]')"

if [[ "${job_type}" != "ai_exec" ]]; then
  finish_status "NOT_APPLICABLE" "Result publication is only used for ai_exec jobs."
  exit 0
fi

if [[ ! "${job_id}" =~ ^[A-Za-z0-9._:-]+$ || ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  finish_status "ERROR" "Unsafe or missing job metadata."
  exit 1
fi

case "${commit_sha}" in
  "" | none | NONE | null | NULL | notcreated | "not created" | not_created)
    finish_status "NO_COMMIT" "No commit was created; no branch was published."
    exit 0
    ;;
esac

if [[ ! "${commit_sha}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  finish_status "ERROR" "The reported commit value is not a valid Git SHA."
  exit 1
fi

config_file="${REGISTRY_DIR}/${repo_name}.env"
if [[ ! -r "${config_file}" ]]; then
  finish_status "ERROR" "Workspace registry is missing: ${config_file}"
  exit 1
fi

config_owner="$(stat -c '%U' "${config_file}" 2>/dev/null || true)"
config_mode="$(stat -c '%a' "${config_file}" 2>/dev/null || true)"
if [[ "${config_owner}" != "root" || ! "${config_mode}" =~ ^[0-7]{3,4}$ ]]; then
  finish_status "ERROR" "Workspace registry ownership or mode is unsafe."
  exit 1
fi
config_mode_decimal=$((8#${config_mode}))
if (( (config_mode_decimal & 0022) != 0 )); then
  finish_status "ERROR" "Workspace registry is group/world writable."
  exit 1
fi

REPO_NAME=""
REPO_PATH=""
# shellcheck disable=SC1090
source "${config_file}"
repo_path="${REPO_PATH:-}"

if [[ "${REPO_NAME:-}" != "${repo_name}" || ! -d "${repo_path}/.git" ]]; then
  finish_status "ERROR" "Workspace registry does not resolve to a valid Git checkout."
  exit 1
fi

if ! git -c safe.directory="${repo_path}" -C "${repo_path}" cat-file -e "${commit_sha}^{commit}" 2>/dev/null; then
  finish_status "ERROR" "The reported commit is not present in the workspace."
  exit 1
fi

head_sha="$(git -c safe.directory="${repo_path}" -C "${repo_path}" rev-parse HEAD 2>/dev/null || true)"
if [[ "${head_sha}" != "${commit_sha}" ]]; then
  finish_status "ERROR" "Workspace HEAD does not match the reported commit; publication was refused."
  exit 1
fi

if [[ -n "$(git -c safe.directory="${repo_path}" -C "${repo_path}" status --porcelain 2>/dev/null)" ]]; then
  finish_status "ERROR" "Workspace is dirty after a successful job; publication was refused."
  exit 1
fi

origin_url="$(git config --file "${repo_path}/.git/config" --get remote.origin.url 2>/dev/null || true)"
repository=""
case "${origin_url}" in
  https://github.com/*)
    repository="${origin_url#https://github.com/}"
    ;;
  git@github.com:*)
    repository="${origin_url#git@github.com:}"
    ;;
  *)
    finish_status "ERROR" "Only GitHub origin repositories can be published automatically."
    exit 1
    ;;
esac
repository="${repository%.git}"

if [[ ! "${repository}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  finish_status "ERROR" "Could not derive a safe GitHub repository name from origin."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1 || ! gh auth status --hostname github.com >/dev/null 2>&1; then
  finish_status "ERROR" "Root GitHub CLI authentication is unavailable."
  exit 1
fi

if ! gh auth setup-git --hostname github.com >/dev/null 2>&1; then
  finish_status "ERROR" "GitHub CLI could not configure Git credential use."
  exit 1
fi

branch_suffix="$(printf '%s' "${job_id}" | sed -E 's/[^A-Za-z0-9._-]+/-/g')"
publish_branch="ai-council/job-${branch_suffix}"
default_branch="$(gh repo view "${repository}" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
default_branch="${default_branch:-main}"

if ! git -c safe.directory="${repo_path}" -C "${repo_path}" push origin "${commit_sha}:refs/heads/${publish_branch}"; then
  finish_status "ERROR" "Could not push the dedicated result branch."
  exit 1
fi

pr_url="$(gh pr list \
  --repo "${repository}" \
  --head "${publish_branch}" \
  --state open \
  --json url \
  --jq '.[0].url // empty' 2>/dev/null || true)"

if [[ -z "${pr_url}" ]]; then
  pr_url="$(gh pr create \
    --repo "${repository}" \
    --base "${default_branch}" \
    --head "${publish_branch}" \
    --draft \
    --title "AI Council result: ${job_id}" \
    --body "Automated AI Council result branch. Review the diff and source Issue evidence before merging. No direct push to the default branch was performed." 2>/dev/null || true)"
fi

append_report_once "- Publish Repository: ${repository}"
append_report_once "- Publish Branch: ${publish_branch}"
append_report_once "- Publish Commit: ${commit_sha}"

if [[ -z "${pr_url}" ]]; then
  finish_status "ERROR" "The result branch was pushed, but a draft pull request could not be resolved or created."
  exit 1
fi

append_report_once "- Pull Request: ${pr_url}"
finish_status "OK" "Published ${commit_sha} to ${publish_branch} and prepared a draft pull request."
