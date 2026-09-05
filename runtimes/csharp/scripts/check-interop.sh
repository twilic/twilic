#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[interop] Running C# interop unit tests..."
export PATH="${HOME}/.dotnet:${PATH}"
(cd "${ROOT_DIR}" && dotnet test --filter "FullyQualifiedName~Interop" --no-restore 2>/dev/null || dotnet test --filter "FullyQualifiedName~Interop")

if [[ -x "${SCRIPT_DIR}/check-rust-client-interop.sh" ]]; then
  bash "${SCRIPT_DIR}/check-rust-client-interop.sh"
fi

echo "[interop] OK"
