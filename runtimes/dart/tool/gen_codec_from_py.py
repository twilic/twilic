#!/usr/bin/env python3
"""Generate lib/src/codec.dart from twilic-python codec.py (mechanical baseline)."""
from __future__ import annotations

import re
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python/src/twilic/codec.py"
OUT = Path(__file__).resolve().parents[1] / "lib/src/codec.dart"

HEADER = '''import 'dart:typed_data';

import 'errors.dart';
import 'model.dart';
import 'wire.dart';

const _simple8bSlots = <(int, int)>[
  (60, 1),
  (30, 2),
  (20, 3),
  (15, 4),
  (12, 5),
  (10, 6),
  (8, 7),
  (7, 8),
  (6, 10),
  (5, 12),
  (4, 15),
  (3, 20),
  (2, 30),
  (1, 60),
];

const _u64Max = 0xFFFFFFFFFFFFFFFF;

'''


def py_to_dart(src: str) -> str:
    lines = []
    for line in src.splitlines():
        if line.startswith('"""') or line.startswith("from ") or line.startswith("import "):
            continue
        if line.strip().startswith("SIMPLE8B_SLOTS"):
            continue
        s = line
        s = re.sub(r"^def (\w+)", r"void \1(", s)
        s = re.sub(r"^def (\w+)\(", r"\1(", s)  # fix double
        s = s.replace("def ", "")
        s = s.replace("-> None:", "")
        s = s.replace("-> list[int]:", "")
        s = s.replace("-> list[float]:", "")
        s = s.replace("-> tuple[int, bool]:", "")
        s = s.replace(": list[int]", "")
        s = s.replace(": list[float]", "")
        s = s.replace("bytearray", "BytesBuilder")
        s = s.replace("Reader", "Reader")
        s = s.replace("VectorCodec.", "VectorCodec.")
        s = s.replace("match codec:", "switch (codec) {")
        s = s.replace("match ", "switch (")
        s = s.replace("case VectorCodec.", "case VectorCodec.")
        s = re.sub(r"if not values:", "if (values.isEmpty)", s)
        s = re.sub(r"if not ", "if (!", s)
        s = s.replace(" and ", " && ")
        s = s.replace(" or ", " || ")
        s = s.replace("True", "true")
        s = s.replace("False", "false")
        s = s.replace("None", "null")
        s = s.replace("append(", "add(")
        s = s.replace("raise invalid_data", "throw invalidData")
        s = s.replace("struct.unpack", "// struct")
        if s.strip():
            lines.append(s)
    return "\n".join(lines)


def main() -> None:
    if not PY.exists():
        print("missing", PY)
        return
    body = py_to_dart(PY.read_text(encoding="utf-8"))
    OUT.write_text(HEADER + "// AUTO-GENERATED — fix manually\n\n" + body, encoding="utf-8")
    print("wrote", OUT, len(body))


if __name__ == "__main__":
    main()
