local errors = require("twilic.core.errors")
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

function M.encode_v2(value)
  local out = byte_buffer.new()
  local state = new_encode_state()
  M.encode_v2_value(value, out, state)
  return byte_buffer.bytes(out)
end

function M.decode_v2(data)
  local reader = wire.new_reader(data)
  local state = new_decode_state()
  local value = M.decode_v2_value(reader, state)
  if not reader:is_eof() then
    errors.raise(errors.invalid_data("trailing bytes in v2 decode"))
  end
  return value
end

function M.encode_v2_value(value, out, state)
  local k = value.kind
  if k == model.VALUE_NULL then
    byte_buffer.append(out, M.NULL_TAG)
  elseif k == model.VALUE_BOOL then
    byte_buffer.append(out, value.bool and M.TRUE_TAG or M.FALSE_TAG)
  elseif k == model.VALUE_I64 then
    M.encode_v2_i64(value.i64, out)
  elseif k == model.VALUE_U64 then
    M.encode_v2_u64(value.u64, out)
  elseif k == model.VALUE_F64 then
    byte_buffer.append(out, M.F64_TAG)
    wire.append_f64_le(out, value.f64)
  elseif k == model.VALUE_STRING then
    local ref_id = state.str_ids[value.str]
    if ref_id then
      byte_buffer.append(out, M.STR_REF_TAG)
      wire.encode_varuint(ref_id, out)
    else
      M.encode_v2_string_literal(value.str, out)
      state.str_ids[value.str] = state.next_str_id
      state.next_str_id = state.next_str_id + 1
    end
  elseif k == model.VALUE_BINARY then
    M.encode_v2_binary(value.bin, out)
  elseif k == model.VALUE_ARRAY then
    M.encode_v2_array(value.arr, out, state)
  elseif k == model.VALUE_MAP then
    M.encode_v2_map(value.map, out, state)
  else
    errors.raise(errors.invalid_data("unsupported value kind"))
  end
end

function M.encode_v2_array(values, out, state)
  local shape_keys = M.detect_shape_keys(values)
  if shape_keys then
    local sk = session.shape_key(shape_keys)
    if not state.shape_ids[sk] then
      state.shape_ids[sk] = state.next_shape_id
      state.next_shape_id = state.next_shape_id + 1
    end
    local shape_id = state.shape_ids[sk]
    M.write_v2_array_header(#values, out)
    byte_buffer.append(out, M.SHAPE_DEF_TAG)
    wire.encode_varuint(shape_id, out)
    wire.encode_varuint(#shape_keys, out)
    for i = 1, #shape_keys do
      M.encode_v2_key(shape_keys[i], out, state)
    end
    for i = 1, #values do
      local value = values[i]
      if value.kind ~= model.VALUE_MAP then
        errors.raise(errors.invalid_data("shape array row must be map"))
      end
      for j = 1, #value.map do
        M.encode_v2_value(value.map[j].value, out, state)
      end
    end
    return
  end
  M.write_v2_array_header(#values, out)
  for i = 1, #values do
    M.encode_v2_value(values[i], out, state)
  end
end

function M.encode_v2_map(entries, out, state)
  M.write_v2_map_header(#entries, out)
  for i = 1, #entries do
    M.encode_v2_key(entries[i].key, out, state)
    M.encode_v2_value(entries[i].value, out, state)
  end
end

function M.encode_v2_key(key, out, state)
  local ref_id = state.key_ids[key]
  if ref_id then
    byte_buffer.append(out, M.KEY_REF_TAG)
    wire.encode_varuint(ref_id, out)
    return
  end
  M.encode_v2_string_literal(key, out)
  state.key_ids[key] = state.next_key_id
  state.next_key_id = state.next_key_id + 1
end

function M.encode_v2_string_literal(value, out)
  local length = #value
  if length <= 31 then
    byte_buffer.append(out, 0x80 | length)
  elseif length <= 0xFF then
    byte_buffer.append(out, M.STR8_TAG)
    byte_buffer.append(out, length)
  elseif length <= 0xFFFF then
    byte_buffer.append(out, M.STR16_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
  else
    byte_buffer.append(out, M.STR32_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
    byte_buffer.append(out, (length >> 16) & 0xFF)
    byte_buffer.append(out, (length >> 24) & 0xFF)
  end
  byte_buffer.append_bytes(out, value)
end

function M.encode_v2_binary(value, out)
  local length = #value
  if length <= 0xFF then
    byte_buffer.append(out, M.BIN8_TAG)
    byte_buffer.append(out, length)
  elseif length <= 0xFFFF then
    byte_buffer.append(out, M.BIN16_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
  else
    byte_buffer.append(out, M.BIN32_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
    byte_buffer.append(out, (length >> 16) & 0xFF)
    byte_buffer.append(out, (length >> 24) & 0xFF)
  end
  byte_buffer.append_bytes(out, value)
end

function M.encode_v2_u64(value, out)
  value = value & model.MAX_U64
  if value <= 127 then
    byte_buffer.append(out, value)
  elseif value <= 0xFF then
    byte_buffer.append(out, M.U8_TAG)
    byte_buffer.append(out, value)
  elseif value <= 0xFFFF then
    byte_buffer.append(out, M.U16_TAG)
    byte_buffer.append(out, value & 0xFF)
    byte_buffer.append(out, (value >> 8) & 0xFF)
  elseif value <= 0xFFFFFFFF then
    byte_buffer.append(out, M.U32_TAG)
    byte_buffer.append(out, value & 0xFF)
    byte_buffer.append(out, (value >> 8) & 0xFF)
    byte_buffer.append(out, (value >> 16) & 0xFF)
    byte_buffer.append(out, (value >> 24) & 0xFF)
  else
    byte_buffer.append(out, M.U64_TAG)
    wire.append_u64_le(out, value)
  end
end

function M.encode_v2_i64(value, out)
  if value >= -32 and value <= -1 then
    byte_buffer.append(out, value & 0xFF)
  elseif value >= 0 and value <= 127 then
    byte_buffer.append(out, value)
  elseif value >= -128 and value <= 127 then
    byte_buffer.append(out, M.I8_TAG)
    byte_buffer.append(out, value & 0xFF)
  elseif value >= -32768 and value <= 32767 then
    byte_buffer.append(out, M.I16_TAG)
    byte_buffer.append_bytes(out, string.pack("<i2", value))
  elseif value >= -2147483648 and value <= 2147483647 then
    byte_buffer.append(out, M.I32_TAG)
    byte_buffer.append_bytes(out, string.pack("<i4", value))
  else
    byte_buffer.append(out, M.I64_TAG)
    wire.append_u64_le(out, value & model.MAX_U64)
  end
end

function M.write_v2_array_header(length, out)
  if length <= 15 then
    byte_buffer.append(out, 0xA0 | length)
  elseif length <= 0xFFFF then
    byte_buffer.append(out, M.ARRAY16_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
  else
    byte_buffer.append(out, M.ARRAY32_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
    byte_buffer.append(out, (length >> 16) & 0xFF)
    byte_buffer.append(out, (length >> 24) & 0xFF)
  end
end

function M.write_v2_map_header(length, out)
  if length <= 15 then
    byte_buffer.append(out, 0xB0 | length)
  elseif length <= 0xFFFF then
    byte_buffer.append(out, M.MAP16_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
  else
    byte_buffer.append(out, M.MAP32_TAG)
    byte_buffer.append(out, length & 0xFF)
    byte_buffer.append(out, (length >> 8) & 0xFF)
    byte_buffer.append(out, (length >> 16) & 0xFF)
    byte_buffer.append(out, (length >> 24) & 0xFF)
  end
end

function M.detect_shape_keys(values)
  if #values < 2 then return nil end
  if values[1].kind ~= model.VALUE_MAP or #values[1].map == 0 then return nil end
  local keys = {}
  for i = 1, #values[1].map do keys[i] = values[1].map[i].key end
  for vi = 2, #values do
    local value = values[vi]
    if value.kind ~= model.VALUE_MAP or #value.map ~= #keys then return nil end
    for i = 1, #keys do
      if value.map[i].key ~= keys[i] then return nil end
    end
  end
  return keys
end

function M.decode_v2_value(reader, state)
  return M.decode_v2_value_from_tag(reader, state, reader:read_u8())
end

local function read_le_u16(reader)
  local b = reader:read_exact(2)
  return string.byte(b, 1) | (string.byte(b, 2) << 8)
end

local function read_le_u32(reader)
  local b = reader:read_exact(4)
  return string.byte(b, 1) | (string.byte(b, 2) << 8) | (string.byte(b, 3) << 16) | (string.byte(b, 4) << 24)
end

function M.decode_v2_value_from_tag(reader, state, tag)
  if tag <= 0x7F then
    return model.u64_value(tag)
  end
  if tag >= 0x80 and tag <= 0x9F then
    local length = tag & 0x1F
    local s = reader:read_exact(length)
    state.strings[#state.strings + 1] = s
    return model.string_value(s)
  end
  if tag >= 0xA0 and tag <= 0xAF then
    return M.decode_v2_array_body(reader, state, tag & 0x0F)
  end
  if tag >= 0xB0 and tag <= 0xBF then
    return M.decode_v2_map_body(reader, state, tag & 0x0F)
  end
  if tag >= 0xE0 then
    return model.i64_value(tag < 128 and tag or tag - 256)
  end
  if tag == M.NULL_TAG then return model.null_value() end
  if tag == M.FALSE_TAG then return model.bool_value(false) end
  if tag == M.TRUE_TAG then return model.bool_value(true) end
  if tag == M.F64_TAG then return model.f64_value(wire.read_f64_le(reader)) end
  if tag == M.U8_TAG then return model.u64_value(reader:read_u8()) end
  if tag == M.U16_TAG then return model.u64_value(read_le_u16(reader)) end
  if tag == M.U32_TAG then return model.u64_value(read_le_u32(reader)) end
  if tag == M.U64_TAG then return model.u64_value(wire.read_u64_le(reader)) end
  if tag == M.I8_TAG then
    local b = reader:read_u8()
    return model.i64_value(b < 128 and b or b - 256)
  end
  if tag == M.I16_TAG then return model.i64_value(string.unpack("<i2", reader:read_exact(2))) end
  if tag == M.I32_TAG then return model.i64_value(string.unpack("<i4", reader:read_exact(4))) end
  if tag == M.I64_TAG then return model.i64_value(string.unpack("<i8", reader:read_exact(8))) end
  if tag == M.BIN8_TAG then return model.binary_value(reader:read_exact(reader:read_u8())) end
  if tag == M.BIN16_TAG then return model.binary_value(reader:read_exact(read_le_u16(reader))) end
  if tag == M.BIN32_TAG then return model.binary_value(reader:read_exact(read_le_u32(reader))) end
  if tag == M.STR8_TAG or tag == M.STR16_TAG or tag == M.STR32_TAG then
    return M.decode_v2_string_tag(reader, state, tag)
  end
  if tag == M.ARRAY16_TAG then return M.decode_v2_array_body(reader, state, read_le_u16(reader)) end
  if tag == M.ARRAY32_TAG then return M.decode_v2_array_body(reader, state, read_le_u32(reader)) end
  if tag == M.MAP16_TAG then return M.decode_v2_map_body(reader, state, read_le_u16(reader)) end
  if tag == M.MAP32_TAG then return M.decode_v2_map_body(reader, state, read_le_u32(reader)) end
  if tag == M.STR_REF_TAG then
    local ref_id = reader:read_varuint()
    if ref_id >= #state.strings then
      errors.raise(errors.invalid_data("unknown str_ref id"))
    end
    return model.string_value(state.strings[ref_id + 1])
  end
  errors.raise(errors.invalid_tag(tag))
end

function M.decode_v2_string_tag(reader, state, tag)
  local length
  if tag == M.STR8_TAG then
    length = reader:read_u8()
  elseif tag == M.STR16_TAG then
    length = read_le_u16(reader)
  elseif tag == M.STR32_TAG then
    length = read_le_u32(reader)
  else
    errors.raise(errors.invalid_data("invalid string tag"))
  end
  local s = reader:read_exact(length)
  state.strings[#state.strings + 1] = s
  return model.string_value(s)
end

function M.decode_v2_array_body(reader, state, length)
  reader:claim_output(length)
  return reader:with_depth(function() return M.decode_v2_array_body_inner(reader, state, length) end)
end

function M.decode_v2_array_body_inner(reader, state, length)
  if length == 0 then return model.array_value({}) end
  local first_tag = reader:read_u8()
  if first_tag == M.SHAPE_DEF_TAG then
    local shape_id = reader:read_count(65535)
    local key_count = reader:read_count(256)
    local keys = {}
    for i = 1, key_count do keys[i] = M.decode_v2_key(reader, state) end
    state.shapes[shape_id + 1] = keys
    local values = {}
    for i = 1, length do
      reader:claim_output(#keys)
      local row = {}
      for j = 1, #keys do
        row[j] = model.entry(keys[j], M.decode_v2_value(reader, state))
      end
      values[i] = model.map_value(row)
    end
    return model.array_value(values)
  end
  local values = { M.decode_v2_value_from_tag(reader, state, first_tag) }
  for i = 2, length do values[i] = M.decode_v2_value(reader, state) end
  return model.array_value(values)
end

function M.decode_v2_map_body(reader, state, length)
  reader:claim_output(length)
  return reader:with_depth(function() return M.decode_v2_map_body_inner(reader, state, length) end)
end

function M.decode_v2_map_body_inner(reader, state, length)
  local entries = {}
  for i = 1, length do
    entries[i] = model.entry(M.decode_v2_key(reader, state), M.decode_v2_value(reader, state))
  end
  return model.map_value(entries)
end

function M.decode_v2_key(reader, state)
  local tag = reader:read_u8()
  if tag == M.KEY_REF_TAG then
    local ref_id = reader:read_varuint()
    if ref_id >= #state.keys then
      errors.raise(errors.invalid_data("unknown key_ref id"))
    end
    return state.keys[ref_id + 1]
  end
  if tag >= 0x80 and tag <= 0x9F then
    local length = tag & 0x1F
    local key = reader:read_exact(length)
    state.keys[#state.keys + 1] = key
    return key
  end
  if tag == M.STR8_TAG or tag == M.STR16_TAG or tag == M.STR32_TAG then
    local v = M.decode_v2_value_from_tag(reader, state, tag)
    if v.kind ~= model.VALUE_STRING then
      errors.raise(errors.invalid_data("expected string key"))
    end
    state.keys[#state.keys + 1] = v.str
    return v.str
  end
  errors.raise(errors.invalid_data("map key must be key_ref or string"))
end

return M
