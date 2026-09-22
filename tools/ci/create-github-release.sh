#!/usr/bin/env bash
# Create a GitHub Release using the matching Keep a Changelog section.
#
# Usage:
#   bash tools/ci/create-github-release.sh <tag> <title>
set -euo pipefail

tag="${1:-}"
title="${2:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${tag}" || -z "${title}" ]]; then
  printf 'usage: %s <tag> <title>\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

if gh release view "${tag}" >/dev/null 2>&1; then
  printf 'release %s already exists\n' "${tag}"
  exit 0
fi

notes_file="$(mktemp)"
trap 'rm -f "${notes_file}"' EXIT
bash "${script_dir}/extract-changelog-notes.sh" "${tag}" > "${notes_file}"

gh release create "${tag}" \
  --title "${title}" \
  --notes-file "${notes_file}" \
  --verify-tag
