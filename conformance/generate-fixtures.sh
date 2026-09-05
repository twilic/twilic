#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cargo run --quiet --locked \
  --manifest-path "${SCRIPT_DIR}/rust-server-fixtures/Cargo.toml" \
  > "${SCRIPT_DIR}/fixtures/interop-v1.txt"
