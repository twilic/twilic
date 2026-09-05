#!/usr/bin/env python3
"""Port twilic-python/src/twilic/codec.py to lib/src/codec.dart."""
from __future__ import annotations

import re
import textwrap
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python/src/twilic/codec.py"
OUT = Path(__file__).resolve().parents[1] / "lib/src/codec.dart"

HEADER = textwrap.dedent(
    """
    import 'dart:typed_data';

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
    """
).strip()


def camel(name: str) -> str:
    parts = name.split("_")
    return parts[0] + "".join(p.title() for p in parts[1:])


def convert_expr(expr: str) -> str:
    e = expr.strip()
    e = e.replace("reader.read_varuint()", "reader.readVaruint()")
    e = e.replace("reader.read_u8()", "reader.readU8()")
    e = e.replace("reader.is_eof()", "reader.isEof")
    e = e.replace("reader.read_exact(", "reader.readExact(")
    e = e.replace("encode_varuint(", "encodeVaruint(")
    e = e.replace("encode_zigzag(", "encodeZigzag(")
    e = e.replace("decode_zigzag(", "decodeZigzag(")
    e = e.replace("append_f64_le(", "appendF64Le(")
    e = e.replace("append_u64_le(", "appendU64Le(")
    e = e.replace("read_f64_le(", "readF64Le(")
    e = e.replace("read_u64_le(", "readU64Le(")
    e = re.sub(r"VectorCodec\.(\w+)", lambda m: f"VectorCodec.{camel(m.group(1).lower())}", e)
    e = e.replace("invalid_data(", "invalidData(")
    e = e.replace(" and ", " && ")
    e = e.replace(" or ", " || ")
    e = e.replace(" not ", " !")
    e = e.replace("True", "true")
    e = e.replace("False", "false")
    e = e.replace("None", "null")
    return e


def convert_body(body: str, ret: str) -> str:
    lines = []
    indent = "  "
    for raw in body.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        s = line.strip()
        if s.startswith("match "):
            var = s.split()[1].rstrip(":")
            lines.append(f"{indent}switch ({var}) {{")
            continue
        if s.startswith("case "):
            case = s.split("case ")[1].split(":")[0].strip()
            if "|" in case:
                for part in case.split("|"):
                    part = part.strip()
                    lines.append(f"{indent}  case {convert_expr(part)}:")
            else:
                lines.append(f"{indent}  case {convert_expr(case)}:")
            continue
        if s == "case _:":
            lines.append(f"{indent}  default:")
            continue
        if s.startswith("return "):
            val = convert_expr(s[7:])
            lines.append(f"{indent}  return {val};")
            continue
        if s.startswith("if not "):
            cond = convert_expr(s[7:].rstrip(":"))
            lines.append(f"{indent}  if (!({cond})) {{")
            continue
        if s.startswith("if "):
            cond = convert_expr(s[3:].rstrip(":"))
            lines.append(f"{indent}  if ({cond}) {{")
            continue
        if s == "return":
            lines.append(f"{indent}  return;")
            continue
        if s.startswith("raise "):
            msg = s.split("(", 1)[1]
            lines.append(f"{indent}  throw {convert_expr('invalid_data'+msg)};")
            continue
        if s.startswith("for _ in range("):
            m = re.match(r"for _ in range\((.+)\):", s)
            n = convert_expr(m.group(1))
            lines.append(f"{indent}  for (var _i = 0; _i < {n}; _i++) {{")
            continue
        if s.startswith("while "):
            cond = convert_expr(s[6:].rstrip(":"))
            lines.append(f"{indent}  while ({cond}) {{")
            continue
        if s.endswith(":"):
            continue
        # assignment / call
        if "=" in s and not s.startswith("if"):
            left, right = s.split("=", 1)
            lines.append(f"{indent}  {convert_expr(left.strip())} = {convert_expr(right.strip())};")
        else:
            call = convert_expr(s)
            if not call.endswith(";"):
                call += ";"
            lines.append(f"{indent}  {call}")
    if ret and ret != "None":
        if ret == "list[int]":
            pass
    return "\n".join(lines)


def port_function(name: str, args: str, body: str, ret: str) -> str:
    dart_args = ", ".join(
        f"int {a}" if a == "v" else f"List<int> {a}" if a == "values" else f"{a}"
        for a in [x.strip() for x in args.split(",") if x.strip()]
    )
    # fix signatures manually for known functions
    sigs = {
        "encode_i64_vector": "void encodeI64Vector(List<int> values, VectorCodec codec, BytesBuilder out)",
        "decode_i64_vector": "List<int> decodeI64Vector(Reader reader, VectorCodec codec)",
        "encode_u64_vector": "void encodeU64Vector(List<int> values, VectorCodec codec, BytesBuilder out)",
        "decode_u64_vector": "List<int> decodeU64Vector(Reader reader, VectorCodec codec)",
        "encode_f64_vector": "void encodeF64Vector(List<double> values, VectorCodec codec, BytesBuilder out)",
        "decode_f64_vector": "List<double> decodeF64Vector(Reader reader, VectorCodec codec)",
    }
    sig = sigs.get(name, f"void {camel(name)}()")
    b = convert_body(body, ret)
    return f"{sig} {{\n{b}\n}}\n"


def main() -> None:
    src = PY.read_text(encoding="utf-8")
    # For reliability, copy python file as reference comment and emit hand-maintained subset
    # Use exec of python logic via subprocess - instead write known-good minimal + read py

    # Emit by transforming python with regex for function blocks
    out_parts = [HEADER, ""]
    func_re = re.compile(
        r"^def (\w+)\(([^)]*)\)(?: -> ([^:]+))?:\n((?:    .*\n)*)",
        re.MULTILINE,
    )
    for m in func_re.finditer(src):
        name, args, ret, body = m.groups()
        ret = ret or "None"
        try:
            out_parts.append(port_function(name, args, body, ret))
        except Exception as e:
            out_parts.append(f"// FAILED {name}: {e}\n")

    OUT.write_text("\n".join(out_parts), encoding="utf-8")
    print("wrote", OUT, "lines", len(out_parts))


if __name__ == "__main__":
    main()
