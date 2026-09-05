#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Rust server frames..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Zig client..."
zig run --dep twilic -Mroot="${ROOT_DIR}/scripts/decode-rust-server-fixtures.zig" -Mtwilic="${ROOT_DIR}/src/lib.zig" < "${FIXTURES_FILE}"

echo "[interop] OK: Rust server -> Zig client smoke test passed"
