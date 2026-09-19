#!/usr/bin/env bash
# Verify runtimes/rust/vX.Y.Z matches Cargo.toml package version.
#
# Usage:
#   bash tools/ci/verify-rust-tag-version.sh <tag>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag="${1:-}"
if [[ -z "${tag}" ]]; then
  printf 'usage: %s <tag>\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

# shellcheck disable=SC1090
eval "$(bash "${ROOT_DIR}/tools/ci/parse-runtime-tag.sh" "${tag}" rust)"

manifest="${ROOT_DIR}/runtimes/rust/Cargo.toml"
cargo_version="$(
  awk '
    /^\[package\]/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && /^version[[:space:]]*=/ {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "${manifest}"
)"

if [[ "${cargo_version}" != "${version}" ]]; then
  printf 'tag/version mismatch: tag=%s Cargo.toml version=%s\n' "${tag}" "${cargo_version}" >&2
  exit 1
fi
