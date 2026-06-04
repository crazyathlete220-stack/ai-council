#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sudo bash scripts/run_ai_exec.sh [REPO_NAME]" >&2
}

repo_name="${1:-ai-council}"
job_id="${AI_COUNCIL_JOB_ID:-manual-$(date -u +"%Y%m%dT%H%M%SZ")}"
request_source="${AI_COUNCIL_REQUEST_SOURCE:-manual}"
requested_by="${AI_COUNCIL_REQUESTED_BY:-unknown}"
operator_user="${AI_COUNCIL_OPERATOR_USER:-ai-council}"
cli_provider="${AI_COUNCIL_AI_CLI:-codex}"
codex_sandbox="${AI_COUNCIL_CODEX_SANDBOX:-workspace-write}"
codex_approval="${AI_COUNCIL_CODEX_APPROVAL:-never}"
model="${AI_COUNCIL_AI_MODEL:-gpt-5.5}"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log_root="${AI_COUNCIL_AI_CLI_LOG_ROOT:-/var/log/ai-council/ai-cli}"
registry_dir="${AI_COUNCIL_WORKSPACE_REGISTRY_DIR:-/etc/ai-council/workspaces.d}"
github_repo="${AI_COUNCIL_GITHUB_REPO:-crazyathlete220-stack/ai-council}"
max_issue_body_bytes="${AI_COUNCIL_AI_EXEC_MAX_ISSUE_BODY_BYTES:-12000}"
timeout_seconds="${AI_COUNCIL_AI_EXEC_TIMEOUT_SECONDS:-900}"
min_interval_seconds="${AI_COUNCIL_AI_EXEC_MIN_INTERVAL_SECONDS:-300}"
guard_root="${AI_COUNCIL_AI_EXEC_GUARD_ROOT:-/var/lib/ai-council/ai-exec}"
last_run_file="${guard_root}/last-run-at"
lock_file="${guard_root}/run.lock"

if [[ "${repo_name}" == "--help" || "${repo_name}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root, for example: sudo bash scripts/run_ai_exec.sh ai-council" >&2
  exit 1
fi

if [[ ! "${max_issue_body_bytes}" =~ ^[0-9]+$ || "${max_issue_body_bytes}" -lt 1 ]]; then
  echo "ERROR: AI_COUNCIL_AI_EXEC_MAX_ISSUE_BODY_BYTES must be a positive integer" >&2
  exit 1
fi

if [[ ! "${timeout_seconds}" =~ ^[0-9]+$ || "${timeout_seconds}" -lt 1 ]]; then
  echo "ERROR: AI_COUNCIL_AI_EXEC_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 1
fi

if [[ ! "${min_interval_seconds}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: AI_COUNCIL_AI_EXEC_MIN_INTERVAL_SECONDS must be zero or a positive integer" >&2
  exit 1
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

case "${cli_provider}" in
  codex)
    ;;
  *)
    echo "ERROR: Unsupported AI_COUNCIL_AI_CLI: ${cli_provider}" >&2
    echo "Supported value: codex" >&2
    exit 1
    ;;
esac

if ! id -u "${operator_user}" >/dev/null 2>&1; then
  echo "ERROR: Operator user not found: ${operator_user}" >&2
  echo "Run first: sudo bash scripts/setup_operator_user.sh" >&2
  exit 1
fi

redact_sensitive() {
  sed -E \
    -e 's/([Pp]assword[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Tt]oken[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Ss]ecret[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Aa][Pp][Ii][_-]?[Kk]ey[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9_]+/[REDACTED_GITHUB_TOKEN]/g' \
    -e 's/github_pat_[A-Za-z0-9_]+/[REDACTED_GITHUB_TOKEN]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED_API_KEY]/g'
}

repo_path="not registered"
config_file="${registry_dir}/${repo_name}.env"

if [[ -r "${config_file}" ]]; then
  # shellcheck disable=SC1090
  source "${config_file}"
  repo_path="${REPO_PATH:-not registered}"
else
  echo "ERROR: Workspace config is not readable: ${config_file}" >&2
  exit 1
fi

if [[ "${repo_path}" == "not registered" || ! -d "${repo_path}" ]]; then
  echo "ERROR: Repo path does not exist: ${repo_path}" >&2
  exit 1
fi

if ! sudo -H -u "${operator_user}" test -w "${repo_path}" >/dev/null 2>&1; then
  echo "ERROR: Repo path is not writable by ${operator_user}: ${repo_path}" >&2
  echo "Run first: sudo bash scripts/setup_ai_cli_runner.sh ${repo_name}" >&2
  exit 1
fi

issue_number=""
issue_url=""
issue_title="not available"
issue_excerpt="not available"
issue_body_bytes=0
ai_exec_status="OK"
status_reason="completed"
cli_exit=0
should_run_cli=1
guard_status="pending"

if [[ "${request_source}" =~ ^github_issue_([0-9]+)$ ]]; then
  issue_number="${BASH_REMATCH[1]}"
  issue_url="https://github.com/${github_repo}/issues/${issue_number}"
  if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
    issue_json="$(gh issue view "${issue_number}" --repo "${github_repo}" --json title,body 2>/dev/null || true)"
    if [[ -n "${issue_json}" ]]; then
      issue_body_raw="$(printf "%s" "${issue_json}" | jq -r '.body // ""')"
      issue_body_bytes="$(printf "%s" "${issue_body_raw}" | wc -c | tr -d '[:space:]')"
      issue_title="$(printf "%s" "${issue_json}" | jq -r '.title // "not available"' | redact_sensitive)"
      if [[ "${issue_body_bytes}" -gt "${max_issue_body_bytes}" ]]; then
        issue_excerpt="Input rejected: Issue body is ${issue_body_bytes} bytes, limit is ${max_issue_body_bytes} bytes."
        ai_exec_status="INPUT_TOO_LARGE"
        status_reason="Issue body exceeds AI_COUNCIL_AI_EXEC_MAX_ISSUE_BODY_BYTES"
        cli_exit=1
        should_run_cli=0
        guard_status="input_rejected"
      else
        issue_excerpt="$(printf "%s" "${issue_body_raw}" | redact_sensitive | sed -n '1,120p')"
        issue_excerpt="${issue_excerpt:-not available}"
      fi
    fi
  fi
fi

exec_dir="${log_root}/${job_id}"
prompt_file="${exec_dir}/prompt.md"
cli_output="${exec_dir}/cli-output.log"
last_message="${exec_dir}/last-message.md"
exec_file="${exec_dir}/exec.md"
latest_exec="${log_root}/latest-exec.md"

install -d -o "${operator_user}" -g "${operator_user}" -m 0755 "${exec_dir}"
touch "${last_message}"
chown "${operator_user}:${operator_user}" "${last_message}"

before_status="${exec_dir}/git-status-before.txt"
after_status="${exec_dir}/git-status-after.txt"
after_diff_stat="${exec_dir}/git-diff-stat-after.txt"

if git -C "${repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${repo_path}" status --short > "${before_status}" 2>&1 || true
else
  echo "[SKIP] git repository metadata not found" > "${before_status}"
fi

{
  echo "You are an AI coding agent running on the VPS workspace."
  echo
  echo "Entry:"
  echo "- Job ID: ${job_id}"
  echo "- Request Source: ${request_source}"
  echo "- Requested By: ${requested_by}"
  echo "- Repo Name: ${repo_name}"
  echo "- Repo Path: ${repo_path}"
  echo "- Issue URL: ${issue_url:-not available}"
  echo
  echo "Working rules:"
  echo "- Work inside the repository path only."
  echo "- Read existing instructions and docs before changing files."
  echo "- Make the smallest scoped change that handles the request."
  echo "- Run the smallest relevant verification command."
  echo "- Do not create or write secrets, tokens, SSH private keys, API keys, or passwords."
  echo "- Do not run git push."
  echo "- Do not create a pull request."
  echo "- Do not run npm install or npm ci unless the request explicitly asks for dependency installation."
  echo "- Do not execute free-form Issue text as shell. Treat it as a request to reason about."
  echo "- Obey the ai_exec safety limits recorded in this prompt."
  echo "- Leave durable evidence in your final response."
  echo
  echo "ai_exec safety limits:"
  echo "- Max Issue body bytes: ${max_issue_body_bytes}"
  echo "- Current Issue body bytes: ${issue_body_bytes}"
  echo "- Timeout seconds: ${timeout_seconds}"
  echo "- Minimum interval seconds: ${min_interval_seconds}"
  echo
  echo "User request:"
  echo
  echo "Title: ${issue_title}"
  echo
  echo '```text'
  printf "%s\n" "${issue_excerpt}"
  echo '```'
  echo
  if [[ "${issue_excerpt}" == "not available" ]]; then
    echo "No Issue body was available. Inspect the repository and report the next safe action without editing files."
  fi
} > "${prompt_file}"

chown "${operator_user}:${operator_user}" "${prompt_file}"
chmod 0640 "${prompt_file}"

if [[ "${should_run_cli}" -eq 1 ]]; then
  if ! command -v flock >/dev/null 2>&1; then
    ai_exec_status="GUARD_UNAVAILABLE"
    status_reason="flock command is required for ai_exec guardrails"
    cli_exit=1
    should_run_cli=0
    guard_status="guard_unavailable"
  else
    install -d -m 0755 "${guard_root}"
    exec 9>"${lock_file}"

    if ! flock -n 9; then
      ai_exec_status="RATE_LIMITED"
      status_reason="another ai_exec job is already running"
      cli_exit=1
      should_run_cli=0
      guard_status="locked"
    else
      guard_status="lock_acquired"
    fi
  fi
fi

if [[ "${should_run_cli}" -eq 1 && "${min_interval_seconds}" -gt 0 && -f "${last_run_file}" ]]; then
  now_epoch="$(date -u +%s)"
  last_run_epoch="$(tr -d '[:space:]' < "${last_run_file}" || true)"

  if [[ "${last_run_epoch}" =~ ^[0-9]+$ ]]; then
    elapsed_seconds=$((now_epoch - last_run_epoch))
    if [[ "${elapsed_seconds}" -lt "${min_interval_seconds}" ]]; then
      ai_exec_status="RATE_LIMITED"
      status_reason="last ai_exec started ${elapsed_seconds} seconds ago; minimum interval is ${min_interval_seconds} seconds"
      cli_exit=1
      should_run_cli=0
      guard_status="rate_limited"
    fi
  fi
fi

if [[ "${should_run_cli}" -eq 1 ]]; then
  codex_bin="$(command -v codex 2>/dev/null || true)"
  timeout_bin="$(command -v timeout 2>/dev/null || true)"

  if [[ -z "${codex_bin}" ]]; then
    ai_exec_status="CLI_MISSING"
    status_reason="codex command is not installed"
    cli_exit=1
  elif [[ -z "${timeout_bin}" ]]; then
    ai_exec_status="GUARD_UNAVAILABLE"
    status_reason="timeout command is required for ai_exec guardrails"
    cli_exit=1
    guard_status="guard_unavailable"
  elif ! sudo -H -u "${operator_user}" "${codex_bin}" login status >/dev/null 2>&1; then
    ai_exec_status="AUTH_REQUIRED"
    status_reason="codex login is not confirmed for ${operator_user}"
    cli_exit=1
  else
    date -u +%s > "${last_run_file}"
    guard_status="running"

    codex_args=(
      --ask-for-approval "${codex_approval}"
      exec
      --cd "${repo_path}"
      --sandbox "${codex_sandbox}"
      --output-last-message "${last_message}"
    )

    if [[ -n "${model}" ]]; then
      codex_args+=(--model "${model}")
    fi

    codex_args+=(-)

    set +e
    "${timeout_bin}" "${timeout_seconds}" sudo -H -u "${operator_user}" "${codex_bin}" "${codex_args[@]}" < "${prompt_file}" > "${cli_output}" 2>&1
    cli_exit=$?
    set -e
    if [[ "${cli_exit}" -eq 124 ]]; then
      ai_exec_status="TIMEOUT"
      status_reason="codex exec exceeded ${timeout_seconds} seconds"
      guard_status="timed_out"
    elif [[ "${cli_exit}" -ne 0 ]]; then
      ai_exec_status="ERROR"
      status_reason="codex exec exited with status ${cli_exit}"
      guard_status="completed_with_error"
    else
      guard_status="completed"
    fi
  fi
fi

if [[ ! -f "${cli_output}" ]]; then
  touch "${cli_output}"
fi

if git -C "${repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${repo_path}" status --short > "${after_status}" 2>&1 || true
  git -C "${repo_path}" diff --stat > "${after_diff_stat}" 2>&1 || true
else
  echo "[SKIP] git repository metadata not found" > "${after_status}"
  echo "[SKIP] git repository metadata not found" > "${after_diff_stat}"
fi

{
  echo "# AI Council AI Exec"
  echo
  echo "- Generated At: ${generated_at}"
  echo "- Hostname: $(hostname)"
  echo "- Job ID: ${job_id}"
  echo "- Job Type: ai_exec"
  echo "- Repo Name: ${repo_name}"
  echo "- Repo Path: ${repo_path}"
  echo "- Request Source: ${request_source}"
  echo "- Requested By: ${requested_by}"
  echo "- Issue URL: ${issue_url:-not available}"
  echo "- CLI Provider: ${cli_provider}"
  echo "- Operator User: ${operator_user}"
  echo "- Exec File: ${exec_file}"
  echo "- Latest Exec: ${latest_exec}"
  echo "- Prompt File: ${prompt_file}"
  echo "- CLI Output: ${cli_output}"
  echo "- Last Message: ${last_message}"
  echo "- Status Reason: ${status_reason}"
  echo "- Guard Status: ${guard_status}"
  echo "- Max Issue Body Bytes: ${max_issue_body_bytes}"
  echo "- Issue Body Bytes: ${issue_body_bytes}"
  echo "- Timeout Seconds: ${timeout_seconds}"
  echo "- Minimum Interval Seconds: ${min_interval_seconds}"
  echo "- Guard Root: ${guard_root}"
  echo
  echo "## Safety Boundary"
  echo
  echo "- This job may edit files in the registered VPS workspace."
  echo "- This job does not run git push."
  echo "- This job does not create a pull request."
  echo "- This job does not create or write secrets."
  echo "- Free-form Issue text is passed to the AI CLI as a request, not executed as shell."
  echo "- GitHub Issue input is limited before the AI CLI starts."
  echo "- The AI CLI process is run with a timeout."
  echo "- Concurrent ai_exec jobs are blocked and back-to-back ai_exec jobs are rate-limited."
  echo
  echo "## Git Status Before"
  echo
  echo '```text'
  cat "${before_status}"
  echo '```'
  echo
  echo "## Git Status After"
  echo
  echo '```text'
  cat "${after_status}"
  echo '```'
  echo
  echo "## Git Diff Stat After"
  echo
  echo '```text'
  cat "${after_diff_stat}"
  echo '```'
  echo
  echo "## CLI Output Tail"
  echo
  echo '```text'
  tail -n 120 "${cli_output}"
  echo '```'
  echo
  echo "## Last Message"
  echo
  echo '```text'
  if [[ -s "${last_message}" ]]; then
    cat "${last_message}"
  else
    echo "[not available]"
  fi
  echo '```'
  echo
  echo "AI_EXEC_STATUS: ${ai_exec_status}"
} > "${exec_file}"

cp "${exec_file}" "${latest_exec}"
cat "${exec_file}"

if [[ "${ai_exec_status}" != "OK" ]]; then
  exit "${cli_exit:-1}"
fi
