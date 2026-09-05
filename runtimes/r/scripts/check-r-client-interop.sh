#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TWILIC_RUST_DIR="${TWILIC_RUST_DIR:-${ROOT_DIR}/../rust}"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting R client frames..."
Rscript "${ROOT_DIR}/inst/interop/emit-rust-client-fixtures.R" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Rust client..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-client-check/Cargo.toml" < "${FIXTURES_FILE}"

echo "[interop] OK: R client -> Rust server smoke test passed"
