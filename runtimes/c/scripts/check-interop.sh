#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"

cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}"
cmake --build "${BUILD_DIR}"
ctest --test-dir "${BUILD_DIR}" --output-on-failure

bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
bash "${SCRIPT_DIR}/check-c-client-interop.sh"

echo "[interop] OK: bidirectional smoke checks passed"
