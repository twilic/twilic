#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[interop] Running Lua interop unit tests..."
(
  cd "${ROOT_DIR}"
  export LUA_PATH="src/?.lua;src/?/init.lua;${LUA_PATH:-;;}"
  busted spec/twilic/core/interop_fixtures_spec.lua
)

bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
bash "${SCRIPT_DIR}/check-lua-client-interop.sh"

echo "[interop] OK: bidirectional smoke checks passed"
