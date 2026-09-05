#!/usr/bin/env bash
set -euo pipefail

BASE_SHA="${1:-}"
HEAD_SHA="${2:-HEAD}"

runtime_os() {
  case "$1" in
    swift) printf 'macos-latest\n' ;;
    *) printf 'ubuntu-latest\n' ;;
  esac
}

runtime_names=(rust javascript go python java c cpp csharp dart kotlin lua php r ruby scala swift zig elixir)

if [[ -z "${BASE_SHA}" ]] || [[ "${BASE_SHA}" == "0000000000000000000000000000000000000000" ]] || \
   ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  shared=1
  changed_files=""
else
  shared=0
  changed_files="$(git diff --name-only "${BASE_SHA}" "${HEAD_SHA}")"
fi

if [[ "${shared}" -eq 0 ]]; then
  while IFS= read -r path; do
    case "${path}" in
      SPEC.md|docs/*|versions/*|conformance/*|testdata/*|tools/*)
        shared=1
        break
        ;;
    esac
  done <<< "${changed_files}"
fi

selected=()
for runtime in "${runtime_names[@]}"; do
  if [[ "${shared}" -eq 1 ]]; then
    selected+=("${runtime}")
    continue
  fi
  while IFS= read -r path; do
    if [[ "${path}" == "runtimes/${runtime}"/* ]]; then
      selected+=("${runtime}")
      break
    fi
  done <<< "${changed_files}"
done

printf '{"include":['
first=1
if [[ "${#selected[@]}" -gt 0 ]]; then
  for runtime in "${selected[@]}"; do
    [[ "${first}" -eq 1 ]] || printf ','
    first=0
    os="$(runtime_os "${runtime}")"
    printf '{"runtime":"%s","os":"%s"}' "${runtime}" "${os}"
  done
fi
printf ']}\n'
