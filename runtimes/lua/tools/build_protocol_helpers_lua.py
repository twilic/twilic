#!/usr/bin/env python3
"""Emit twilic.core.protocol_helpers from twilic-python protocol.py helper functions."""
from __future__ import annotations

import re
import textwrap
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "src" / "twilic" / "core" / "protocol_helpers.lua"


def strip_types(s: str) -> str:
    s = re.sub(r"\s*->[^:]+:", ":", s)
    s = re.sub(r":\s*[^,\)=]+", "", s)
    return s


def convert_match_case(block: str) -> str:
    lines = block.splitlines()
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"(\s*)match\s+(.+):\s*$", line)
        if m:
            ind, expr = m.group(1), m.group(2)
            out.append(f"{ind}if true then -- match {expr}")
            i += 1
            first = True
            while i < len(lines):
                st = lines[i].strip()
                if st.startswith("case ") and st.endswith(":"):
                    case_expr = st[5:-1].strip()
                    if first:
                        out.append(f"{ind}  if {case_expr} then")
                        first = False
                    else:
                        out.append(f"{ind}  elseif {case_expr} then")
                    i += 1
                    continue
                if st == "case _:" or st.startswith("case _"):
                    out.append(f"{ind}  else")
                    i += 1
                    continue
                if re.match(r"\S", lines[i]) and not lines[i].startswith(ind + " "):
                    break
                if st and not lines[i].startswith(ind + "  ") and not lines[i].startswith(ind + "\t"):
                    if st.startswith("def ") or st.startswith("class "):
                        break
                out.append(lines[i])
                i += 1
            out.append(f"{ind}  end")
            out.append(f"{ind}end")
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


ENUM = {
    "ValueKind.": "model.VALUE_",
    "MessageKind.": "model.MESSAGE_KIND_",
    "VectorCodec.": "model.VECTOR_CODEC_",
    "ElementType.": "model.ELEMENT_TYPE_",
    "StringMode.": "model.STRING_MODE_",
    "NullStrategy.": "model.NULL_STRATEGY_",
    "PatchOpcode.": "model.PATCH_OPCODE_",
    "ControlStreamCodec.": "model.CONTROL_STREAM_CODEC_",
}

FUNCS = {
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
    "encode_zigzag": "wire.encode_zigzag",
    "Message": "model.message",
    "Column": "M._column",
    "TypedVectorData": "model.typed_vector_data",
    "TypedVector": "M._typed_vector",
    "TemplateDescriptor": "M._template_descriptor",
    "PatchOperation": "M._patch_operation",
    "MessageMapEntry": "M._message_map_entry",
    "ShapedObjectMessage": "M._shaped_object",
    "SchemaObjectMessage": "M._schema_object",
    "KeyRef": "M._key_ref",
}


def convert_line(line: str) -> str | None:
    if not line.strip() or line.strip().startswith("#"):
        return None
    s = line.rstrip()
    if s.strip().startswith("@") or s.strip().startswith("from "):
        return None
    if re.match(r"\s*def \w+", s):
        m = re.match(r"(\s*)def (\w+)\(([^)]*)\)", s)
        if not m:
            return None
        ind, name, params = m.group(1), m.group(2), m.group(3)
        params = strip_types(params)
        params = re.sub(r"\b\w+:\s*", "", params)
        params = params.replace("list[", "").replace("]", "")
        return f"{ind}function M.{name}({params})"
    s = re.sub(r"^(\s*)", r"\1", s)
    st = s.strip()
    if st in ("pass", "..."):
        return None
    s = s.replace("True", "true").replace("False", "false").replace("None", "nil")
    s = s.replace(" and ", " and ").replace(" or ", " or ").replace(" not ", " not ")
    s = re.sub(r"\blen\(([^)]+)\)", r"#\1", s)
    s = re.sub(r"\bstruct\.pack\('E', ([^)]+)\)", r"string.pack('<d', \1)", s)
    s = re.sub(r"\[([^\]]+)\]\.pack\('E'\)\.unpack1\('Q<'\)", r"string.unpack('<I8', string.pack('<d', \1))", s)
    for k, v in ENUM.items():
        s = s.replace(k, v)
    for k, v in FUNCS.items():
        s = re.sub(rf"\b{k}\(", f"{v}(", s)
    s = re.sub(r"raise invalid_data\(([^)]+)\)", r"errors.raise(errors.invalid_data(\1))", s)
    s = re.sub(r"raise invalid_tag\(([^)]+)\)", r"errors.raise(errors.invalid_tag(\1))", s)
    s = re.sub(r"raise invalid_kind\(([^)]+)\)", r"errors.raise(errors.invalid_kind(\1))", s)
    s = re.sub(r"\.clone\(\)", ".clone_value()", s)
    s = re.sub(r"for _ in range\(([^)]+)\)", r"for _ = 1, \1 do", s)
    s = re.sub(r"for (\w+) in range\(([^)]+)\)", r"for \1 = 1, \2 do", s)
    s = re.sub(r"for (\w+), (\w+) in enumerate\(([^)]+)\)", r"for \1, \2 in ipairs(\3) do", s)
    s = re.sub(r"for (\w+) in (\w+):", r"for _, \1 in ipairs(\2) do", s)
    s = re.sub(r"if (\w+) is None:", r"if \1 == nil then", s)
    s = re.sub(r"if (\w+) is not None:", r"if \1 ~= nil then", s)
    s = re.sub(r"return \[", "return {", s)
    s = re.sub(r"\]$", "}", s)
    s = s.replace("return (", "return ")
    s = re.sub(r"\b0x([0-9A-Fa-f]+)\b", lambda m: str(int(m.group(0), 0)), s)
    if s.strip().startswith("return {") and "}" not in s:
        s = s + "}"
    return s


def convert_function_body(body: str) -> str:
    body = convert_match_case(body)
    out_lines = []
    for raw in body.splitlines():
        cl = convert_line(raw)
        if cl is not None:
            out_lines.append(cl)
    return "\n".join(out_lines)


def parse_functions(text: str) -> list[tuple[str, str, str]]:
    funcs = []
    i = 0
    while True:
        m = re.search(r"\ndef (\w+)\(", text[i:])
        if not m:
            break
        name = m.group(1)
        start = i + m.start()
        sig_end = text.index(":", start) + 1
        # find next def at col 0
        nxt = re.search(r"\n\ndef ", text[sig_end:])
        end = sig_end + nxt.start() if nxt else len(text)
        body = text[sig_end:end]
        sig = text[start:sig_end]
        funcs.append((name, sig, body))
        i = end
    return funcs


HEADER = textwrap.dedent(
    """\
    local errors = require("twilic.core.errors")
    local model = require("twilic.core.model")
    local wire = require("twilic.core.wire")
    local byte_buffer = require("twilic.core.byte_buffer")
    local codec = require("twilic.core.codec")
    local session = require("twilic.core.session")

    local M = {}

    function M._column(opts)
      return {
        field_id = opts.field_id,
        null_strategy = opts.null_strategy,
        presence = opts.presence,
        has_presence = opts.has_presence,
        codec = opts.codec,
        dictionary_id = opts.dictionary_id,
        values = opts.values,
      }
    end

    function M._typed_vector(opts)
      return { element_type = opts.element_type, codec = opts.codec, data = opts.data }
    end

    function M._template_descriptor(opts)
      return {
        template_id = opts.template_id,
        field_ids = opts.field_ids,
        null_strategies = opts.null_strategies,
        codecs = opts.codecs,
      }
    end

    function M._patch_operation(opts)
      return { field_id = opts.field_id, opcode = opts.opcode, value = opts.value }
    end

    function M._message_map_entry(opts)
      return { key = opts.key, value = opts.value }
    end

    function M._shaped_object(opts)
      return {
        shape_id = opts.shape_id,
        presence = opts.presence,
        has_presence = opts.has_presence,
        values = opts.values,
      }
    end

    function M._schema_object(opts)
      return {
        schema_id = opts.schema_id,
        presence = opts.presence,
        has_presence = opts.has_presence,
        fields = opts.fields,
      }
    end

    function M._key_ref(opts)
      return opts
    end

    function M.bit_width_u64(v)
      v = v & model.MAX_U64
      if v == 0 then return 1 end
      return codec.bit_width(v)
    end

    function M.abs64(v)
      if v < 0 then return -v end
      return v
    end

    """
)


def main() -> None:
    # Hand-ported helpers (Ruby protocol_helpers.rb + protocol.rb shared helpers)
    OUT.write_text(HEADER + HAND_PORTED + "\nreturn M\n")
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


HAND_PORTED = r'''
function M.column_null_strategy_local(values, present_bits)
  local null_count = 0
  for i = 1, #values do
    if values[i].kind == model.VALUE_NULL then null_count = null_count + 1 end
  end
  if null_count == 0 then
    return model.NULL_STRATEGY_ALL_PRESENT_ELIDED, nil, false
  end
  if null_count <= math.floor(#values / 4) then
    local inverted = {}
    for i = 1, #present_bits do inverted[i] = not present_bits[i] end
    return model.NULL_STRATEGY_INVERTED_PRESENCE_BITMAP, inverted, true
  end
  local presence = {}
  for i = 1, #present_bits do presence[i] = present_bits[i] end
  return model.NULL_STRATEGY_PRESENCE_BITMAP, presence, true
end

function M.strip_nulls_local(values)
  local out = {}
  for i = 1, #values do
    if values[i].kind ~= model.VALUE_NULL then out[#out + 1] = values[i] end
  end
  return out
end

function M.rows_to_columns(rows)
  if #rows == 0 then return nil end
  local width = 0
  for i = 1, #rows do width = math.max(width, #rows[i]) end
  local column_values, column_presence = {}, {}
  for col = 1, width do
    column_values[col], column_presence[col] = {}, {}
  end
  for _, row in ipairs(rows) do
    for col = 1, width do
      local value = col <= #row and model.clone_value(row[col]) or model.null_value()
      column_values[col][#column_values[col] + 1] = value
      column_presence[col][#column_presence[col] + 1] = value.kind ~= model.VALUE_NULL
    end
  end
  local columns = {}
  for col = 1, width do
    local null_strategy, presence, has_presence =
      M.column_null_strategy_local(column_values[col], column_presence[col])
    local codec_id, tvd = M.infer_column_codec_and_values(M.strip_nulls_local(column_values[col]))
    columns[col] = {
      field_id = col - 1,
      null_strategy = null_strategy,
      presence = presence or {},
      has_presence = has_presence,
      codec = codec_id,
      dictionary_id = nil,
      values = tvd,
    }
  end
  return columns
end

function M.typed_data_i64(data)
  local tvd = model.typed_vector_data(model.ELEMENT_TYPE_I64)
  for i = 1, #data do tvd.i64s[i] = data[i] end
  return tvd
end

function M.typed_data_u64(data)
  local tvd = model.typed_vector_data(model.ELEMENT_TYPE_U64)
  for i = 1, #data do tvd.u64s[i] = data[i] & model.MAX_U64 end
  return tvd
end

function M.typed_data_f64(data)
  local tvd = model.typed_vector_data(model.ELEMENT_TYPE_F64)
  for i = 1, #data do tvd.f64s[i] = data[i] end
  return tvd
end

function M.typed_data_bool(data)
  local tvd = model.typed_vector_data(model.ELEMENT_TYPE_BOOL)
  for i = 1, #data do tvd.bools[i] = data[i] end
  return tvd
end

function M.typed_data_string(data)
  local tvd = model.typed_vector_data(model.ELEMENT_TYPE_STRING)
  for i = 1, #data do tvd.strings[i] = data[i] end
  return tvd
end

function M.infer_column_codec_and_values(values)
  if #values == 0 then
    return model.VECTOR_CODEC_PLAIN, model.typed_vector_data(model.ELEMENT_TYPE_VALUE)
  end
  local kind = values[1].kind
  for i = 2, #values do
    if values[i].kind ~= kind then kind = nil; break end
  end
  if kind == model.VALUE_I64 then
    local data = {}
    for i = 1, #values do data[i] = values[i].i64 end
    return M.select_integer_codec(data), M.typed_data_i64(data)
  end
  if kind == model.VALUE_U64 then
    local data = {}
    for i = 1, #values do data[i] = values[i].u64 end
    return M.select_u64_codec(data), M.typed_data_u64(data)
  end
  if kind == model.VALUE_F64 then
    local data = {}
    for i = 1, #values do data[i] = values[i].f64 end
    return M.select_float_codec(data), M.typed_data_f64(data)
  end
  if kind == model.VALUE_BOOL then
    local data = {}
    for i = 1, #values do data[i] = values[i].bool end
    return model.VECTOR_CODEC_DIRECT_BITPACK, M.typed_data_bool(data)
  end
  if kind == model.VALUE_STRING then
    local data = {}
    for i = 1, #values do data[i] = values[i].str end
    return M.select_string_codec(data), M.typed_data_string(data)
  end
  local cloned = {}
  for i = 1, #values do cloned[i] = model.clone_value(values[i]) end
  local tvd = model.typed_vector_data(model.ELEMENT_TYPE_VALUE)
  tvd.values = cloned
  return model.VECTOR_CODEC_PLAIN, tvd
end

function M.deltas(values)
  local out = {}
  for i = 1, #values do
    out[i] = i == 1 and values[i] or (values[i] - values[i - 1])
  end
  return out
end

function M.run_stats(values)
  if #values == 0 then return 0.0, 0.0 end
  local runs, run_len = {}, 1
  for i = 2, #values do
    if values[i] == values[i - 1] then
      run_len = run_len + 1
    else
      runs[#runs + 1] = run_len
      run_len = 1
    end
  end
  runs[#runs + 1] = run_len
  local repeated = 0
  for _, r in ipairs(runs) do if r > 1 then repeated = repeated + r end end
  local total_run = 0
  for _, r in ipairs(runs) do total_run = total_run + r end
  return repeated / #values, total_run / #runs
end

function M.run_stats_u64(values)
  return M.run_stats(values)
end

function M.bit_width_signed(min_v, max_v)
  local range_val = max_v >= min_v and (max_v - min_v) or (min_v - max_v)
  return M.bit_width_u64(range_val)
end

function M.select_integer_codec(values)
  if #values < 4 then return model.VECTOR_CODEC_PLAIN end
  local delta_vals = M.deltas(values)
  local dd = M.deltas(delta_vals)
  local non_zero_dd = 0
  for i = 2, #dd do if dd[i] ~= 0 then non_zero_dd = non_zero_dd + 1 end end
  local non_zero_ratio = #dd > 1 and (non_zero_dd / (#dd - 1)) or 0.0
  local min_d, max_d = delta_vals[1], delta_vals[1]
  for i = 2, #delta_vals do
    min_d = math.min(min_d, delta_vals[i])
    max_d = math.max(max_d, delta_vals[i])
  end
  local delta_range_bits = M.bit_width_signed(min_d, max_d)
  if #values >= 8 and (non_zero_ratio <= 0.25 or delta_range_bits <= 2) then
    return model.VECTOR_CODEC_DELTA_DELTA_BITPACK
  end
  local repeated_ratio, avg_run = M.run_stats(values)
  if repeated_ratio >= 0.5 and avg_run >= 3.0 then return model.VECTOR_CODEC_RLE end
  local min_v, max_v = values[1], values[1]
  for i = 2, #values do
    min_v = math.min(min_v, values[i])
    max_v = math.max(max_v, values[i])
  end
  local range_bits = M.bit_width_signed(min_v, max_v)
  if range_bits <= 60 then return model.VECTOR_CODEC_FOR_BITPACK end
  local monotonic = true
  for i = 2, #values do
    if values[i] < values[i - 1] then monotonic = false; break end
  end
  if #values >= 8 and monotonic and delta_range_bits <= range_bits - 3 then
    return model.VECTOR_CODEC_DELTA_FOR_BITPACK
  end
  local max_abs = 0
  for i = 1, #delta_vals do
    max_abs = math.max(max_abs, M.bit_width_u64(M.abs64(delta_vals[i])))
  end
  if max_abs <= 61 then return model.VECTOR_CODEC_DELTA_BITPACK end
  local max_bit = 0
  for i = 1, #values do max_bit = math.max(max_bit, M.bit_width_u64(M.abs64(values[i]))) end
  if #values >= 8 and max_bit <= 16 and not monotonic then return model.VECTOR_CODEC_SIMPLE8B end
  if max_bit < 64 then return model.VECTOR_CODEC_DIRECT_BITPACK end
  return model.VECTOR_CODEC_PLAIN
end

function M.select_u64_codec(values)
  local all_signed = true
  for i = 1, #values do
    if values[i] > 0x7FFFFFFFFFFFFFFF then all_signed = false; break end
  end
  if all_signed then
    local signed = {}
    for i = 1, #values do signed[i] = values[i] & 0x7FFFFFFFFFFFFFFF end
    return M.select_integer_codec(signed)
  end
  if #values < 4 then return model.VECTOR_CODEC_DIRECT_BITPACK end
  local repeated_ratio, avg_run = M.run_stats_u64(values)
  if repeated_ratio >= 0.5 and avg_run >= 3.0 then return model.VECTOR_CODEC_RLE end
  local min_v, max_v = values[1], values[1]
  for i = 2, #values do
    min_v = math.min(min_v, values[i])
    max_v = math.max(max_v, values[i])
  end
  if M.bit_width_u64(max_v - min_v) <= 60 then return model.VECTOR_CODEC_FOR_BITPACK end
  local max_width = 0
  for i = 1, #values do max_width = math.max(max_width, M.bit_width_u64(values[i])) end
  if #values >= 8 and max_width <= 16 then return model.VECTOR_CODEC_SIMPLE8B end
  if max_width < 64 then return model.VECTOR_CODEC_DIRECT_BITPACK end
  return model.VECTOR_CODEC_PLAIN
end

function M.select_float_codec(values)
  if #values < 4 then return model.VECTOR_CODEC_PLAIN end
  local changes, prev = 0, string.unpack("<I8", string.pack("<d", values[1]))
  for i = 2, #values do
    local bits = string.unpack("<I8", string.pack("<d", values[i]))
    if bits ~= prev then changes = changes + 1 end
    prev = bits
  end
  if changes * 2 <= #values then return model.VECTOR_CODEC_XOR_FLOAT end
  return model.VECTOR_CODEC_PLAIN
end

function M.select_string_codec(values)
  if #values == 0 then return model.VECTOR_CODEC_PLAIN end
  local uniq = {}
  for i = 1, #values do uniq[values[i]] = true end
  local nuniq = 0
  for _ in pairs(uniq) do nuniq = nuniq + 1 end
  if nuniq * 2 <= #values then return model.VECTOR_CODEC_DICTIONARY end
  local prefix_gain, prev = 0, ""
  for i = 1, #values do
    prefix_gain = prefix_gain + M.common_prefix_len(prev, values[i])
    prev = values[i]
  end
  if prefix_gain > #values * 2 then return model.VECTOR_CODEC_PREFIX_DELTA end
  return model.VECTOR_CODEC_PLAIN
end

function M.common_prefix_len(a, b)
  local n = math.min(#a, #b)
  local i = 0
  while i < n do
    local ai = string.byte(a, i + 1)
    local bi = string.byte(b, i + 1)
    if ai ~= bi then break end
    i = i + 1
  end
  return i
end

function M.rle_encode_bytes(input)
  if #input == 0 then return nil end
  local out = {}
  local i = 1
  while i <= #input do
    local j = i + 1
    local bi = string.byte(input, i)
    while j <= #input and string.byte(input, j) == bi and j - i < 255 do j = j + 1 end
    out[#out + 1] = string.char(j - i)
    out[#out + 1] = string.char(bi)
    i = j
  end
  return table.concat(out)
end

function M.rle_decode_bytes(input)
  local out = {}
  local i = 1
  while i <= #input do
    if i + 1 > #input then errors.raise(errors.invalid_data("rle payload")) end
    local run = string.byte(input, i)
    local b = string.byte(input, i + 1)
    for _ = 1, run do out[#out + 1] = string.char(b) end
    i = i + 2
  end
  return table.concat(out)
end

function M.control_bitpack_encode_bytes(input) return input end
function M.control_bitpack_decode_bytes(input) return input end
function M.control_huffman_encode_bytes(input) return input end
function M.control_huffman_decode_bytes(input) return input end
function M.control_fse_encode_bytes(input) return input end
function M.control_fse_decode_bytes(input) return input end

function M.template_descriptor_from_columns(template_id, columns)
  local field_ids, null_strategies, codecs = {}, {}, {}
  for i = 1, #columns do
    field_ids[i] = columns[i].field_id
    null_strategies[i] = columns[i].null_strategy
    codecs[i] = columns[i].codec
  end
  return {
    template_id = template_id,
    field_ids = field_ids,
    null_strategies = null_strategies,
    codecs = codecs,
  }
end

function M.find_template_id(templates, columns)
  local ids = {}
  for id in pairs(templates) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = templates[id]
    if #t.field_ids == #columns then
      local ok = true
      for i = 1, #columns do
        if t.field_ids[i] ~= columns[i].field_id or t.null_strategies[i] ~= columns[i].null_strategy then
          ok = false
          break
        end
      end
      if ok then return id, true end
    end
  end
  return 0, false
end

function M.diff_template_columns(previous, current)
  local mask, changed = {}, {}
  for i = 1, #current do
    if i > #previous or M.estimate_column_size(previous[i]) ~= M.estimate_column_size(current[i]) then
      mask[i] = true
      changed[#changed + 1] = current[i]
    else
      mask[i] = false
    end
  end
  return mask, changed
end

function M.merge_template_columns(previous, changed_mask, changed)
  local out, idx = {}, 1
  for i = 1, #changed_mask do
    if changed_mask[i] then
      if idx > #changed then errors.raise(errors.invalid_data("template changed column count mismatch")) end
      out[i] = changed[idx]
      idx = idx + 1
    else
      if i > #previous then errors.raise(errors.invalid_data("template reference out of range")) end
      out[i] = previous[i]
    end
  end
  return out
end

function M.message_fields(message)
  if message.kind == model.MESSAGE_KIND_ARRAY then
    local out = {}
    for i = 1, #message.array do out[i] = model.clone_value(message.array[i]) end
    return out
  end
  if message.kind == model.MESSAGE_KIND_MAP then
    local out = {}
    for i = 1, #message.map do out[i] = model.clone_value(message.map[i].value) end
    return out
  end
  if message.kind == model.MESSAGE_KIND_SHAPED_OBJECT then
    local out = {}
    for i = 1, #message.shaped_object.values do
      out[i] = model.clone_value(message.shaped_object.values[i])
    end
    return out
  end
  if message.kind == model.MESSAGE_KIND_SCHEMA_OBJECT then
    local out = {}
    for i = 1, #message.schema_object.fields do
      out[i] = model.clone_value(message.schema_object.fields[i])
    end
    return out
  end
  return {}
end

function M.diff_message(prev, current)
  local a, b = M.message_fields(prev), M.message_fields(current)
  local n = math.max(#a, #b)
  local ops = {}
  for i = 1, n do
    if i <= #a and i <= #b then
      if model.equal(a[i], b[i]) then
        ops[#ops + 1] = { field_id = i - 1, opcode = model.PATCH_OPCODE_KEEP, value = nil }
      else
        ops[#ops + 1] = {
          field_id = i - 1,
          opcode = model.PATCH_OPCODE_REPLACE_SCALAR,
          value = model.clone_value(b[i]),
        }
      end
    elseif i <= #b then
      ops[#ops + 1] = {
        field_id = i - 1,
        opcode = model.PATCH_OPCODE_INSERT_FIELD,
        value = model.clone_value(b[i]),
      }
    else
      ops[#ops + 1] = { field_id = i - 1, opcode = model.PATCH_OPCODE_DELETE_FIELD, value = nil }
    end
  end
  return ops, 0
end

function M.rebuild_message_like(base, fields)
  if base.kind == model.MESSAGE_KIND_ARRAY then
    return model.message({ kind = model.MESSAGE_KIND_ARRAY, array = fields })
  end
  if base.kind == model.MESSAGE_KIND_MAP then
    local entries = {}
    for i = 1, #fields do
      if i > #base.map then errors.raise(errors.invalid_data("patch map shape mismatch")) end
      entries[i] = { key = base.map[i].key, value = fields[i] }
    end
    return model.message({ kind = model.MESSAGE_KIND_MAP, map = entries })
  end
  if base.kind == model.MESSAGE_KIND_SHAPED_OBJECT then
    local s = base.shaped_object
    return model.message({
      kind = model.MESSAGE_KIND_SHAPED_OBJECT,
      shaped_object = {
        shape_id = s.shape_id,
        presence = s.presence,
        has_presence = s.has_presence,
        values = fields,
      },
    })
  end
  if base.kind == model.MESSAGE_KIND_SCHEMA_OBJECT then
    local s = base.schema_object
    return model.message({
      kind = model.MESSAGE_KIND_SCHEMA_OBJECT,
      schema_object = {
        schema_id = s.schema_id,
        presence = s.presence,
        has_presence = s.has_presence,
        fields = fields,
      },
    })
  end
  errors.raise(errors.invalid_data("state patch reconstruction unsupported for this message kind"))
end

function M.varuint_size(value)
  local sz = 1
  while value >= 0x80 do
    value = value >> 7
    sz = sz + 1
  end
  return sz
end

function M.smallest_u64_size(value)
  if value <= 0xFF then return 1 end
  if value <= 0xFFFF then return 2 end
  if value <= 0xFFFFFFFF then return 4 end
  return 8
end

function M.encoded_bytes_size(length)
  return M.varuint_size(length) + length
end

function M.encoded_string_size(value)
  return M.encoded_bytes_size(#value)
end

function M.encoded_key_ref_size(key)
  if key.is_id then return 1 + M.varuint_size(key.id) end
  return M.encoded_string_size(key.literal)
end

function M.estimate_value_size(value)
  if value.kind == model.VALUE_NULL or value.kind == model.VALUE_BOOL then return 1 end
  if value.kind == model.VALUE_I64 then
    return 2 + M.smallest_u64_size(wire.encode_zigzag(value.i64))
  end
  if value.kind == model.VALUE_U64 then
    return 2 + M.smallest_u64_size(value.u64)
  end
  if value.kind == model.VALUE_F64 then return 9 end
  if value.kind == model.VALUE_STRING then return 2 + M.encoded_string_size(value.str) end
  if value.kind == model.VALUE_BINARY then return 1 + M.encoded_bytes_size(#value.bin) end
  if value.kind == model.VALUE_ARRAY then
    local total = 1 + M.varuint_size(#value.arr)
    for i = 1, #value.arr do total = total + M.estimate_value_size(value.arr[i]) end
    return total
  end
  if value.kind == model.VALUE_MAP then
    local total = 1 + M.varuint_size(#value.map)
    for i = 1, #value.map do
      total = total + M.encoded_string_size(value.map[i].key) + M.estimate_value_size(value.map[i].value)
    end
    return total
  end
  return 1
end

function M.estimate_message_size(message)
  if message.kind == model.MESSAGE_KIND_SCALAR then
    return 1 + M.estimate_value_size(message.scalar)
  end
  if message.kind == model.MESSAGE_KIND_ARRAY then
    local total = 1 + M.varuint_size(#message.array)
    for i = 1, #message.array do total = total + M.estimate_value_size(message.array[i]) end
    return total
  end
  if message.kind == model.MESSAGE_KIND_MAP then
    local total = 1 + M.varuint_size(#message.map)
    for i = 1, #message.map do
      total = total + M.encoded_key_ref_size(message.map[i].key) + M.estimate_value_size(message.map[i].value)
    end
    return total
  end
  if message.kind == model.MESSAGE_KIND_STATE_PATCH then
    local sp = message.state_patch
    local total = 1 + 2 + M.varuint_size(#sp.operations)
    for i = 1, #sp.operations do
      local op = sp.operations[i]
      total = total + M.varuint_size(op.field_id) + 2
      if op.value then total = total + M.estimate_value_size(op.value) end
    end
    return total
  end
  return 16
end

function M.estimate_column_size(column)
  local size = M.varuint_size(column.field_id) + 4
  local vk = column.values.kind
  if vk == model.ELEMENT_TYPE_BOOL then
    size = size + math.floor(#column.values.bools / 8) + 2
  elseif vk == model.ELEMENT_TYPE_I64 then
    size = size + #column.values.i64s * 4
  elseif vk == model.ELEMENT_TYPE_U64 then
    size = size + #column.values.u64s * 4
  elseif vk == model.ELEMENT_TYPE_F64 then
    size = size + #column.values.f64s * 8
  elseif vk == model.ELEMENT_TYPE_STRING then
    for i = 1, #column.values.strings do
      size = size + M.encoded_string_size(column.values.strings[i])
    end
  end
  return size
end

function M.key_ref_string(key, state)
  if key.is_id then
    local s, ok = session.intern_get_value(state.key_table, key.id)
    return ok and s or ""
  end
  return key.literal
end

function M.key_ref_field_identity(key, state)
  local s = M.key_ref_string(key, state)
  if s == "" then return nil end
  return s
end

-- protocol.rb module-level helpers (also used by protocol.lua)
function M.typed_vector_len(data)
  if data.kind == model.ELEMENT_TYPE_BOOL then return #data.bools end
  if data.kind == model.ELEMENT_TYPE_I64 then return #data.i64s end
  if data.kind == model.ELEMENT_TYPE_U64 then return #data.u64s end
  if data.kind == model.ELEMENT_TYPE_F64 then return #data.f64s end
  if data.kind == model.ELEMENT_TYPE_STRING then return #data.strings end
  if data.kind == model.ELEMENT_TYPE_BINARY then return #data.binary end
  if data.kind == model.ELEMENT_TYPE_VALUE then return #data.values end
  return 0
end

function M.lookup_map_field(value, key)
  if value.kind ~= model.VALUE_MAP then return nil end
  for i = 1, #value.map do
    if value.map[i].key == key then return model.clone_value(value.map[i].value) end
  end
  return nil
end

function M.schema_present_field_indices(schema, presence, has_presence)
  if not has_presence then
    local out = {}
    for i = 1, #schema.fields do out[i] = i - 1 end
    return out
  end
  if #presence ~= #schema.fields then
    errors.raise(errors.invalid_data("presence bitmap mismatch for schema"))
  end
  local out = {}
  for i = 1, #schema.fields do
    if presence[i] then out[#out + 1] = i - 1 end
  end
  return out
end

function M.normalized_logical_type(raw)
  return string.lower(string.gsub(raw, "^%s*(.-)%s*$", "%1"))
end

function M.rows_from_values(values)
  local rows = {}
  for i = 1, #values do
    local v = values[i]
    if v.kind == model.VALUE_ARRAY then
      local row = {}
      for j = 1, #v.arr do row[j] = model.clone_value(v.arr[j]) end
      rows[#rows + 1] = row
    else
      rows[#rows + 1] = { model.clone_value(v) }
    end
  end
  return rows
end

function M.column_null_strategy(values, present_bits)
  return M.column_null_strategy_local(values, present_bits)
end

function M.strip_nulls(values)
  return M.strip_nulls_local(values)
end

function M.columns_from_map_values(values)
  if #values == 0 then return nil end
  for i = 1, #values do
    if values[i].kind ~= model.VALUE_MAP then return nil end
  end
  local key_order, key_index = {}, {}
  local column_values, column_presence = {}, {}
  for row_idx = 1, #values do
    local row = values[row_idx]
    local present = {}
    for k = 1, #key_order do present[k] = false end
    for j = 1, #row.map do
      local e = row.map[j]
      local key = e.key
      local entry_value = model.clone_value(e.value)
      local col_idx = key_index[key]
      if not col_idx then
        col_idx = #key_order + 1
        key_order[col_idx] = key
        key_index[key] = col_idx
        column_values[col_idx] = {}
        column_presence[col_idx] = {}
        for r = 1, row_idx - 1 do
          column_values[col_idx][r] = model.null_value()
          column_presence[col_idx][r] = false
        end
        present[col_idx] = false
      end
      column_values[col_idx][row_idx] = entry_value
      column_presence[col_idx][row_idx] = true
      present[col_idx] = true
    end
    for col_idx = 1, #key_order do
      if not present[col_idx] then
        column_values[col_idx][row_idx] = model.null_value()
        column_presence[col_idx][row_idx] = false
      end
    end
  end
  local columns = {}
  for field_id = 1, #key_order do
    local col_values = column_values[field_id]
    local present_bits = column_presence[field_id]
    local null_strategy, presence, has_presence =
      M.column_null_strategy(col_values, present_bits)
    local codec_id, tvd = M.infer_column_codec_and_values(M.strip_nulls(col_values))
    columns[field_id] = {
      field_id = field_id - 1,
      null_strategy = null_strategy,
      presence = presence or {},
      has_presence = has_presence,
      codec = codec_id,
      values = tvd,
    }
  end
  return columns
end

function M.has_uniform_micro_batch_shape(values)
  if #values == 0 or values[1].kind ~= model.VALUE_MAP then return false end
  local keys = {}
  for i = 1, #values[1].map do keys[i] = values[1].map[i].key end
  for vi = 2, #values do
    local v = values[vi]
    if v.kind ~= model.VALUE_MAP or #v.map ~= #keys then return false end
    for j = 1, #keys do
      if v.map[j].key ~= keys[j] then return false end
    end
  end
  return true
end

function M.should_register_shape(keys, observed_count)
  return #keys > 0 and observed_count >= 2
end

function M.supports_state_patch(base, current)
  if not base then return false end
  if base.kind ~= current.kind then return false end
  return base.kind == model.MESSAGE_KIND_MAP
    or base.kind == model.MESSAGE_KIND_SCHEMA_OBJECT
    or base.kind == model.MESSAGE_KIND_SHAPED_OBJECT
    or base.kind == model.MESSAGE_KIND_ARRAY
end

function M.encoded_size(message)
  return M.estimate_message_size(message)
end

function M.typed_vector_to_value(vector)
  local et = vector.element_type
  local d = vector.data
  if et == model.ELEMENT_TYPE_BOOL then
    local items = {}
    for i = 1, #d.bools do items[i] = model.bool_value(d.bools[i]) end
    return model.array_value(items)
  end
  if et == model.ELEMENT_TYPE_I64 then
    local items = {}
    for i = 1, #d.i64s do items[i] = model.i64_value(d.i64s[i]) end
    return model.array_value(items)
  end
  if et == model.ELEMENT_TYPE_U64 then
    local items = {}
    for i = 1, #d.u64s do items[i] = model.u64_value(d.u64s[i]) end
    return model.array_value(items)
  end
  if et == model.ELEMENT_TYPE_F64 then
    local items = {}
    for i = 1, #d.f64s do items[i] = model.f64_value(d.f64s[i]) end
    return model.array_value(items)
  end
  if et == model.ELEMENT_TYPE_STRING then
    local items = {}
    for i = 1, #d.strings do items[i] = model.string_value(d.strings[i]) end
    return model.array_value(items)
  end
  return model.array_value({})
end

function M.entries_to_map(entries, state)
  local out = {}
  for i = 1, #entries do
    local e = entries[i]
    local key = M.key_ref_string(e.key, state)
    out[#out + 1] = { key = key, value = model.clone_value(e.value) }
    local _, ok = session.intern_get_id(state.key_table, key)
    if not ok then session.intern_register(state.key_table, key) end
  end
  return out
end

function M.shape_values_to_map(keys, presence, has_presence, values)
  local out, idx = {}, 1
  for i = 1, #keys do
    if has_presence and i <= #presence and not presence[i] then goto continue end
    if idx > #values then break end
    out[#out + 1] = { key = keys[i], value = model.clone_value(values[idx]) }
    idx = idx + 1
    ::continue::
  end
  return out
end

function M.write_smallest_u64(value, out)
  value = value & model.MAX_U64
  if value <= 0xFF then
    byte_buffer.append(out, 1)
    byte_buffer.append(out, value)
  elseif value <= 0xFFFF then
    byte_buffer.append(out, 2)
    byte_buffer.append(out, value & 0xFF)
    byte_buffer.append(out, (value >> 8) & 0xFF)
  elseif value <= 0xFFFFFFFF then
    byte_buffer.append(out, 4)
    wire.append_u64_le(out, value)
  else
    byte_buffer.append(out, 8)
    wire.append_u64_le(out, value)
  end
end

function M.read_smallest_u64(reader)
  local size = reader:read_u8()
  if size == 1 then return reader:read_u8() end
  if size == 2 then
    local lo, hi = reader:read_u8(), reader:read_u8()
    return lo | (hi << 8)
  end
  if size == 4 then return wire.read_u64_le(reader) & 0xFFFFFFFF end
  if size == 8 then return wire.read_u64_le(reader) end
  errors.raise(errors.invalid_data("invalid smallest u64 size"))
end
'''

if __name__ == "__main__":
    main()
