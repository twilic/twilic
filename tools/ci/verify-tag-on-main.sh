#!/usr/bin/env bash
# Fail unless the given tag (or commit-ish) is an ancestor of origin/main.
#
# Usage:
#   bash tools/ci/verify-tag-on-main.sh <tag>
set -euo pipefail

tag="${1:-}"
if [[ -z "${tag}" ]]; then
  printf 'usage: %s <tag>\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

git fetch --no-tags origin main
if ! git merge-base --is-ancestor "${tag}" origin/main; then
  printf 'ref %q is not an ancestor of origin/main\n' "${tag}" >&2
  exit 1
fi
