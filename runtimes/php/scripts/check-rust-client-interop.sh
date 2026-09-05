#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting PHP server frames..."
(cd "${ROOT_DIR}" && php bin/emit-rust-client-fixtures.php) > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Rust client..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-client-check/Cargo.toml" < "${FIXTURES_FILE}"

echo "[interop] OK: PHP server -> Rust client smoke test passed"
