#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Rust server frames..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with R client..."
TWILIC_R_ROOT="${ROOT_DIR}" Rscript "${ROOT_DIR}/inst/interop/decode-rust-server-fixtures.R" < "${FIXTURES_FILE}"

echo "[interop] OK: Rust server -> R client smoke test passed"
