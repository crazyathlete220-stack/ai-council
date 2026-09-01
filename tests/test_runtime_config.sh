#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

validator="${ROOT_DIR}/scripts/validate_runtime_config.sh"
template="${ROOT_DIR}/config/runtime.env.example"

valid="${tmp}/runtime.env"
cp "${template}" "${valid}"
chmod 0644 "${valid}"
valid_output="$(bash "${validator}" "${valid}")"
printf '%s\n' "${valid_output}"
grep -q '^RUNTIME_CONFIG_STATUS: OK$' <<< "${valid_output}"
grep -q '^RUNTIME_CONFIG_REPO: crazyathlete220-stack/ai-council-private$' <<< "${valid_output}"
grep -q '^RUNTIME_CONFIG_LABEL: vps-job$' <<< "${valid_output}"

expect_failure() {
  local file="$1"
  local pattern="$2"
  local output=""
  local status=0

  set +e
  output="$(bash "${validator}" "${file}" 2>&1)"
  status=$?
  set -e

  printf '%s\n' "${output}"
  test "${status}" -ne 0
  grep -q "${pattern}" <<< "${output}"
}

unknown="${tmp}/unknown.env"
cp "${template}" "${unknown}"
printf '\nAI_COUNCIL_GITHUB_TOKEN=never-store-secrets-here\n' >> "${unknown}"
chmod 0644 "${unknown}"
expect_failure "${unknown}" 'unsupported runtime config key: AI_COUNCIL_GITHUB_TOKEN'

duplicate="${tmp}/duplicate.env"
cp "${template}" "${duplicate}"
printf '\nAI_COUNCIL_GITHUB_REPO=owner/other\n' >> "${duplicate}"
chmod 0644 "${duplicate}"
expect_failure "${duplicate}" 'duplicate runtime config key: AI_COUNCIL_GITHUB_REPO'

relative="${tmp}/relative.env"
sed 's#AI_COUNCIL_JOB_ROOT=/var/lib/ai-council/jobs#AI_COUNCIL_JOB_ROOT=var/lib/ai-council/jobs#' "${template}" > "${relative}"
chmod 0644 "${relative}"
expect_failure "${relative}" 'AI_COUNCIL_JOB_ROOT must be a normalized absolute path'

writable="${tmp}/writable.env"
cp "${template}" "${writable}"
chmod 0666 "${writable}"
expect_failure "${writable}" 'must not be group- or world-writable'

preflight_output="$(bash "${ROOT_DIR}/scripts/deploy_runtime.sh" --check)"
printf '%s\n' "${preflight_output}"
grep -q '^DEPLOY_RUNTIME_PREFLIGHT: OK$' <<< "${preflight_output}"
grep -q '^PREFLIGHT_SCRIPTS: 28$' <<< "${preflight_output}"
grep -q '^PREFLIGHT_DOCS: 14$' <<< "${preflight_output}"
grep -q '^PREFLIGHT_UNITS: 4$' <<< "${preflight_output}"

echo "test_runtime_config: OK"
