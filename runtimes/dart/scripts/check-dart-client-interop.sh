#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUST_DIR="${TWILIC_RUST_DIR:-${ROOT_DIR}/../rust}"
if [[ ! -f "${RUST_DIR}/Cargo.toml" ]]; then
  echo "[interop] skip: twilic-rust not found at ${RUST_DIR}"
  exit 0
fi

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Rust server frames..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-server-fixtures/Cargo.toml" > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Dart client..."
(cd "${ROOT_DIR}" && dart run bin/decode_rust_server_fixtures.dart) < "${FIXTURES_FILE}"

echo "[interop] OK: Rust server -> Dart client smoke test passed"
