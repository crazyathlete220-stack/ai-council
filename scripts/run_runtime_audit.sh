#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

TARGET_REPO="${1:-ai-council-private}"
ISSUE_CSV="${2:-}"
EXPECTED_RUNTIME_COMMIT="${3:-}"
EXPECTED_PRIVATE_COMMIT="${4:-}"

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
REGISTRY_DIR="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
JOB_ROOT="${AI_COUNCIL_JOB_ROOT:-/var/lib/ai-council/jobs}"
BRIDGE_STATE_ROOT="${AI_COUNCIL_GITHUB_BRIDGE_STATE_ROOT:-/var/lib/ai-council/github-bridge}"
PUBLIC_WORKSPACE_OVERRIDE="${AI_COUNCIL_PUBLIC_WORKSPACE:-}"
BRIDGE_SERVICE="${AI_COUNCIL_GITHUB_BRIDGE_SERVICE_NAME:-ai-council-github-bridge.service}"
BRIDGE_TIMER="${AI_COUNCIL_GITHUB_BRIDGE_TIMER_NAME:-ai-council-github-bridge.timer}"
RUNNER_SERVICE="${AI_COUNCIL_JOB_RUNNER_SERVICE_NAME:-ai-council-job-runner.service}"
RUNNER_TIMER="${AI_COUNCIL_JOB_RUNNER_TIMER_NAME:-ai-council-job-runner.timer}"

generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
findings=0
unknowns=0

usage() {
  cat >&2 <<'EOF_USAGE'
Usage: bash scripts/run_runtime_audit.sh [TARGET_REPO] [ISSUE_CSV] [EXPECTED_RUNTIME_COMMIT] [EXPECTED_PRIVATE_COMMIT]

Examples:
  bash scripts/run_runtime_audit.sh ai-council-private 91,98,101
  bash scripts/run_runtime_audit.sh ai-council-private 91 2ed27b67 d8c50012
EOF_USAGE
}

if [[ "${TARGET_REPO}" == "--help" || "${TARGET_REPO}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ ! "${TARGET_REPO}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: unsafe target repo: ${TARGET_REPO}" >&2
  exit 1
fi
if [[ -n "${ISSUE_CSV}" && ! "${ISSUE_CSV}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
  echo "ERROR: ISSUE_CSV must be comma-separated numeric issue IDs" >&2
  exit 1
fi
if [[ -n "${EXPECTED_RUNTIME_COMMIT}" && ! "${EXPECTED_RUNTIME_COMMIT}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  echo "ERROR: EXPECTED_RUNTIME_COMMIT must be a Git commit SHA" >&2
  exit 1
fi
if [[ -n "${EXPECTED_PRIVATE_COMMIT}" && ! "${EXPECTED_PRIVATE_COMMIT}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  echo "ERROR: EXPECTED_PRIVATE_COMMIT must be a Git commit SHA" >&2
  exit 1
fi

mark_finding() {
  findings=$((findings + 1))
}

mark_unknown() {
  unknowns=$((unknowns + 1))
}

count_files() {
  local directory="$1"
  local pattern="${2:-*}"
  if [[ ! -d "${directory}" ]]; then
    printf '0'
    return 0
  fi
  find "${directory}" -maxdepth 1 -type f -name "${pattern}" -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]'
}

read_config_value() {
  local config_file="$1"
  local wanted_key="$2"
  awk -F= -v wanted="${wanted_key}" '
    $1 == wanted {
      sub(/^[^=]*=/, "")
      gsub(/^['"'"']|['"'"']$/, "")
      print
      exit
    }
  ' "${config_file}" 2>/dev/null
}

git_head() {
  local directory="$1"
  if [[ -d "${directory}" ]] && git -C "${directory}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${directory}" rev-parse HEAD 2>/dev/null || true
  fi
}

commit_relation() {
  local directory="$1"
  local expected="$2"
  local head=""

  if [[ -z "${expected}" ]]; then
    printf 'NOT_REQUESTED'
    return 0
  fi
  head="$(git_head "${directory}")"
  if [[ -z "${head}" ]]; then
    printf 'UNKNOWN'
    return 0
  fi
  if [[ "${head}" == "${expected}" || "${head}" == "${expected}"* ]]; then
    printf 'EXACT'
    return 0
  fi
  if git -C "${directory}" cat-file -e "${expected}^{commit}" 2>/dev/null; then
    if git -C "${directory}" merge-base --is-ancestor "${expected}" "${head}" 2>/dev/null; then
      printf 'CONTAINS'
    else
      printf 'DIFFERENT'
    fi
  else
    printf 'OBJECT_MISSING'
  fi
}

unit_active() {
  local unit="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'UNKNOWN'
    return 0
  fi
  systemctl is-active "${unit}" 2>/dev/null || true
}

unit_enabled() {
  local unit="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'UNKNOWN'
    return 0
  fi
  systemctl is-enabled "${unit}" 2>/dev/null || true
}

unit_execstart() {
  local unit="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'UNKNOWN'
    return 0
  fi
  systemctl show "${unit}" -p ExecStart --value 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' || true
}

journal_error_summary() {
  local unit="$1"
  local logs=""
  local matches=""
  local count="0"
  local latest="NONE"

  if ! command -v journalctl >/dev/null 2>&1; then
    printf 'UNKNOWN|UNKNOWN'
    return 0
  fi

  logs="$(journalctl -u "${unit}" -n 50 --no-pager -o short-iso 2>/dev/null || true)"
  matches="$(printf '%s\n' "${logs}" | grep -Ei 'failed|failure|error|auth|permission|workspace|race|out[-_ ]?of[-_ ]?hours' || true)"
  if [[ -n "${matches}" ]]; then
    count="$(printf '%s\n' "${matches}" | awk 'NF {count++} END {print count+0}')"
    latest="$(printf '%s\n' "${matches}" | awk 'NF {value=$1} END {print value}')"
    latest="${latest:-UNKNOWN}"
  fi
  printf '%s|%s' "${count}" "${latest}"
}

issue_state() {
  local issue="$1"
  local imported_marker="${BRIDGE_STATE_ROOT}/imported/issue-${issue}.imported"
  local blocked_marker="${BRIDGE_STATE_ROOT}/blocked/issue-${issue}.blocked"
  local rejected_marker="${BRIDGE_STATE_ROOT}/rejected/issue-${issue}.rejected"
  local job_id=""
  local state="UNKNOWN"
  local posted="NO"

  if [[ -r "${blocked_marker}" ]]; then
    state="BLOCKED"
  elif [[ -r "${rejected_marker}" ]]; then
    state="REJECTED"
  elif [[ -r "${imported_marker}" ]]; then
    job_id="$(read_config_value "${imported_marker}" "JOB_ID")"
    if [[ -n "${job_id}" && "${job_id}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      if [[ -f "${JOB_ROOT}/queue/${job_id}.job" ]]; then
        state="QUEUED"
      elif [[ -f "${JOB_ROOT}/active/${job_id}.job" ]]; then
        state="ACTIVE"
      elif [[ -f "${JOB_ROOT}/done/${job_id}.job" ]]; then
        state="DONE"
      elif [[ -f "${JOB_ROOT}/failed/${job_id}.job" ]]; then
        state="FAILED"
      else
        state="IMPORTED_ORPHAN"
      fi
      if compgen -G "${BRIDGE_STATE_ROOT}/posted/${job_id}-*.posted" >/dev/null; then
        posted="YES"
      fi
    else
      state="IMPORTED_INVALID_JOB_ID"
    fi
  fi

  printf '%s|%s|%s' "${state}" "${job_id:-NONE}" "${posted}"
}

required_runtime_files=(
  "scripts/import_github_jobs.sh"
  "scripts/run_job_once.sh"
  "scripts/run_job_cycle.sh"
  "scripts/report_job_result.sh"
  "scripts/post_job_result_to_github.sh"
  "scripts/requeue_github_issue.sh"
  "scripts/deploy_runtime.sh"
  "scripts/run_runtime_audit.sh"
  "docs/durable-job-lifecycle.md"
)

public_config="${REGISTRY_DIR}/ai-council.env"
public_workspace="${PUBLIC_WORKSPACE_OVERRIDE}"
if [[ -z "${public_workspace}" && -r "${public_config}" ]]; then
  public_workspace="$(read_config_value "${public_config}" "REPO_PATH")"
fi
public_workspace="${public_workspace:-/opt/ai-workspaces/ai-council}"

private_config="${REGISTRY_DIR}/${TARGET_REPO}.env"
private_path=""
private_config_status="MISSING"
if [[ -r "${private_config}" ]]; then
  private_config_status="EXISTS"
  private_path="$(read_config_value "${private_config}" "REPO_PATH")"
elif [[ -e "${private_config}" ]]; then
  private_config_status="UNREADABLE"
fi
private_path="${private_path:-/opt/ai-workspaces/${TARGET_REPO}}"

app_real="$(readlink -f "${APP_DIR}" 2>/dev/null || true)"
public_real="$(readlink -f "${public_workspace}" 2>/dev/null || true)"
app_git="NO"
app_head=""
public_git="NO"
public_head=""
app_workspace_relation="UNKNOWN"

if [[ -n "$(git_head "${APP_DIR}")" ]]; then
  app_git="YES"
  app_head="$(git_head "${APP_DIR}")"
fi
if [[ -n "$(git_head "${public_workspace}")" ]]; then
  public_git="YES"
  public_head="$(git_head "${public_workspace}")"
fi
if [[ -n "${app_real}" && -n "${public_real}" ]]; then
  if [[ "${app_real}" == "${public_real}" ]]; then
    app_workspace_relation="SAME"
  else
    app_workspace_relation="DIFFERENT"
  fi
fi

runtime_present_count=0
runtime_match_count=0
runtime_missing_count=0
runtime_source_missing_count=0
runtime_file_lines=()
for relative in "${required_runtime_files[@]}"; do
  app_file="${APP_DIR}/${relative}"
  source_file="${public_workspace}/${relative}"
  safe_name="$(printf '%s' "${relative}" | tr '/.-' '___' | tr '[:lower:]' '[:upper:]')"
  status=""

  if [[ ! -f "${app_file}" ]]; then
    status="MISSING"
    runtime_missing_count=$((runtime_missing_count + 1))
  else
    runtime_present_count=$((runtime_present_count + 1))
    if [[ ! -f "${source_file}" ]]; then
      status="SOURCE_MISSING"
      runtime_source_missing_count=$((runtime_source_missing_count + 1))
    elif cmp -s "${app_file}" "${source_file}"; then
      status="MATCH"
      runtime_match_count=$((runtime_match_count + 1))
    else
      status="DIFFERENT"
    fi
  fi
  runtime_file_lines+=("RUNTIME_FILE_${safe_name}: ${status}")
done

merged_runtime_present="PARTIAL"
if [[ "${runtime_missing_count}" -eq "${#required_runtime_files[@]}" ]]; then
  merged_runtime_present="NO"
elif [[ "${runtime_match_count}" -eq "${#required_runtime_files[@]}" ]]; then
  merged_runtime_present="YES"
elif [[ "${runtime_present_count}" -eq "${#required_runtime_files[@]}" && "${runtime_source_missing_count}" -gt 0 ]]; then
  merged_runtime_present="UNKNOWN"
fi

bridge_timer_active="$(unit_active "${BRIDGE_TIMER}")"
bridge_timer_enabled="$(unit_enabled "${BRIDGE_TIMER}")"
runner_timer_active="$(unit_active "${RUNNER_TIMER}")"
runner_timer_enabled="$(unit_enabled "${RUNNER_TIMER}")"
bridge_service_active="$(unit_active "${BRIDGE_SERVICE}")"
runner_service_active="$(unit_active "${RUNNER_SERVICE}")"
bridge_execstart="$(unit_execstart "${BRIDGE_SERVICE}")"
runner_execstart="$(unit_execstart "${RUNNER_SERVICE}")"

bridge_mode="UNKNOWN"
if [[ "${bridge_execstart}" == *"/scripts/import_github_jobs.sh"* ]]; then
  bridge_mode="IMPORT_ONLY"
elif [[ "${bridge_execstart}" == *"github_bridge_timer.sh"* ]]; then
  bridge_mode="LEGACY_COMBINED"
fi

runner_mode="UNKNOWN"
if [[ "${runner_execstart}" == *"/scripts/run_job_cycle.sh"* ]]; then
  runner_mode="DURABLE_CYCLE"
elif [[ "${runner_execstart}" == *"/scripts/run_job_once.sh"* ]]; then
  runner_mode="LEGACY_ONCE"
fi

private_workspace_status="MISSING"
private_head=""
private_origin_status="UNKNOWN"
if [[ -d "${private_path}" ]]; then
  if git -C "${private_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    private_workspace_status="OK"
    private_head="$(git_head "${private_path}")"
    if git -C "${private_path}" remote get-url origin >/dev/null 2>&1; then
      private_origin_status="CONFIGURED"
    else
      private_origin_status="MISSING"
    fi
  else
    private_workspace_status="INVALID_GIT"
  fi
fi

sudo_status="NG"
if [[ "${EUID}" -eq 0 ]]; then
  sudo_status="ROOT"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo_status="OK"
fi

gh_auth="NG"
if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
  gh_auth="OK"
fi

queue_count="$(count_files "${JOB_ROOT}/queue" '*.job')"
active_count="$(count_files "${JOB_ROOT}/active" '*.job')"
done_count="$(count_files "${JOB_ROOT}/done" '*.job')"
failed_count="$(count_files "${JOB_ROOT}/failed" '*.job')"
imported_count="$(count_files "${BRIDGE_STATE_ROOT}/imported" '*.imported')"
blocked_count="$(count_files "${BRIDGE_STATE_ROOT}/blocked" '*.blocked')"
rejected_count="$(count_files "${BRIDGE_STATE_ROOT}/rejected" '*.rejected')"
posted_count="$(count_files "${BRIDGE_STATE_ROOT}/posted" '*.posted')"

stash_count="0"
stash_heads="NONE"
if [[ "${public_git}" == "YES" ]]; then
  stash_count="$(git -C "${public_workspace}" stash list --format='%gd' 2>/dev/null | awk 'NF {count++} END {print count+0}')"
  stash_heads="$(git -C "${public_workspace}" stash list --format='%gd' 2>/dev/null | head -n 3 | paste -sd ',' -)"
  stash_heads="${stash_heads:-NONE}"
fi

bridge_journal="$(journal_error_summary "${BRIDGE_SERVICE}")"
runner_journal="$(journal_error_summary "${RUNNER_SERVICE}")"
bridge_error_count="${bridge_journal%%|*}"
bridge_error_latest="${bridge_journal#*|}"
runner_error_count="${runner_journal%%|*}"
runner_error_latest="${runner_journal#*|}"

if [[ "${merged_runtime_present}" != "YES" ]]; then mark_finding; fi
if [[ "${bridge_timer_active}" != "active" || "${bridge_timer_enabled}" != "enabled" ]]; then mark_finding; fi
if [[ "${runner_timer_active}" != "active" || "${runner_timer_enabled}" != "enabled" ]]; then mark_finding; fi
if [[ "${bridge_mode}" != "IMPORT_ONLY" ]]; then mark_finding; fi
if [[ "${runner_mode}" != "DURABLE_CYCLE" ]]; then mark_finding; fi
if [[ "${private_config_status}" != "EXISTS" ]]; then mark_finding; fi
if [[ "${private_workspace_status}" != "OK" ]]; then mark_finding; fi
if [[ "${gh_auth}" != "OK" ]]; then mark_finding; fi
if [[ "${active_count}" -gt 1 ]]; then mark_finding; fi
if [[ "${failed_count}" -gt 0 ]]; then mark_finding; fi
if [[ "${blocked_count}" -gt 0 ]]; then mark_finding; fi
if [[ "${app_workspace_relation}" == "UNKNOWN" ]]; then mark_unknown; fi
if [[ "${bridge_error_count}" == "UNKNOWN" || "${runner_error_count}" == "UNKNOWN" ]]; then mark_unknown; fi

runtime_commit_relation="$(commit_relation "${public_workspace}" "${EXPECTED_RUNTIME_COMMIT}")"
private_commit_relation="$(commit_relation "${private_path}" "${EXPECTED_PRIVATE_COMMIT}")"
if [[ "${runtime_commit_relation}" == "DIFFERENT" || "${runtime_commit_relation}" == "OBJECT_MISSING" || "${runtime_commit_relation}" == "UNKNOWN" ]]; then
  [[ -z "${EXPECTED_RUNTIME_COMMIT}" ]] || mark_finding
fi
if [[ "${private_commit_relation}" == "DIFFERENT" || "${private_commit_relation}" == "OBJECT_MISSING" || "${private_commit_relation}" == "UNKNOWN" ]]; then
  [[ -z "${EXPECTED_PRIVATE_COMMIT}" ]] || mark_finding
fi

recovery_status="READY"
next_action="Run a fresh bounded E2E check."
if [[ "${merged_runtime_present}" != "YES" || "${bridge_mode}" != "IMPORT_ONLY" || "${runner_mode}" != "DURABLE_CYCLE" ]]; then
  recovery_status="BLOCKED_RUNTIME_DEPLOY"
  next_action="Update the public ai-council workspace to the reviewed main commit, then run deploy_runtime.sh as root."
elif [[ "${private_workspace_status}" != "OK" || "${private_config_status}" != "EXISTS" ]]; then
  recovery_status="BLOCKED_PRIVATE_WORKSPACE"
  next_action="Place the private repository through an approved credential path, register it, then requeue the target Issue."
elif [[ "${gh_auth}" != "OK" ]]; then
  recovery_status="BLOCKED_GITHUB_AUTH"
  next_action="Repair GitHub CLI authentication without exposing the token, then rerun the audit."
elif [[ "${bridge_timer_active}" != "active" || "${runner_timer_active}" != "active" ]]; then
  recovery_status="BLOCKED_TIMERS"
  next_action="Inspect the timer unit state and journal before starting or enabling anything."
elif [[ "${failed_count}" -gt 0 || "${blocked_count}" -gt 0 ]]; then
  recovery_status="READY_WITH_STALE_JOBS"
  next_action="Review failed/blocked markers and use requeue_github_issue.sh only for validated targets."
fi

cat <<EOF_HEADER
# AI Council Runtime Audit

- Generated At: ${generated_at}
- User: $(whoami 2>/dev/null || printf 'UNKNOWN')
- UID: ${EUID}
- PWD: $(pwd)
- Target Repo: ${TARGET_REPO}
- Expected Runtime Commit: ${EXPECTED_RUNTIME_COMMIT:-NOT_REQUESTED}
- Expected Private Commit: ${EXPECTED_PRIVATE_COMMIT:-NOT_REQUESTED}

## Privilege and GitHub

SUDO_N: ${sudo_status}
GH_AUTH: ${gh_auth}

## Runtime placement

APP_DIR: ${APP_DIR}
APP_DIR_REALPATH: ${app_real:-UNKNOWN}
APP_DIR_GIT: ${app_git}
APP_DIR_HEAD: ${app_head:-NONE}
PUBLIC_WORKSPACE: ${public_workspace}
PUBLIC_WORKSPACE_REALPATH: ${public_real:-UNKNOWN}
PUBLIC_WORKSPACE_GIT: ${public_git}
PUBLIC_WORKSPACE_HEAD: ${public_head:-NONE}
APP_WORKSPACE_RELATION: ${app_workspace_relation}
EXPECTED_RUNTIME_RELATION: ${runtime_commit_relation}
MERGED_RUNTIME_PRESENT: ${merged_runtime_present}
RUNTIME_FILES_PRESENT: ${runtime_present_count}/${#required_runtime_files[@]}
RUNTIME_FILES_MATCH: ${runtime_match_count}/${#required_runtime_files[@]}
EOF_HEADER

printf '%s\n' "${runtime_file_lines[@]}"

cat <<EOF_SYSTEMD

## systemd

BRIDGE_SERVICE_ACTIVE: ${bridge_service_active:-UNKNOWN}
BRIDGE_EXECSTART: ${bridge_execstart:-UNKNOWN}
BRIDGE_RUNTIME_MODE: ${bridge_mode}
BRIDGE_TIMER: ${bridge_timer_active:-UNKNOWN}, ${bridge_timer_enabled:-UNKNOWN}
RUNNER_SERVICE_ACTIVE: ${runner_service_active:-UNKNOWN}
RUNNER_EXECSTART: ${runner_execstart:-UNKNOWN}
RUNNER_RUNTIME_MODE: ${runner_mode}
RUNNER_TIMER: ${runner_timer_active:-UNKNOWN}, ${runner_timer_enabled:-UNKNOWN}

## Private workspace

PRIVATE_CONFIG: ${private_config_status}
PRIVATE_CONFIG_PATH: ${private_config}
PRIVATE_WORKSPACE: ${private_workspace_status}
PRIVATE_WORKSPACE_PATH: ${private_path}
PRIVATE_HEAD: ${private_head:-NONE}
PRIVATE_EXPECTED_RELATION: ${private_commit_relation}
PRIVATE_ORIGIN: ${private_origin_status}

## Job and bridge state

QUEUE_COUNT: ${queue_count}
ACTIVE_COUNT: ${active_count}
DONE_COUNT: ${done_count}
FAILED_COUNT: ${failed_count}
IMPORTED_COUNT: ${imported_count}
BLOCKED_COUNT: ${blocked_count}
REJECTED_COUNT: ${rejected_count}
POSTED_COUNT: ${posted_count}
EOF_SYSTEMD

if [[ -n "${ISSUE_CSV}" ]]; then
  IFS=',' read -r -a audit_issues <<< "${ISSUE_CSV}"
  echo
  echo "## Requested Issue states"
  echo
  for issue in "${audit_issues[@]}"; do
    state_data="$(issue_state "${issue}")"
    state="${state_data%%|*}"
    remainder="${state_data#*|}"
    job_id="${remainder%%|*}"
    posted="${remainder#*|}"
    echo "ISSUE_${issue}_STATE: ${state}"
    echo "ISSUE_${issue}_JOB_ID: ${job_id}"
    echo "ISSUE_${issue}_POSTED: ${posted}"
  done
fi

cat <<EOF_FOOTER

## Stash and recent errors

STASH_COUNT: ${stash_count}
STASH_HEADS: ${stash_heads}
BRIDGE_RECENT_ERROR_MATCHES: ${bridge_error_count}
BRIDGE_LATEST_ERROR_TIME: ${bridge_error_latest}
RUNNER_RECENT_ERROR_MATCHES: ${runner_error_count}
RUNNER_LATEST_ERROR_TIME: ${runner_error_latest}

## Result

RUNTIME_AUDIT_FINDINGS: ${findings}
RUNTIME_AUDIT_UNKNOWNS: ${unknowns}
RUNTIME_RECOVERY_STATUS: ${recovery_status}
NEXT_SAFE_ACTION: ${next_action}
RUNTIME_AUDIT_STATUS: COMPLETE
EOF_FOOTER
