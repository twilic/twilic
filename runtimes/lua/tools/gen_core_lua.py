#!/usr/bin/env python3
"""Generate twilic-lua core modules from twilic-python sources."""

from __future__ import annotations

import re
import sys
from pathlib import Path

PY_ROOT = Path(__file__).resolve().parents[2] / "python" / "src" / "twilic"
LUA_ROOT = Path(__file__).resolve().parents[1] / "src" / "twilic" / "core"

SKIP = {"errors.py", "wire.py", "__init__.py", "_version.py"}

REQUIRES = {
    "model.py": [],
    "session.py": ["twilic.core.model"],
    "codec.py": ["twilic.core.errors", "twilic.core.model", "twilic.core.wire", "twilic.core.byte_buffer"],
    "dictionary.py": [
        "twilic.core.errors",
        "twilic.core.model",
        "twilic.core.wire",
        "twilic.core.byte_buffer",
        "twilic.core.session",
    ],
    "v2.py": [
        "twilic.core.errors",
        "twilic.core.model",
        "twilic.core.wire",
        "twilic.core.byte_buffer",
        "twilic.core.session",
    ],
    "protocol.py": [
        "twilic.core.codec",
        "twilic.core.dictionary",
        "twilic.core.errors",
        "twilic.core.model",
        "twilic.core.wire",
        "twilic.core.byte_buffer",
        "twilic.core.session",
        "twilic.core.protocol_helpers",
    ],
}


def py_name_to_lua(py_file: str) -> str:
    return py_file.replace(".py", ".lua").replace("protocol.py", "protocol.lua")


def convert_source(text: str, module: str) -> str:
    lines_out = ["local M = {}", ""]

    for req in REQUIRES.get(module, []):
        mod = req.split(".")[-1]
        if mod == "protocol_helpers":
            mod = "protocol_helpers"
        lines_out.append(f'local {mod} = require("{req}")')

    if REQUIRES.get(module):
        lines_out.append("")

    # Strip imports and module docstring
    body_lines: list[str] = []
    skip_class_state = False
    in_class = None
    class_indent = 0

    for raw in text.splitlines():
        line = raw.rstrip("\n")
        stripped = line.strip()

        if stripped.startswith('"""') or stripped.startswith("'''"):
            continue
        if stripped.startswith("from ") or stripped.startswith("import "):
            continue
        if stripped.startswith("@dataclass"):
            continue
        if stripped.startswith("class ") and ":" in stripped:
            m = re.match(r"class (\w+)", stripped)
            if m:
                name = m.group(1)
                if name == "TwilicCodec":
                    in_class = "TwilicCodec"
                    lines_out.extend(["", "local TwilicCodec = {}", ""])
                    continue
                if name == "SessionEncoder":
                    in_class = "SessionEncoder"
                    lines_out.extend(["", "local SessionEncoder = {}", ""])
                    continue
                if name.startswith("_"):
                    continue
            continue
        if stripped.startswith("def ") and in_class:
            m = re.match(r"def (\w+)\(self(?:, ([^)]*))?\)", stripped)
            if m:
                name = m.group(1)
                params = m.group(2) or ""
                params = re.sub(r":[^,)]+", "", params)
                params = params.strip()
                lua_params = "self" + (", " + params if params else "")
                if name.startswith("_"):
                    lua_name = name[1:]
                else:
                    lua_name = name
                target = in_class
                lines_out.append(f"function {target}.{lua_name}({lua_params})")
                continue
        if in_class and stripped.startswith("def "):
            continue

        body_lines.append(line)

    # For now only emit protocol helpers extraction marker
    lines_out.extend(body_lines[:50])
    lines_out.append("")
    lines_out.append("return M")
    return "\n".join(lines_out)


def main() -> int:
    for py_path in sorted(PY_ROOT.glob("*.py")):
        if py_path.name in SKIP:
            continue
        lua_name = py_name_to_lua(py_path.name)
        if lua_name not in {
            "model.lua",
            "session.lua",
            "codec.lua",
            "dictionary.lua",
            "v2.lua",
            "protocol.lua",
        }:
            continue
        out_path = LUA_ROOT / lua_name
        text = py_path.read_text()
        out_path.write_text(convert_source(text, py_path.name))
        print(f"wrote stub {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
