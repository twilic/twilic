#!/usr/bin/env bash
# Print a GitHub Release title for a runtime tag.
#
# Usage:
#   bash tools/ci/runtime-release-title.sh <tag>
#
# Example: runtimes/javascript/v3.2.0 -> JavaScript v3.2.0
set -euo pipefail

tag="${1:-}"

if [[ -z "${tag}" ]]; then
  printf 'usage: %s <tag>\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

if [[ ! "${tag}" =~ ^runtimes/([^/]+)/v(.+)$ ]]; then
  printf 'invalid runtime tag %q (expected runtimes/<language>/v<semver>)\n' "${tag}" >&2
  exit 1
fi

language="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[2]}"

case "${language}" in
  c) display_name="C" ;;
  cpp) display_name="C++" ;;
  csharp) display_name="C#" ;;
  dart) display_name="Dart" ;;
  elixir) display_name="Elixir" ;;
  go) display_name="Go" ;;
  java) display_name="Java" ;;
  javascript) display_name="JavaScript" ;;
  kotlin) display_name="Kotlin" ;;
  lua) display_name="Lua" ;;
  php) display_name="PHP" ;;
  python) display_name="Python" ;;
  r) display_name="R" ;;
  ruby) display_name="Ruby" ;;
  rust) display_name="Rust" ;;
  scala) display_name="Scala" ;;
  swift) display_name="Swift" ;;
  zig) display_name="Zig" ;;
  *)
    printf 'no display name for runtime %q\n' "${language}" >&2
    exit 1
    ;;
esac

printf '%s v%s\n' "${display_name}" "${version}"
