#!/usr/bin/env bash
# Parse a monorepo runtime release tag: runtimes/<language>/v<semver>
#
# Usage:
#   bash tools/ci/parse-runtime-tag.sh <tag> [expected_language]
#
# Writes language, version, runtime_dir, and tag to GITHUB_OUTPUT when set;
# otherwise prints KEY=value lines on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag="${1:-}"
expected_language="${2:-}"

if [[ -z "${tag}" ]]; then
  printf 'usage: %s <tag> [expected_language]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

if [[ ! "${tag}" =~ ^runtimes/([^/]+)/v(.+)$ ]]; then
  printf 'invalid runtime tag %q (expected runtimes/<language>/v<semver>)\n' "${tag}" >&2
  exit 1
fi

language="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[2]}"
runtime_dir="runtimes/${language}"

if [[ -z "${version}" ]]; then
  printf 'invalid runtime tag %q (empty version)\n' "${tag}" >&2
  exit 1
fi

if [[ -n "${expected_language}" && "${language}" != "${expected_language}" ]]; then
  printf 'tag language mismatch: expected %q, got %q from %q\n' \
    "${expected_language}" "${language}" "${tag}" >&2
  exit 1
fi

if [[ ! -d "${ROOT_DIR}/${runtime_dir}" ]]; then
  printf 'unknown runtime directory: %s\n' "${runtime_dir}" >&2
  exit 1
fi

emit() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "${key}" "${value}"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${GITHUB_OUTPUT}"
  fi
}

emit tag "${tag}"
emit language "${language}"
emit version "${version}"
emit runtime_dir "${runtime_dir}"
