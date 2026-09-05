#!/usr/bin/env python3
"""Transpile twilic-php sources to twilic-lua (mechanical, then hand-fix)."""

from __future__ import annotations

import re
import sys
from pathlib import Path

PHP_ROOT = Path(__file__).resolve().parents[2] / "php" / "src" / "Twilic"
LUA_ROOT = Path(__file__).resolve().parents[1] / "src" / "twilic" / "core"

FILE_MAP = {
    "Errors.php": "errors.lua",
    "ByteBuffer.php": "byte_buffer.lua",
    "Wire.php": "wire.lua",
    "Model.php": "model.lua",
    "Session.php": "session.lua",
    "Codec.php": "codec.lua",
    "Dictionary.php": "dictionary.lua",
    "ProtocolHelpers.php": "protocol_helpers.lua",
    "Protocol.php": "protocol.lua",
    "V2.php": "v2.lua",
    "InteropFixtures.php": "interop_fixtures.lua",
}


def snake_case(name: str) -> str:
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    return s.lower()


def convert_php_to_lua(src: str, module: str) -> str:
    lines_out: list[str] = [
        f'-- Auto-transpiled from twilic-php {module}; verify with busted.',
        "local M = {}",
        "",
    ]
    skip_until = None
    in_class = None
    brace_depth = 0

    for raw in src.splitlines():
        line = raw.rstrip()
        stripped = line.strip()

        if stripped.startswith("<?php") or stripped.startswith("declare("):
            continue
        if stripped.startswith("namespace ") or stripped.startswith("use "):
            continue
        if stripped.startswith("/**") or stripped.startswith("*") or stripped.startswith("*/"):
            continue
        if stripped.startswith("#[") or stripped.startswith("//"):
            continue
        if stripped.startswith("enum "):
            # enum Foo: int { case BAR = 0; }
            m = re.match(r"enum (\w+)", stripped)
            if m:
                in_class = m.group(1)
                lines_out.append(f"M.{in_class} = {{")
            continue
        if stripped.startswith("case "):
            m = re.match(r"case (\w+) = (-?\d+);", stripped)
            if m:
                lines_out.append(f"  {m.group(1)} = {m.group(2)},")
            continue
        if stripped == "}" and in_class and "function" not in stripped:
            if lines_out and lines_out[-1].endswith(","):
                lines_out.append("}")
                lines_out.append("")
                in_class = None
            continue

        # final class Foo -> M.Foo = {}
        m = re.match(r"final class (\w+)", stripped)
        if m:
            in_class = m.group(1)
            lines_out.append(f"M.{in_class} = {{}}")
            lines_out.append(f"local {in_class} = M.{in_class}")
            lines_out.append("")
            continue

        # function foo(
        m = re.match(r"function (\w+)\(", stripped)
        if m and not stripped.startswith("public ") and not stripped.startswith("private "):
            name = m.group(1)
            lua_name = snake_case(name) if name[0].isupper() else name
            params = stripped[stripped.index("(") + 1 : stripped.rindex(")")]
            params = re.sub(r"\bint\b|\bstring\b|\bfloat\b|\bbool\b|\barray\b|\bvoid\b", "", params)
            params = re.sub(r"\?\w+", "", params)
            params = params.replace("Value ", "").replace("Message ", "")
            params = re.sub(r"\$(\w+)", r"\1", params)
            params = re.sub(r",\s*,", ",", params).strip(" ,")
            lines_out.append(f"function M.{lua_name}({params})")
            continue

        # public function method(
        m = re.match(r"public function (\w+)\(", stripped)
        if m and in_class:
            name = m.group(1)
            lua_name = snake_case(name)
            params = stripped[stripped.index("(") + 1 : stripped.rindex(")")]
            params = re.sub(r"\b\w+\s+\$(\w+)", r"\1", params)
            params = re.sub(r"\$(\w+)", r"\1", params)
            lines_out.append(f"function {in_class}.{lua_name}({params})")
            continue

        if stripped in ("{", "}"):
            if stripped == "{":
                lines_out.append("")
            continue

        s = line
        s = re.sub(r"\$(\w+)", r"\1", s)
        s = s.replace("===", "==").replace("!==", "~=")
        s = s.replace("->", ".")
        s = s.replace("::", ".")
        s = s.replace("true", "true").replace("false", "false")
        s = s.replace("null", "nil")
        s = s.replace("throw ", "error(")
        if "error(" in s and not s.rstrip().endswith(")"):
            s = s.rstrip() + ", 0)"
        s = re.sub(r"\bstrlen\(([^)]+)\)", r"#\1", s)
        s = re.sub(r"\bcount\(([^)]+)\)", r"#\1", s)
        s = re.sub(r"\bord\(([^)]+)\[([^\]]+)\]\)", r"string.byte(\1, \2 + 1)", s)
        s = s.replace("array_fill", "-- array_fill")
        s = s.replace("new ", "")
        s = s.replace("?:", " or nil")
        if s.strip():
            lines_out.append("  " + s.strip())

    lines_out.append("")
    lines_out.append("return M")
    return "\n".join(lines_out)


def main() -> int:
    for php_name, lua_name in FILE_MAP.items():
        php_path = PHP_ROOT / php_name
        if not php_path.exists():
            print(f"skip missing {php_path}", file=sys.stderr)
            continue
        lua_path = LUA_ROOT / lua_name
        lua_path.parent.mkdir(parents=True, exist_ok=True)
        text = php_path.read_text()
        lua_path.write_text(convert_php_to_lua(text, php_name))
        print(f"wrote {lua_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
