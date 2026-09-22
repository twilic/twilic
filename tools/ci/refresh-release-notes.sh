#!/usr/bin/env bash
# Rewrite the latest GitHub Releases from each runtime CHANGELOG.md.
#
# Usage:
#   bash tools/ci/refresh-release-notes.sh [limit]
set -euo pipefail

limit="${1:-10}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"

if [[ ! "${limit}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'limit must be a positive integer, got %q\n' "${limit}" >&2
  exit 2
fi

tags="$(gh release list --limit "${limit}" --json tagName --jq '.[].tagName')"
if [[ -z "${tags}" ]]; then
  printf 'no GitHub releases found\n' >&2
  exit 1
fi

while IFS= read -r tag; do
  [[ -z "${tag}" ]] && continue
  if [[ ! "${tag}" =~ ^runtimes/([^/]+)/v(.+)$ ]]; then
    printf 'skip %s (not a runtime tag)\n' "${tag}"
    continue
  fi

  language="${BASH_REMATCH[1]}"
  changelog="${root_dir}/runtimes/${language}/docs/CHANGELOG.md"
  notes_file="$(mktemp)"
  if ! bash "${script_dir}/extract-changelog-notes.sh" "${tag}" "${changelog}" > "${notes_file}"; then
    rm -f "${notes_file}"
    exit 1
  fi

  title="$(bash "${script_dir}/runtime-release-title.sh" "${tag}")"
  printf 'update %s as %s from %s\n' "${tag}" "${title}" "runtimes/${language}/docs/CHANGELOG.md"
  gh release edit "${tag}" --title "${title}" --notes-file "${notes_file}"
  rm -f "${notes_file}"
done <<< "${tags}"
