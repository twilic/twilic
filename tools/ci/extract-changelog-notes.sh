#!/usr/bin/env bash
# Print the Keep a Changelog section for a runtime release tag.
#
# Usage:
#   bash tools/ci/extract-changelog-notes.sh <tag> [changelog-path]
#
# <tag> is runtimes/<language>/v<semver>. When [changelog-path] is omitted, the
# script reads runtimes/<language>/docs/CHANGELOG.md from this repository.
set -euo pipefail

tag="${1:-}"
changelog="${2:-}"

if [[ -z "${tag}" ]]; then
  printf 'usage: %s <tag> [changelog-path]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

if [[ ! "${tag}" =~ ^runtimes/([^/]+)/v(.+)$ ]]; then
  printf 'invalid runtime tag %q (expected runtimes/<language>/v<semver>)\n' "${tag}" >&2
  exit 1
fi

language="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[2]}"

if [[ -z "${changelog}" ]]; then
  root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  changelog="${root_dir}/runtimes/${language}/docs/CHANGELOG.md"
fi

if [[ ! -f "${changelog}" ]]; then
  printf 'changelog not found for %s: %s\n' "${tag}" "${changelog}" >&2
  exit 1
fi

heading="## [${version}]"
notes="$(
  awk -v heading="${heading}" '
    index($0, heading) == 1 { capture = 1; next }
    capture && index($0, "## [") == 1 { exit }
    capture { lines[++count] = $0 }
    END {
      start = 1
      end = count
      while (start <= end && lines[start] ~ /^[[:space:]]*$/) start++
      while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
      for (i = start; i <= end; i++) print lines[i]
    }
  ' "${changelog}"
)"

if [[ -z "${notes}" ]]; then
  printf 'changelog section %s not found in %s\n' "${heading}" "${changelog}" >&2
  exit 1
fi

printf '%s\n' "${notes}"
