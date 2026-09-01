#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/tests/*.sh
bash "${ROOT_DIR}/tests/test_job_lifecycle.sh"
bash "${ROOT_DIR}/tests/test_result_posting.sh"
bash "${ROOT_DIR}/tests/test_import_workspace_block.sh"
echo "tests: OK"
