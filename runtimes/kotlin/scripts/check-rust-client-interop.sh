#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURES_FILE="$(mktemp)"
trap 'rm -f "${FIXTURES_FILE}"' EXIT

echo "[interop] Emitting Kotlin server frames..."
(cd "${ROOT_DIR}" && ./gradlew -q emitRustClientFixtures --no-daemon) > "${FIXTURES_FILE}"

echo "[interop] Decoding frames with Rust client..."
cargo run --quiet --manifest-path "${ROOT_DIR}/scripts/rust-client-check/Cargo.toml" < "${FIXTURES_FILE}"

echo "[interop] OK: Kotlin server -> Rust client smoke test passed"
