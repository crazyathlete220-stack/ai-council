#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
UNIT_DIR="${AI_COUNCIL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
RUNTIME_CONFIG="${AI_COUNCIL_RUNTIME_CONFIG:-/etc/ai-council/runtime.env}"
PUBLIC_WORKSPACE_OVERRIDE="${AI_COUNCIL_PUBLIC_WORKSPACE:-}"

config_value() {
  local file="$1"
  local wanted="$2"
  awk -F= -v wanted="${wanted}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == wanted {
      sub(/^[^=]*=/, "")
      gsub(/^['"'"']|['"'"']$/, "")
      print
      exit
    }
  ' "${file}" 2>/dev/null
}

runtime_recovery_status="READY"
manifest_status="ERROR"
source_validation="UNKNOWN"
entries=0
targets=0
matched=0
missing=0
different=0
mode_mismatch=0
source_missing=0
unmanaged=0
first_problem="NONE"
public_workspace="${PUBLIC_WORKSPACE_OVERRIDE}"

if [[ -z "${public_workspace}" && -r "${RUNTIME_CONFIG}" ]]; then
  registry_dir="$(config_value "${RUNTIME_CONFIG}" AI_COUNCIL_WORKSPACE_REGISTRY_DIR)"
  public_config="${registry_dir}/ai-council.env"
  if [[ -r "${public_config}" ]]; then
    public_workspace="$(config_value "${public_config}" REPO_PATH)"
  fi
fi
public_workspace="${public_workspace:-/opt/ai-workspaces/ai-council}"
source_manifest="${public_workspace}/config/runtime-manifest.txt"
installed_manifest="${APP_DIR}/config/runtime-manifest.txt"
source_installer="${public_workspace}/scripts/install_runtime_files.sh"

if [[ ! -r "${source_manifest}" || -L "${source_manifest}" ]]; then
  runtime_recovery_status="BLOCKED_RUNTIME_MANIFEST_SOURCE"
  first_problem="source_manifest_missing"
elif [[ ! -r "${source_installer}" ]]; then
  runtime_recovery_status="BLOCKED_RUNTIME_MANIFEST_INSTALLER"
  first_problem="source_installer_missing"
else
  set +e
  source_check_output="$(AI_COUNCIL_RUNTIME_MANIFEST="${source_manifest}" bash "${source_installer}" --check 2>&1)"
  source_check_status=$?
  set -e
  if [[ "${source_check_status}" -eq 0 ]]; then
    source_validation="OK"
  else
    source_validation="ERROR"
    runtime_recovery_status="BLOCKED_RUNTIME_MANIFEST_INVALID"
    first_problem="source_manifest_validation_failed"
  fi
fi

if [[ "${source_validation}" == "OK" ]]; then
  declare -A expected_app_paths=()

  while IFS='|' read -r entry_type repository_path file_mode extra || [[ -n "${entry_type}${repository_path}${file_mode}${extra}" ]]; do
    [[ "${entry_type}" =~ ^[[:space:]]*$ || "${entry_type}" =~ ^[[:space:]]*# ]] && continue
    entries=$((entries + 1))
    basename="${repository_path##*/}"

    case "${entry_type}" in
      root) app_target="${APP_DIR}/${basename}" ;;
      config) app_target="${APP_DIR}/config/${basename}" ;;
      doc) app_target="${APP_DIR}/docs/${basename}" ;;
      script) app_target="${APP_DIR}/scripts/${basename}" ;;
      unit) app_target="${APP_DIR}/systemd/${basename}" ;;
      *)
        source_missing=$((source_missing + 1))
        [[ "${first_problem}" == "NONE" ]] && first_problem="unsupported_type"
        continue
        ;;
    esac

    expected_app_paths["${app_target}"]=1
    source_file="${public_workspace}/${repository_path}"
    targets=$((targets + 1))

    if [[ ! -f "${source_file}" ]]; then
      source_missing=$((source_missing + 1))
      [[ "${first_problem}" == "NONE" ]] && first_problem="source_missing:${repository_path}"
    elif [[ ! -f "${app_target}" ]]; then
      missing=$((missing + 1))
      [[ "${first_problem}" == "NONE" ]] && first_problem="target_missing:${repository_path}"
    elif ! cmp -s "${source_file}" "${app_target}"; then
      different=$((different + 1))
      [[ "${first_problem}" == "NONE" ]] && first_problem="target_different:${repository_path}"
    else
      matched=$((matched + 1))
    fi

    if [[ -f "${app_target}" ]]; then
      actual_mode="$(stat -c '%a' "${app_target}" 2>/dev/null || true)"
      expected_mode="${file_mode#0}"
      if [[ -n "${actual_mode}" && "${actual_mode}" != "${expected_mode}" ]]; then
        mode_mismatch=$((mode_mismatch + 1))
        [[ "${first_problem}" == "NONE" ]] && first_problem="mode_mismatch:${repository_path}"
      fi
    fi

    if [[ "${entry_type}" == "unit" ]]; then
      unit_target="${UNIT_DIR}/${basename}"
      targets=$((targets + 1))
      if [[ ! -f "${source_file}" ]]; then
        :
      elif [[ ! -f "${unit_target}" ]]; then
        missing=$((missing + 1))
        [[ "${first_problem}" == "NONE" ]] && first_problem="unit_missing:${repository_path}"
      elif ! cmp -s "${source_file}" "${unit_target}"; then
        different=$((different + 1))
        [[ "${first_problem}" == "NONE" ]] && first_problem="unit_different:${repository_path}"
      else
        matched=$((matched + 1))
      fi
      if [[ -f "${unit_target}" ]]; then
        actual_mode="$(stat -c '%a' "${unit_target}" 2>/dev/null || true)"
        expected_mode="${file_mode#0}"
        if [[ -n "${actual_mode}" && "${actual_mode}" != "${expected_mode}" ]]; then
          mode_mismatch=$((mode_mismatch + 1))
          [[ "${first_problem}" == "NONE" ]] && first_problem="unit_mode_mismatch:${repository_path}"
        fi
      fi
    fi
  done < "${source_manifest}"

  for directory in "${APP_DIR}" "${APP_DIR}/config" "${APP_DIR}/docs" "${APP_DIR}/scripts" "${APP_DIR}/systemd"; do
    [[ -d "${directory}" ]] || continue
    while IFS= read -r installed_file; do
      [[ -n "${installed_file}" ]] || continue
      if [[ -z "${expected_app_paths[${installed_file}]:-}" ]]; then
        unmanaged=$((unmanaged + 1))
      fi
    done < <(find "${directory}" -maxdepth 1 -type f -print 2>/dev/null)
  done

  if [[ "${source_missing}" -eq 0 && "${missing}" -eq 0 && "${different}" -eq 0 && "${mode_mismatch}" -eq 0 && "${matched}" -eq "${targets}" ]]; then
    manifest_status="OK"
    if [[ "${unmanaged}" -gt 0 ]]; then
      runtime_recovery_status="READY_WITH_UNMANAGED_RUNTIME_FILES"
    else
      runtime_recovery_status="READY"
    fi
  else
    manifest_status="PARTIAL"
    runtime_recovery_status="BLOCKED_RUNTIME_DEPLOY"
  fi
fi

cat <<EOF_REPORT
RUNTIME_MANIFEST_SOURCE: ${source_manifest}
RUNTIME_MANIFEST_INSTALLED: ${installed_manifest}
RUNTIME_MANIFEST_SOURCE_VALIDATION: ${source_validation}
RUNTIME_MANIFEST_STATUS: ${manifest_status}
RUNTIME_MANIFEST_ENTRIES: ${entries}
RUNTIME_MANIFEST_TARGETS: ${targets}
RUNTIME_MANIFEST_MATCHED: ${matched}
RUNTIME_MANIFEST_MISSING: ${missing}
RUNTIME_MANIFEST_DIFFERENT: ${different}
RUNTIME_MANIFEST_MODE_MISMATCH: ${mode_mismatch}
RUNTIME_MANIFEST_SOURCE_MISSING: ${source_missing}
RUNTIME_MANIFEST_UNMANAGED_APP_FILES: ${unmanaged}
RUNTIME_MANIFEST_FIRST_PROBLEM: ${first_problem}
RUNTIME_MANIFEST_RECOVERY_STATUS: ${runtime_recovery_status}
RUNTIME_MANIFEST_AUDIT_STATUS: COMPLETE
EOF_REPORT

if [[ "${manifest_status}" == "OK" ]]; then
  exit 0
fi
exit 1
