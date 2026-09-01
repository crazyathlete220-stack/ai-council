#!/usr/bin/env bash
set -u

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
LOG_DIR="${AI_COUNCIL_GITHUB_BRIDGE_LOG_DIR:-/var/log/ai-council/github-bridge}"
cycle_stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
cycle_log="${LOG_DIR}/bridge-cycle-${cycle_stamp}-$$.log"
latest_cycle="${LOG_DIR}/latest-cycle.log"

mkdir -p "${LOG_DIR}"

run_cycle() {
  local import_rc=0
  local job_cycle_rc=0

  echo "AI Council GitHub bridge cycle"
  echo "Generated At: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo

  set +e
  bash "${APP_DIR}/scripts/import_github_jobs.sh"
  import_rc=$?
  set -e

  echo
  echo "IMPORT_GITHUB_JOBS_EXIT: ${import_rc}"

  if [[ "${import_rc}" -ne 0 ]]; then
    echo "GITHUB_BRIDGE_CYCLE_STATUS: IMPORT_ERROR"
    return 1
  fi

  echo
  set +e
  bash "${APP_DIR}/scripts/run_job_cycle.sh"
  job_cycle_rc=$?
  set -e

  echo
  echo "RUN_JOB_CYCLE_EXIT: ${job_cycle_rc}"

  if [[ "${job_cycle_rc}" -ne 0 ]]; then
    echo "GITHUB_BRIDGE_CYCLE_STATUS: JOB_ERROR_REPORTED"
    return 1
  fi

  echo "GITHUB_BRIDGE_CYCLE_STATUS: OK"
}

set +e
run_cycle > >(tee "${cycle_log}" "${latest_cycle}") 2>&1
cycle_rc=$?
set -e

exit "${cycle_rc}"
