#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUNTIME="${1:-}"
RUST_ROOT="${TWILIC_RUST_ROOT:-${ROOT_DIR}/runtimes/rust}"
export TWILIC_RUST_ROOT="${RUST_ROOT}"
export TWILIC_RUST_DIR="${TWILIC_RUST_DIR:-${RUST_ROOT}}"
export GOCACHE="${GOCACHE:-${ROOT_DIR}/.cache/go-build}"

runtime_dir() {
  printf '%s/runtimes/%s\n' "${ROOT_DIR}" "$1"
}

run_runtime() {
  local runtime="$1"
  local dir
  dir="$(runtime_dir "${runtime}")"

  case "${runtime}" in
    rust)
      cargo test --all-targets --manifest-path "${dir}/Cargo.toml"
      ;;
    javascript)
      (cd "${dir}" && pnpm build:wasm && pnpm test)
      ;;
    go)
      (cd "${dir}" && go test ./... -count=1)
      ;;
    python)
      (cd "${dir}" && uv run pytest)
      ;;
    java)
      (cd "${dir}" && ./gradlew test --no-daemon)
      ;;
    c|cpp)
      local build_dir="${dir}/build"
      cmake -S "${dir}" -B "${build_dir}" -DCMAKE_BUILD_TYPE=Release
      cmake --build "${build_dir}"
      ctest --test-dir "${build_dir}" --output-on-failure
      ;;
    csharp)
      (cd "${dir}" && dotnet test)
      ;;
    dart)
      (cd "${dir}" && dart test)
      ;;
    kotlin)
      (cd "${dir}" && ./gradlew test --no-daemon)
      ;;
    lua)
      (cd "${dir}" && LUA_PATH="src/?.lua;src/?/init.lua;${LUA_PATH:-;;}" busted spec)
      ;;
    php)
      (cd "${dir}" && composer test)
      ;;
    r)
      (cd "${dir}" && Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")')
      ;;
    ruby)
      (cd "${dir}" && bundle exec rake test)
      ;;
    scala)
      (cd "${dir}" && sbt -batch scalafmtCheck test)
      ;;
    swift)
      (cd "${dir}" && swift test)
      ;;
    zig)
      (cd "${dir}" && zig build test)
      ;;
    elixir)
      (cd "${dir}" && mix test)
      ;;
    *)
      printf 'unknown runtime: %s\n' "${runtime}" >&2
      return 2
      ;;
  esac
}

if [[ "${RUNTIME}" == "" ]]; then
  printf 'usage: %s <runtime|all>\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

if [[ "${RUNTIME}" == "all" ]]; then
  for runtime in rust javascript go python java c cpp csharp dart kotlin lua php r ruby scala swift zig elixir; do
    printf '\n==> testing %s\n' "${runtime}"
    run_runtime "${runtime}"
  done
else
  run_runtime "${RUNTIME}"
fi
