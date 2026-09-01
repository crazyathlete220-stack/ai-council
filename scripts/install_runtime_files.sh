#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

APP_DIR="${AI_COUNCIL_APP_DIR:-/opt/ai-council}"
UNIT_DIR="${AI_COUNCIL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
MODE="${1:-install}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${AI_COUNCIL_RUNTIME_MANIFEST:-${REPO_DIR}/config/runtime-manifest.txt}"

case "${MODE}" in
  install) ;;
  --check | check) MODE="check" ;;
  *)
    echo "ERROR: usage: bash scripts/install_runtime_files.sh [--check]" >&2
    exit 1
    ;;
esac

if [[ ! -r "${MANIFEST}" || -L "${MANIFEST}" ]]; then
  echo "ERROR: readable non-symlink runtime manifest is required: ${MANIFEST}" >&2
  exit 1
fi

manifest_size="$(wc -c < "${MANIFEST}" | tr -d '[:space:]')"
if [[ ! "${manifest_size}" =~ ^[0-9]+$ || "${manifest_size}" -gt 65536 ]]; then
  echo "ERROR: runtime manifest is unexpectedly large" >&2
  exit 1
fi

declare -A seen_paths=()
manifest_types=()
manifest_paths=()
manifest_modes=()
entry_count=0
script_count=0
doc_count=0
unit_count=0
config_count=0
root_count=0
line_number=0

while IFS='|' read -r entry_type repository_path file_mode extra || [[ -n "${entry_type}${repository_path}${file_mode}${extra}" ]]; do
  line_number=$((line_number + 1))
  [[ "${entry_type}" =~ ^[[:space:]]*$ || "${entry_type}" =~ ^[[:space:]]*# ]] && continue

  if [[ -n "${extra}" || -z "${repository_path}" || -z "${file_mode}" ]]; then
    echo "ERROR: invalid runtime manifest fields at line ${line_number}" >&2
    exit 1
  fi
  if [[ ! "${entry_type}" =~ ^(root|config|doc|script|unit)$ ]]; then
    echo "ERROR: unsupported runtime manifest type at line ${line_number}: ${entry_type}" >&2
    exit 1
  fi
  if [[ ! "${repository_path}" =~ ^[A-Za-z0-9._/-]+$ || "${repository_path}" == /* || "${repository_path}" == *".."* || "${repository_path}" == *"//"* ]]; then
    echo "ERROR: unsafe runtime manifest path at line ${line_number}" >&2
    exit 1
  fi
  if [[ ! "${file_mode}" =~ ^0(644|755)$ ]]; then
    echo "ERROR: unsupported runtime manifest mode at line ${line_number}: ${file_mode}" >&2
    exit 1
  fi
  if [[ -n "${seen_paths[${repository_path}]:-}" ]]; then
    echo "ERROR: duplicate runtime manifest path: ${repository_path}" >&2
    exit 1
  fi

  case "${entry_type}" in
    root)
      [[ "${repository_path}" != */* ]] || { echo "ERROR: root entry must be a repository-root file: ${repository_path}" >&2; exit 1; }
      root_count=$((root_count + 1))
      ;;
    config)
      [[ "${repository_path}" == config/* ]] || { echo "ERROR: config entry must be under config/: ${repository_path}" >&2; exit 1; }
      config_count=$((config_count + 1))
      ;;
    doc)
      [[ "${repository_path}" == docs/* ]] || { echo "ERROR: doc entry must be under docs/: ${repository_path}" >&2; exit 1; }
      doc_count=$((doc_count + 1))
      ;;
    script)
      [[ "${repository_path}" == scripts/* ]] || { echo "ERROR: script entry must be under scripts/: ${repository_path}" >&2; exit 1; }
      [[ "${file_mode}" == "0755" ]] || { echo "ERROR: script must use mode 0755: ${repository_path}" >&2; exit 1; }
      script_count=$((script_count + 1))
      ;;
    unit)
      [[ "${repository_path}" == systemd/* ]] || { echo "ERROR: unit entry must be under systemd/: ${repository_path}" >&2; exit 1; }
      unit_count=$((unit_count + 1))
      ;;
  esac

  if [[ ! -f "${REPO_DIR}/${repository_path}" ]]; then
    echo "ERROR: runtime manifest source is missing: ${repository_path}" >&2
    exit 1
  fi

  seen_paths["${repository_path}"]=1
  manifest_types+=("${entry_type}")
  manifest_paths+=("${repository_path}")
  manifest_modes+=("${file_mode}")
  entry_count=$((entry_count + 1))
done < "${MANIFEST}"

if [[ "${entry_count}" -lt 1 || "${script_count}" -lt 1 || "${unit_count}" -lt 1 ]]; then
  echo "ERROR: runtime manifest is incomplete" >&2
  exit 1
fi

bash -n "${REPO_DIR}"/scripts/*.sh

echo "RUNTIME_MANIFEST_SOURCE_STATUS: OK"
echo "RUNTIME_MANIFEST_ENTRIES: ${entry_count}"
echo "RUNTIME_MANIFEST_ROOT_FILES: ${root_count}"
echo "RUNTIME_MANIFEST_CONFIG_FILES: ${config_count}"
echo "RUNTIME_MANIFEST_DOCS: ${doc_count}"
echo "RUNTIME_MANIFEST_SCRIPTS: ${script_count}"
echo "RUNTIME_MANIFEST_UNITS: ${unit_count}"

if [[ "${MODE}" == "check" ]]; then
  echo "INSTALL_RUNTIME_FILES_STATUS: CHECK_OK"
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: runtime installation requires root" >&2
  exit 1
fi

install -d -m 0755 "${APP_DIR}" "${APP_DIR}/config" "${APP_DIR}/docs" "${APP_DIR}/scripts" "${APP_DIR}/systemd" "${UNIT_DIR}"

for ((index=0; index<entry_count; index++)); do
  entry_type="${manifest_types[${index}]}"
  repository_path="${manifest_paths[${index}]}"
  file_mode="${manifest_modes[${index}]}"
  basename="${repository_path##*/}"

  case "${entry_type}" in
    root) destination="${APP_DIR}/${basename}" ;;
    config) destination="${APP_DIR}/config/${basename}" ;;
    doc) destination="${APP_DIR}/docs/${basename}" ;;
    script) destination="${APP_DIR}/scripts/${basename}" ;;
    unit) destination="${APP_DIR}/systemd/${basename}" ;;
  esac

  install -m "${file_mode}" "${REPO_DIR}/${repository_path}" "${destination}"
  if [[ "${entry_type}" == "unit" ]]; then
    install -m "${file_mode}" "${REPO_DIR}/${repository_path}" "${UNIT_DIR}/${basename}"
  fi
done

mismatch_count=0
for ((index=0; index<entry_count; index++)); do
  entry_type="${manifest_types[${index}]}"
  repository_path="${manifest_paths[${index}]}"
  basename="${repository_path##*/}"

  case "${entry_type}" in
    root) destination="${APP_DIR}/${basename}" ;;
    config) destination="${APP_DIR}/config/${basename}" ;;
    doc) destination="${APP_DIR}/docs/${basename}" ;;
    script) destination="${APP_DIR}/scripts/${basename}" ;;
    unit) destination="${APP_DIR}/systemd/${basename}" ;;
  esac

  cmp -s "${REPO_DIR}/${repository_path}" "${destination}" || mismatch_count=$((mismatch_count + 1))
  if [[ "${entry_type}" == "unit" ]]; then
    cmp -s "${REPO_DIR}/${repository_path}" "${UNIT_DIR}/${basename}" || mismatch_count=$((mismatch_count + 1))
  fi
done

echo "RUNTIME_MANIFEST_COPY_MISMATCHES: ${mismatch_count}"
if [[ "${mismatch_count}" -eq 0 ]]; then
  echo "INSTALL_RUNTIME_FILES_STATUS: OK"
  exit 0
fi

echo "INSTALL_RUNTIME_FILES_STATUS: ERROR" >&2
exit 1
