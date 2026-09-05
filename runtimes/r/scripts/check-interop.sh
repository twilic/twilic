#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[interop] Running R package tests (interop subset)..."
Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-interop-fixtures.R")'

bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
bash "${SCRIPT_DIR}/check-rust-server-interop.sh"

echo "[interop] OK: bidirectional smoke checks passed"
