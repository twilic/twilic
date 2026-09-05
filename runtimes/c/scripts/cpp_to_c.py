#!/usr/bin/env python3
"""Mechanical twilic-cpp -> twilic-c conversion helper (headers + sources)."""

from __future__ import annotations

import re
import sys
from pathlib import Path

CPP_ROOT = Path(__file__).resolve().parents[2] / "cpp"
C_ROOT = Path(__file__).resolve().parents[1]

HEADER_MAP = {
    "cstdint": "stdint.h",
    "cstddef": "stddef.h",
    "cstring": "string.h",
    "cmath": "math.h",
    "cstdio": "stdio.h",
    "cstdlib": "stdlib.h",
    "stdbool.h": "stdbool.h",
    "memory": None,
    "optional": None,
    "string": None,
    "vector": None,
    "unordered_map": None,
    "utility": None,
    "sstream": None,
    "stdexcept": None,
}


def guard_name(path: Path) -> str:
    return "TWILIC_" + path.stem.upper() + "_H"


def convert_includes(text: str) -> str:
    def repl(m: re.Match[str]) -> str:
        inc = m.group(1)
        if inc.startswith("twilic/"):
            return f'#include "{inc.replace(".hpp", ".h")}"'
        if inc in HEADER_MAP:
            alt = HEADER_MAP[inc]
            return f"#include <{alt}>" if alt else ""
        return m.group(0)

    lines = []
    for line in text.splitlines():
        if line.startswith("#include <"):
            m = re.match(r'#include <([^>]+)>', line)
            if m:
                inc = m.group(1)
                alt = HEADER_MAP.get(inc)
                if alt is None and inc in HEADER_MAP:
                    continue
                if alt:
                    line = f"#include <{alt}>"
        elif line.startswith('#include "'):
            line = repl(re.match(r'(#include "[^"]+")', line) or line)  # type: ignore
            m = re.match(r'#include "([^"]+)"', line)
            if m:
                line = f'#include "{m.group(1).replace(".hpp", ".h")}"'
        lines.append(line)
    return "\n".join(lines)


def strip_namespace(text: str) -> str:
    text = re.sub(r"\nnamespace twilic \{\n", "\n", text)
    text = re.sub(r"\n\}  // namespace twilic\n", "\n", text)
    return text


def enum_class_to_c(text: str) -> str:
    def repl(m: re.Match[str]) -> str:
        name = m.group(1)
        body = m.group(2)
        body = re.sub(r"(\w+)\s*=\s*", r"\1 = ", body)
        return f"typedef enum {name} {{\n{body}}} {name};\n"

    return re.sub(r"enum class (\w+)\s*:\s*\w+\s*\{([^}]+)\};", repl, text, flags=re.S)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: cpp_to_c.py <cpp-path> <c-path>", file=sys.stderr)
        return 2
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    text = src.read_text()
    text = convert_includes(text)
    text = strip_namespace(text)
    text = enum_class_to_c(text)
    dst.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
