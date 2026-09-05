#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[interop] Running Dart interop unit tests..."
(cd "${ROOT_DIR}" && dart test test/interop_fixtures_test.dart)

bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
bash "${SCRIPT_DIR}/check-dart-client-interop.sh"

echo "[interop] OK: bidirectional smoke checks passed"
