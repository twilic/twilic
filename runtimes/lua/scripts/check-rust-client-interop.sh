#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Lua server frames..."
(
  cd "${ROOT_DIR}"
  export LUA_PATH="src/?.lua;src/?/init.lua;;"
  lua bin/emit-rust-client-fixtures.lua
) > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Rust client..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-client-check/Cargo.toml" < "${FIXTURES_FILE}"

echo "[interop] OK: Lua server -> Rust client smoke test passed"
