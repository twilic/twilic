#!/usr/bin/env python3
"""Verify git tag vX.Y.Z matches pyproject.toml version."""

from __future__ import annotations

import os
import sys
import tomllib
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    pyproject_path = root / "pyproject.toml"
    with pyproject_path.open("rb") as handle:
        version = tomllib.load(handle)["project"]["version"]

    tag = os.environ.get("GITHUB_REF_NAME") or (sys.argv[1] if len(sys.argv) > 1 else None)
    if not tag:
        print("tag is required (set GITHUB_REF_NAME or pass tag as arg)", file=sys.stderr)
        sys.exit(1)

    normalized_tag = tag[1:] if tag.startswith("v") else tag
    if normalized_tag != version:
        print(
            f"tag/version mismatch: tag={tag} pyproject.toml version={version}",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
