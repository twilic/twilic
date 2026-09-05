#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" ]]; then
  echo "[interop] Skipping Rust server -> Elixir client (scripts/rust-server-fixtures not found)"
  exit 0
fi

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Rust server frames..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Elixir client..."
(cd "${ROOT_DIR}" && mix twilic.decode_rust_server_fixtures --no-compile) < "${FIXTURES_FILE}"

echo "[interop] OK: Rust server -> Elixir client smoke test passed"
