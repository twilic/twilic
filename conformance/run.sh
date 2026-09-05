#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_RUNNER="${ROOT_DIR}/tools/test-runtime.sh"

usage() {
  printf 'usage: %s [--interop] <runtime|all|fixtures>\n' "${BASH_SOURCE[0]}" >&2
}

interop=0
if [[ "${1:-}" == "--interop" ]]; then
  interop=1
  shift
fi

target="${1:-}"
if [[ -z "${target}" ]]; then
  usage
  exit 2
fi

if [[ "${target}" == "fixtures" ]]; then
  export TWILIC_RUST_ROOT="${TWILIC_RUST_ROOT:-${ROOT_DIR}/runtimes/rust}"
  export TWILIC_RUST_DIR="${TWILIC_RUST_DIR:-${TWILIC_RUST_ROOT}}"
  cargo run --quiet --manifest-path "${SCRIPT_DIR}/rust-client-check/Cargo.toml" \
    < "${SCRIPT_DIR}/fixtures/interop-v1.txt"
  exit 0
fi

if [[ "${interop}" -eq 0 ]]; then
  bash "${RUNTIME_RUNNER}" "${target}"
  exit 0
fi

if [[ "${target}" == "all" ]]; then
  runtimes=(rust javascript go python java c cpp csharp dart kotlin lua php r ruby scala swift zig elixir)
else
  runtimes=("${target}")
fi

export TWILIC_RUST_ROOT="${TWILIC_RUST_ROOT:-${ROOT_DIR}/runtimes/rust}"
export TWILIC_RUST_DIR="${TWILIC_RUST_DIR:-${TWILIC_RUST_ROOT}}"

for runtime in "${runtimes[@]}"; do
  if [[ "${runtime}" == "rust" ]]; then
    printf '\n==> interop %s\n' "${runtime}"
    bash "${BASH_SOURCE[0]}" fixtures
    continue
  fi
  script="${ROOT_DIR}/runtimes/${runtime}/scripts/check-interop.sh"
  if [[ ! -f "${script}" ]]; then
    printf 'interop script not found for %s: %s\n' "${runtime}" "${script}" >&2
    exit 2
  fi
  printf '\n==> interop %s\n' "${runtime}"
  bash "${script}"
done
