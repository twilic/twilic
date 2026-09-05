#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[interop] Running Go interop unit tests..."
(cd "${ROOT_DIR}" && go test ./internal/core -run '^TestInteropFixtures_' -count=1)

bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
bash "${SCRIPT_DIR}/check-go-client-interop.sh"

echo "[interop] OK: bidirectional smoke checks passed"
