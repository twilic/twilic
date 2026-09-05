#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TWILIC_RUST_DIR="${TWILIC_RUST_DIR:-$(cd "${ROOT_DIR}/../rust" && pwd)}"
export TWILIC_RUST_DIR

CONTROL_DECODE="${ROOT_DIR}/scripts/control-stream-decode"
if [[ -f "${CONTROL_DECODE}/Cargo.toml" ]]; then
  echo "[interop] Building control-stream-decode helper..."
  cargo build --quiet --release --manifest-path "${CONTROL_DECODE}/Cargo.toml"
  export TWILIC_CONTROL_STREAM_DECODE="${CONTROL_DECODE}/target/release/control_stream_decode"
fi

echo "[interop] Compiling Elixir..."
(cd "${ROOT_DIR}" && mix compile 2>/dev/null)

echo "[interop] Running Elixir interop unit tests..."
(cd "${ROOT_DIR}" && mix test test/interop_fixtures_test.exs)

bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
bash "${SCRIPT_DIR}/check-elixir-client-interop.sh"

echo "[interop] OK: bidirectional smoke checks passed"
