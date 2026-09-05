#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[interop] Running Kotlin interop unit tests..."
(cd "${ROOT_DIR}" && ./gradlew -q test --tests io.twilic.internal.core.InteropFixturesTest --no-daemon)

bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
bash "${SCRIPT_DIR}/check-kotlin-client-interop.sh"

echo "[interop] OK: bidirectional smoke checks passed"
