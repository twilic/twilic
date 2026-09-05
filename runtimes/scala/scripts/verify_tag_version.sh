#!/usr/bin/env bash
set -euo pipefail
TAG="${1:-${GITHUB_REF_NAME:-}}"
VERSION="$(rg 'final val VERSION: String = "([^"]+)"' "${BASH_SOURCE%/*}/../src/main/scala/io/twilic/Version.scala" -or '$1' | head -n1)"
if [[ -z "$TAG" ]]; then
  echo "usage: $0 <tag>"
  exit 1
fi
if [[ "v$VERSION" != "$TAG" ]]; then
  echo "tag/version mismatch: tag=$TAG version=v$VERSION"
  exit 1
fi
echo "tag/version OK: $TAG"
