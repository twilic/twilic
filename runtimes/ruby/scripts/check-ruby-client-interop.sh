#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Rust server frames..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Ruby client..."
(cd "${ROOT_DIR}" && bundle exec ruby -Ilib "${ROOT_DIR}/scripts/decode-rust-server-fixtures/main.rb") < "${FIXTURES_FILE}"

echo "[interop] OK: Rust server -> Ruby client smoke test passed"
