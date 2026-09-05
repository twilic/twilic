#!/usr/bin/env python3
"""Emit v2.lua from twilic-php V2.php (mechanical, hand-tuned patterns)."""
from pathlib import Path

PHP = Path(__file__).resolve().parents[2] / "php" / "src" / "Twilic" / "V2.php"
OUT = Path(__file__).resolve().parents[1] / "src" / "twilic" / "core" / "v2.lua"

HEADER = '''local errors = require("twilic.core.errors")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local byte_buffer = require("twilic.core.byte_buffer")
local session = require("twilic.core.session")

local M = {}

M.NULL_TAG = 0xC0
M.FALSE_TAG = 0xC1
M.TRUE_TAG = 0xC2
M.F64_TAG = 0xC3
M.U8_TAG = 0xC4
M.U16_TAG = 0xC5
M.U32_TAG = 0xC6
M.U64_TAG = 0xC7
M.I8_TAG = 0xC8
M.I16_TAG = 0xC9
M.I32_TAG = 0xCA
M.I64_TAG = 0xCB
M.BIN8_TAG = 0xCC
M.BIN16_TAG = 0xCD
M.BIN32_TAG = 0xCE
M.STR8_TAG = 0xCF
M.STR16_TAG = 0xD0
M.STR32_TAG = 0xD1
M.ARRAY16_TAG = 0xD2
M.ARRAY32_TAG = 0xD3
M.MAP16_TAG = 0xD4
M.MAP32_TAG = 0xD5
M.SHAPE_DEF_TAG = 0xD6
M.KEY_REF_TAG = 0xD8
M.STR_REF_TAG = 0xD9

local function new_encode_state()
  return { key_ids = {}, str_ids = {}, shape_ids = {}, next_key_id = 0, next_str_id = 0, next_shape_id = 0 }
end

local function new_decode_state()
  return { keys = {}, strings = {}, shapes = {} }
end

'''

def main():
    src = PHP.read_text()
    body = []
    in_fn = False
    fn_lines = []
    for raw in src.splitlines():
        line = raw.rstrip()
        st = line.strip()
        if st.startswith("<?php") or st.startswith("declare") or st.startswith("namespace"):
            continue
        if st.startswith("const V2_"):
            continue
        if st.startswith("final class"):
            continue
        if st.startswith("function "):
            if in_fn and fn_lines:
                body.append(convert_fn(fn_lines))
                fn_lines = []
            in_fn = True
            fn_lines = [line]
            continue
        if in_fn:
            if st == "}" and fn_lines and fn_lines[-1].strip() != "{":
                fn_lines.append(line)
                body.append(convert_fn(fn_lines))
                fn_lines = []
                in_fn = False
            else:
                fn_lines.append(line)
    OUT.write_text(HEADER + "\n".join(body) + "\n\nreturn M\n")
    print(f"wrote {OUT}")


def convert_fn(lines):
    first = lines[0]
    m = __import__("re").match(r"function (\w+)\(([^)]*)\)", first.strip())
    name = m.group(1)
    params = m.group(2)
    params = __import__("re").sub(r"\b(?:Value|ByteBuffer|Reader|V2EncodeState|V2DecodeState)\s+\$(\w+)", r"\1", params)
    params = __import__("re").sub(r"\$(\w+)", r"\1", params)
    params = params.replace("array $values", "values").replace("array $entries", "entries")
    out = [f"function M.{name}({params})"]
    for line in lines[1:]:
        s = line.strip()
        if s in ("{", "}"):
            continue
        s = __import__("re").sub(r"\$(\w+)", r"\1", s)
        s = s.replace("->", ".")
        s = s.replace("::", ".")
        s = s.replace("===", "==").replace("!==", "~=")
        s = s.replace("null", "nil")
        s = s.replace("true", "true").replace("false", "false")
        s = s.replace("new_null()", "model.null_value()")
        s = s.replace("new_bool(", "model.bool_value(")
        s = s.replace("new_i64(", "model.i64_value(")
        s = s.replace("new_u64(", "model.u64_value(")
        s = s.replace("new_f64(", "model.f64_value(")
        s = s.replace("new_string(", "model.string_value(")
        s = s.replace("new_binary(", "model.binary_value(")
        s = s.replace("new_array(", "model.array_value(")
        s = s.replace("new_map(", "model.map_value(")
        s = s.replace("entry(", "model.entry(")
        s = s.replace("ValueKind.", "model.VALUE_")
        s = s.replace("shape_key(", "session.shape_key(")
        s = s.replace("encode_varuint(", "wire.encode_varuint(")
        s = s.replace("append_f64_le(", "wire.append_f64_le(")
        s = s.replace("append_u64_le(", "wire.append_u64_le(")
        s = s.replace("read_f64_le(", "wire.read_f64_le(")
        s = s.replace("read_u64_le(", "wire.read_u64_le(")
        s = s.replace("new_reader(", "wire.new_reader(")
        s = s.replace("throw invalid_data(", "errors.raise(errors.invalid_data(")
        s = s.replace("throw invalid_tag(", "errors.raise(errors.invalid_tag(")
        if "errors.raise(errors." in s and not s.rstrip().endswith(")"):
            s = s.rstrip() + ")"
        s = s.replace("strlen(", "#")
        s = s.replace("count(", "#")
        s = s.replace("$out", "out")
        s = s.replace("new ByteBuffer()", "byte_buffer.new()")
        s = s.replace("->append(", "byte_buffer.append(out, ")
        s = s.replace("->appendBytes(", "byte_buffer.append_bytes(out, ")
        s = s.replace("V2_", "M.")
        s = s.replace("unpack('s', ", 'string.unpack("<i2", ')
        s = s.replace("unpack('l', ", 'string.unpack("<i4", ')
        s = s.replace("unpack('q', ", 'string.unpack("<i8", ')
        s = s.replace(")[1]", ")")
        if s.startswith("match ") or "match (" in s:
            continue
        if "static function" in s:
            continue
        out.append("  " + s)
    out.append("end")
    return "\n".join(out)


if __name__ == "__main__":
    main()
