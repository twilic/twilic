#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Rust server frames..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Lua client..."
(
  cd "${ROOT_DIR}"
  export LUA_PATH="src/?.lua;src/?/init.lua;;"
  lua bin/decode-rust-server-fixtures.lua
) < "${FIXTURES_FILE}"

echo "[interop] OK: Rust server -> Lua client smoke test passed"
