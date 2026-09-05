#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"
TWILIC_RUST_DIR="${TWILIC_RUST_DIR:-${ROOT_DIR}/../rust}"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Rust server frames..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with C++ client..."
"${BUILD_DIR}/decode_rust_server_fixtures" < "${FIXTURES_FILE}"

echo "[interop] OK: Rust server -> C++ client smoke test passed"
