#!/usr/bin/env python3
"""Convert twilic-php procedural functions to a Lua module (best-effort)."""
from __future__ import annotations

import re
import sys
from pathlib import Path

PHP_ROOT = Path(__file__).resolve().parents[2] / "php" / "src" / "Twilic"
LUA_ROOT = Path(__file__).resolve().parents[1] / "src" / "twilic" / "core"

MODULES = {
    "Codec.php": {
        "lua": "codec.lua",
        "requires": [
            "twilic.core.errors",
            "twilic.core.model",
            "twilic.core.wire",
            "twilic.core.byte_buffer",
        ],
    },
    "Dictionary.php": {
        "lua": "dictionary.lua",
        "requires": [
            "twilic.core.errors",
            "twilic.core.model",
            "twilic.core.wire",
            "twilic.core.byte_buffer",
            "twilic.core.session",
        ],
    },
    "ProtocolHelpers.php": {
        "lua": "protocol_helpers.lua",
        "requires": [
            "twilic.core.errors",
            "twilic.core.model",
            "twilic.core.wire",
            "twilic.core.codec",
        ],
    },
}

ENUM_MAP = {
    "ValueKind::": "model.VALUE_",
    "MessageKind::": "model.MESSAGE_KIND_",
    "VectorCodec::": "model.VECTOR_CODEC_",
    "ElementType::": "model.ELEMENT_TYPE_",
    "StringMode::": "model.STRING_MODE_",
    "NullStrategy::": "model.NULL_STRATEGY_",
    "ControlOpcode::": "model.CONTROL_OPCODE_",
    "PatchOpcode::": "model.PATCH_OPCODE_",
    "ControlStreamCodec::": "model.CONTROL_STREAM_CODEC_",
    "UnknownReferencePolicy::": "session.UNKNOWN_REFERENCE_POLICY_",
    "DictionaryFallback::": "session.DICTIONARY_FALLBACK_",
}

FUNC_MAP = {
    "new_null": "model.null_value",
    "new_bool": "model.bool_value",
    "new_i64": "model.i64_value",
    "new_u64": "model.u64_value",
    "new_f64": "model.f64_value",
    "new_string": "model.string_value",
    "new_binary": "model.binary_value",
    "new_array": "model.array_value",
    "new_map": "model.map_value",
    "entry": "model.entry",
    "equal": "model.equal",
    "clone": "model.clone_value",
    "encode_varuint": "wire.encode_varuint",
    "decode_zigzag": "wire.decode_zigzag",
    "encode_zigzag": "wire.encode_zigzag",
    "append_f64_le": "wire.append_f64_le",
    "append_u64_le": "wire.append_u64_le",
    "read_f64_le": "wire.read_f64_le",
    "read_u64_le": "wire.read_u64_le",
    "new_reader": "wire.new_reader",
    "encode_string": "wire.encode_string",
    "encode_bytes": "wire.encode_bytes",
    "encode_bitmap": "wire.encode_bitmap",
    "invalid_data": "errors.invalid_data",
    "invalid_tag": "errors.invalid_tag",
    "allocate_dictionary_id": "session.allocate_dictionary_id",
}


def convert_line(line: str) -> str | None:
    s = line.rstrip()
    st = s.strip()
    if not st or st.startswith("//") or st.startswith("#["):
        return None
    if st.startswith("use ") or st.startswith("/**") or st.startswith("*"):
        return None
    if st in ("{", "}"):
        return None
    if st.startswith("match ") or st.startswith("case ") or st.startswith("default "):
        return None
    if "static function" in st or "static fn" in st:
        return None
    if st.startswith("return match"):
        return None
    s = re.sub(r"\$(\w+)", r"\1", s)
    s = s.replace("===", "==").replace("!==", "~=")
    s = s.replace("->", ".")
    s = s.replace("::", ".")
    s = s.replace("null", "nil")
    s = s.replace("true", "true").replace("false", "false")
    s = re.sub(r"\bstrlen\(([^)]+)\)", r"#\1", s)
    s = re.sub(r"\bcount\(([^)]+)\)", r"#\1", s)
    s = re.sub(r"\bmax\(([^)]+)\)", r"math.max(\1)", s)
    s = re.sub(r"\bmin\(([^)]+)\)", r"math.min(\1)", s)
    s = re.sub(r"\bord\(([^]]+)\[(\d+)\]\)", r"string.byte(\1, \2 + 1)", s)
    s = re.sub(r"\bord\(([^)]+)\)", r"string.byte(\1)", s)
    s = re.sub(r"\bpack\('E', ([^)]+)\)", r"string.pack('<d', \1)", s)
    s = re.sub(r"\bunpack\('E', ([^)]+)\)", r"string.unpack('<d', \1)", s)
    s = re.sub(r"\bunpack\('Q<', ([^)]+)\)", r"string.unpack('<I8', \1)", s)
    s = re.sub(r"\bunpack\('s', ([^)]+)\)", r"string.unpack('<i2', \1)", s)
    s = re.sub(r"\bunpack\('l', ([^)]+)\)", r"string.unpack('<i4', \1)", s)
    s = re.sub(r"\bunpack\('q', ([^)]+)\)", r"string.unpack('<i8', \1)", s)
    s = re.sub(r"\)\[1\]", ")", s)
    for k, v in ENUM_MAP.items():
        s = s.replace(k.replace("::", "."), v)
    for k, v in FUNC_MAP.items():
        s = re.sub(rf"\b{k}\(", f"{v}(", s)
    s = s.replace("throw invalid_data(", "errors.raise(errors.invalid_data(")
    s = s.replace("throw invalid_tag(", "errors.raise(errors.invalid_tag(")
    if "errors.raise(errors." in s and not s.rstrip().endswith(")"):
        s = s.rstrip() + ")"
    s = s.replace("new ByteBuffer()", "byte_buffer.new()")
    s = s.replace("ByteBuffer $out", "out")
    s = s.replace("$out", "out")
    s = s.replace("->appendBytes(", "byte_buffer.append_bytes(out, ")
    s = s.replace("->append(", "byte_buffer.append(out, ")
    s = s.replace("->bytes()", "byte_buffer.bytes(out)")
    s = s.replace("->readVaruint()", ":read_varuint()")
    s = s.replace("->readU8()", ":read_u8()")
    s = s.replace("->readExact(", ":read_exact(")
    s = s.replace("->isEof()", ":is_eof()")
    s = s.replace("->position()", ":position()")
    s = s.replace("array_fill", "-- array_fill")
    s = s.replace("array_map", "-- array_map")
    s = s.replace("array_filter", "-- array_filter")
    s = s.replace("array_values", "-- array_values")
    s = s.replace("array_unique", "-- array_unique")
    s = s.replace("array_sum", "-- array_sum")
    s = s.replace("array_slice", "-- array_slice")
    s = s.replace("foreach (", "-- foreach ")
    s = s.replace("for ($", "for ")
    s = s.replace("; $", ", ")
    s = s.replace("++", " + 1")
    s = s.replace("fn (", "function(")
    s = s.replace("static fn", "function")
    if st.startswith("function "):
        m = re.match(r"function (\w+)\(([^)]*)\)", st)
        if m:
            name, params = m.group(1), m.group(2)
            params = re.sub(r"\b(?:int|string|float|bool|array|void)\b\s*", "", params)
            params = re.sub(r"\?\w+\s*", "", params)
            params = re.sub(r"\b(?:Value|Message|ByteBuffer|Reader|VectorCodec|SessionState|Column|Schema)\s+\$(\w+)", r"\1", params)
            params = re.sub(r"array \$(\w+)", r"\1", params)
            params = re.sub(r"\$(\w+)", r"\1", params)
            params = params.strip(" ,")
            return f"function M.{name}({params})"
    indent = "  " if not st.startswith("function ") else ""
    return indent + s.strip()


def convert_file(php_name: str, cfg: dict) -> None:
    src = (PHP_ROOT / php_name).read_text()
    lines = ["local M = {}", ""]
    for req in cfg["requires"]:
        mod = req.split(".")[-1]
        lines.append(f'local {mod} = require("{req}")')
    lines.append("")
    if php_name == "Codec.php":
        lines.append("M.SIMPLE8B_SLOTS = {")
        lines.append("  {60,1},{30,2},{20,3},{15,4},{12,5},{10,6},{8,7},{7,8},")
        lines.append("  {6,10},{5,12},{4,15},{3,20},{2,30},{1,60},")
        lines.append("}")
        lines.append("M.MAX_U64 = model.MAX_U64")
        lines.append("M.MAX_I64 = model.MAX_I64")
        lines.append("M.MIN_I64 = model.MIN_I64")
        lines.append("")
    in_class = False
    for raw in src.splitlines():
        st = raw.strip()
        if st.startswith("final class") or st.startswith("class WideU128"):
            in_class = True
            continue
        if in_class and st == "}":
            in_class = False
            continue
        if in_class:
            continue
        if st.startswith("<?php") or st.startswith("declare") or st.startswith("namespace"):
            continue
        if st.startswith("const SIMPLE8B") or st.startswith("const U64_MAX"):
            continue
        out = convert_line(raw)
        if out:
            lines.append(out)
    lines.append("")
    lines.append("return M")
    out_path = LUA_ROOT / cfg["lua"]
    out_path.write_text("\n".join(lines) + "\n")
    print(f"wrote {out_path} ({len(lines)} lines)")


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else None
    for php_name, cfg in MODULES.items():
        if target and php_name != target:
            continue
        convert_file(php_name, cfg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
