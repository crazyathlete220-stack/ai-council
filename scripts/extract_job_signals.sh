#!/usr/bin/env bash
set -euo pipefail

REPORT_FILE="${1:-}"

if [[ -z "${REPORT_FILE}" || ! -r "${REPORT_FILE}" ]]; then
  echo "ERROR: readable job report path is required" >&2
  exit 1
fi

awk '
  BEGIN {
    na=split("Generated At|Hostname|Job ID|Job Type|Repo Name|Repo Path|Request Source|Requested By|Job Log|Job Report|Plan File|Latest Plan|Check File|Latest Check|Exec File|Latest Exec|CLI Provider|Result Marker|Status Reason|Guard Status|Commit Status|Commit|Changed File Count|Changed File Bytes|Failed Change Stash|Allowed Hours JST|Current Hour JST|Max Per Hour|Hourly Count Before Run|Max Per Day|Daily Count Before Run|Deferred Reason|Retry Not Before Epoch|Defer Count|Max Defer Count", a, "|")
    for (i=1; i<=na; i++) allowed_meta[a[i]]=1

    nb=split("REPO_CHECK_STATUS|WORKSPACE_SUMMARY_STATUS|AI_PLAN_STATUS|AI_CHECK_STATUS|AI_EXEC_STATUS|JOB_RUNNER_STATUS", b, "|")
    for (i=1; i<=nb; i++) allowed_status[b[i]]=1

    nc=split("AUDIT_PROFILE|AUDIT_PROFILE_STATUS|RUNTIME_AUDIT_ERROR|SUDO_N|GH_AUTH|APP_DIR|APP_DIR_REALPATH|APP_DIR_GIT|APP_DIR_HEAD|PUBLIC_WORKSPACE|PUBLIC_WORKSPACE_REALPATH|PUBLIC_WORKSPACE_GIT|PUBLIC_WORKSPACE_HEAD|APP_WORKSPACE_RELATION|EXPECTED_RUNTIME_RELATION|MERGED_RUNTIME_PRESENT|RUNTIME_FILES_PRESENT|RUNTIME_FILES_MATCH|BRIDGE_SERVICE_ACTIVE|BRIDGE_EXECSTART|BRIDGE_RUNTIME_MODE|BRIDGE_TIMER|RUNNER_SERVICE_ACTIVE|RUNNER_EXECSTART|RUNNER_RUNTIME_MODE|RUNNER_TIMER|PRIVATE_CONFIG|PRIVATE_CONFIG_PATH|PRIVATE_WORKSPACE|PRIVATE_WORKSPACE_PATH|PRIVATE_HEAD|PRIVATE_EXPECTED_RELATION|PRIVATE_ORIGIN|QUEUE_COUNT|ACTIVE_COUNT|DONE_COUNT|FAILED_COUNT|IMPORTED_COUNT|BLOCKED_COUNT|REJECTED_COUNT|POSTED_COUNT|STASH_COUNT|STASH_HEADS|BRIDGE_RECENT_ERROR_MATCHES|BRIDGE_LATEST_ERROR_TIME|RUNNER_RECENT_ERROR_MATCHES|RUNNER_LATEST_ERROR_TIME|RUNTIME_AUDIT_FINDINGS|RUNTIME_AUDIT_UNKNOWNS|RUNTIME_RECOVERY_STATUS|NEXT_SAFE_ACTION|RUNTIME_AUDIT_STATUS", c, "|")
    for (i=1; i<=nc; i++) allowed_audit[c[i]]=1

    in_audit=0
  }

  /^RUNTIME_AUDIT_OUTPUT_BEGIN$/ {
    in_audit=1
    next
  }

  /^RUNTIME_AUDIT_OUTPUT_END$/ {
    in_audit=0
    next
  }

  in_audit {
    if ($0 ~ /^[A-Z0-9_]+: /) {
      key=$0
      sub(/:.*/, "", key)
      if ((allowed_audit[key] || key ~ /^ISSUE_[0-9]+_(STATE|JOB_ID|POSTED)$/) && !seen["a:" key]++) {
        print
      }
    }
    next
  }

  /^- / {
    key=$0
    sub(/^- /, "", key)
    sub(/:.*/, "", key)
    if (allowed_meta[key] && !seen["m:" key]++) print
    next
  }

  /^[A-Z_]+: / {
    key=$0
    sub(/:.*/, "", key)
    if (allowed_status[key]) status[key]=$0
  }

  END {
    for (i=1; i<=nb; i++) if (status[b[i]] != "") print status[b[i]]
  }
' "${REPORT_FILE}"
