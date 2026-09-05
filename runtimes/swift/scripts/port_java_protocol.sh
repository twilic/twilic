#!/bin/bash
# Copy Java protocol sources into Swift via line-oriented translation (bootstrap).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JAVA_DIR="${ROOT_DIR}/../java/src/main/java/io/twilic/internal/core"
OUT="${ROOT_DIR}/Sources/Twilic/Core"
cp "$JAVA_DIR/ProtocolCodec.java" "$OUT/ProtocolCodec.java.txt"
cp "$JAVA_DIR/ProtocolHelpers.java" "$OUT/ProtocolHelpers.java.txt"
echo "Copied Java sources for manual port reference."
