#!/usr/bin/env python3
"""Mechanical Python -> Swift port helper for Twilic core modules."""

from __future__ import annotations

import re
import sys
from pathlib import Path

RUNTIMES_ROOT = Path(__file__).resolve().parents[2]
PY_ROOT = RUNTIMES_ROOT / "python" / "src" / "twilic"
OUT_ROOT = RUNTIMES_ROOT / "swift" / "Sources" / "Twilic" / "Core"

HEADER = """import Foundation

"""

REPLACEMENTS = [
    (r"from __future__ import annotations\n", ""),
    (r'"""[^"]*"""\n\n', ""),
    (r"from \.errors import ([^\n]+)\n", r"// import errors: \1\n"),
    (r"from \.model import ([^\n]+)\n", r"// import model: \1\n"),
    (r"from \.wire import ([^\n]+)\n", r"// import wire: \1\n"),
    (r"from \.codec import ([^\n]+)\n", r"// import codec: \1\n"),
    (r"from \.session import ([^\n]+)\n", r"// import session: \1\n"),
    (r"from \.dictionary import ([^\n]+)\n", r"// import dictionary: \1\n"),
    (r"import struct\n", ""),
    (r"import pytest\n", ""),
    (r"class (\w+)\(IntEnum\):", r"enum \1: UInt8, CaseIterable {"),
    (r"    (\w+) = (\d+)", r"    case \1 = \2"),
    (r"@dataclass\nclass (\w+)", r"struct \1"),
    (r"class (\w+):", r"final class \1 {"),
    (r"def (\w+)\(", r"func \1("),
    (r"self\.", r"self."),
    (r" -> None:", r" {"),
    (r" -> bytes:", r" -> Data {"),
    (r" -> int:", r" -> UInt64 {"),
    (r" -> float:", r" -> Double {"),
    (r" -> str:", r" -> String {"),
    (r" -> bool:", r" -> Bool {"),
    (r"list\[", r"["),
    (r"dict\[", r"[String: "),
    (r"\| None", r"?"),
    (r"None", r"nil"),
    (r"True", r"true"),
    (r"False", r"false"),
    (r"bytearray", r"Data"),
    (r"bytes", r"Data"),
]


def port_file(name: str) -> None:
    src = (PY_ROOT / name).read_text()
    out_name = "".join(p.capitalize() for p in name.replace(".py", "").split("_"))
    if out_name == "V2":
        out_name = "V2"
    if out_name == "":
        return
    text = src
    for pat, rep in REPLACEMENTS:
        text = re.sub(pat, rep, text)
    text = HEADER + f"// AUTO-PORTED from {name} — requires manual fixes\n\n" + text
    (OUT_ROOT / f"{out_name}.swift").write_text(text)
    print(f"wrote {out_name}.swift")


if __name__ == "__main__":
    for f in sys.argv[1:] or [
        "wire.py",
        "errors.py",
        "model.py",
        "session.py",
        "dictionary.py",
        "codec.py",
        "v2.py",
    ]:
        port_file(f)
