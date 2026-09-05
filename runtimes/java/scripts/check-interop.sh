#!/usr/bin/env bash
set -euo pipefail
"$(dirname "$0")/check-rust-client-interop.sh"
"$(dirname "$0")/check-java-client-interop.sh"
echo "[interop] OK: bidirectional smoke checks passed"
