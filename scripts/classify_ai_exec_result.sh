#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

message_file="${1:-}"

if [[ -z "${message_file}" || ! -r "${message_file}" ]]; then
  echo "AI_EXEC_RESULT_CONTRACT_STATUS: INDETERMINATE"
  echo "AI_EXEC_RESULT_MARKER: MISSING"
  echo "AI_EXEC_RESULT_REASON: last_message_not_readable"
  exit 22
fi

marker_count="$(grep -Ec '^AI_EXEC_RESULT: (SUCCESS|BLOCKED|FAILED)$' "${message_file}" || true)"
marker_line="$(grep -E '^AI_EXEC_RESULT: (SUCCESS|BLOCKED|FAILED)$' "${message_file}" | tail -n 1 || true)"
last_nonempty="$(awk 'NF {line=$0} END {print line}' "${message_file}")"

if [[ "${marker_count}" -eq 0 ]]; then
  echo "AI_EXEC_RESULT_CONTRACT_STATUS: INDETERMINATE"
  echo "AI_EXEC_RESULT_MARKER: MISSING"
  echo "AI_EXEC_RESULT_REASON: required_marker_missing"
  exit 22
fi

if [[ "${marker_count}" -ne 1 ]]; then
  echo "AI_EXEC_RESULT_CONTRACT_STATUS: INDETERMINATE"
  echo "AI_EXEC_RESULT_MARKER: MULTIPLE"
  echo "AI_EXEC_RESULT_REASON: marker_count_${marker_count}"
  exit 22
fi

if [[ "${last_nonempty}" != "${marker_line}" ]]; then
  echo "AI_EXEC_RESULT_CONTRACT_STATUS: INDETERMINATE"
  echo "AI_EXEC_RESULT_MARKER: NOT_FINAL"
  echo "AI_EXEC_RESULT_REASON: marker_must_be_final_nonempty_line"
  exit 22
fi

marker="${marker_line#AI_EXEC_RESULT: }"
case "${marker}" in
  SUCCESS)
    echo "AI_EXEC_RESULT_CONTRACT_STATUS: VERIFIED_SUCCESS"
    echo "AI_EXEC_RESULT_MARKER: SUCCESS"
    echo "AI_EXEC_RESULT_REASON: explicit_success"
    exit 0
    ;;
  BLOCKED)
    echo "AI_EXEC_RESULT_CONTRACT_STATUS: VERIFIED_BLOCKED"
    echo "AI_EXEC_RESULT_MARKER: BLOCKED"
    echo "AI_EXEC_RESULT_REASON: explicit_blocked"
    exit 20
    ;;
  FAILED)
    echo "AI_EXEC_RESULT_CONTRACT_STATUS: VERIFIED_FAILED"
    echo "AI_EXEC_RESULT_MARKER: FAILED"
    echo "AI_EXEC_RESULT_REASON: explicit_failed"
    exit 21
    ;;
esac

echo "AI_EXEC_RESULT_CONTRACT_STATUS: INDETERMINATE"
echo "AI_EXEC_RESULT_MARKER: INVALID"
echo "AI_EXEC_RESULT_REASON: unsupported_marker"
exit 22
