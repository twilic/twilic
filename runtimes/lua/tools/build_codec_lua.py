#!/usr/bin/env python3
"""Emit a loadable twilic.core.codec module (full logic from twilic-python)."""
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "src" / "twilic" / "core" / "codec.lua"

# Hand-translated from twilic-python/src/twilic/codec.py
OUT.write_text(r'''local errors = require("twilic.core.errors")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local byte_buffer = require("twilic.core.byte_buffer")

local M = {}

M.SIMPLE8B_SLOTS = {
  {60,1},{30,2},{20,3},{15,4},{12,5},{10,6},{8,7},{7,8},
  {6,10},{5,12},{4,15},{3,20},{2,30},{1,60},
}
M.MAX_U64 = model.MAX_U64
M.MAX_I64 = model.MAX_I64
M.MIN_I64 = model.MIN_I64

function M.bit_width(v)
  v = v & model.MAX_U64
  if v == 0 then return 1 end
  local bits = 0
  while v > 0 do bits = bits + 1; v = v >> 1 end
  return bits
end

function M.checked_add_u64(a, b)
  local total = a + b
  if total > model.MAX_U64 then return 0, false end
  return total, true
end

function M.checked_add_i64(a, b)
  local total = a + b
  if (b > 0 and total < a) or (b < 0 and total > a) then return 0, false end
  return total, true
end

function M.delta(values)
  local out = {}
  local prev = 0
  for i = 1, #values do
    out[i] = i == 1 and values[i] or (values[i] - prev)
    prev = values[i]
  end
  return out
end

function M.undelta(values)
  local out = {}
  local prev = 0
  for i = 1, #values do
    if i == 1 then
      out[i] = values[i]
      prev = values[i]
    else
      local nxt, ok = M.checked_add_i64(prev, values[i])
      if not ok then errors.raise(errors.invalid_data("delta overflow")) end
      out[i] = nxt
      prev = nxt
    end
  end
  return out
end

function M.encode_u64_plain(values, out)
  wire.encode_varuint(#values, out)
  for i = 1, #values do wire.encode_varuint(values[i], out) end
end

function M.decode_u64_plain(reader)
  local length = reader:read_varuint()
  local out = {}
  for i = 1, length do out[i] = reader:read_varuint() end
  return out
end

function M.encode_i64_plain(values, out)
  wire.encode_varuint(#values, out)
  for i = 1, #values do wire.encode_varuint(wire.encode_zigzag(values[i]), out) end
end

function M.decode_i64_plain(reader)
  local length = reader:read_varuint()
  local out = {}
  for i = 1, length do out[i] = wire.decode_zigzag(reader:read_varuint()) end
  return out
end

function M.pack_u64_values(values, width, out)
  local total_bits = #values * width
  local byte_len = math.floor((total_bits + 7) / 8)
  local bytes = {}
  for i = 1, byte_len do bytes[i] = 0 end
  local bit_pos = 0
  for vi = 1, #values do
    local value = values[vi]
    local written = 0
    while written < width do
      local byte_idx = math.floor(bit_pos / 8) + 1
      local bit_off = bit_pos % 8
      local room = 8 - bit_off
      local take = width - written
      if take > room then take = room end
      local mask = (1 << take) - 1
      local part = (value >> written) & mask
      bytes[byte_idx] = bytes[byte_idx] | (part << bit_off)
      bit_pos = bit_pos + take
      written = written + take
    end
  end
  for i = 1, byte_len do byte_buffer.append(out, bytes[i]) end
end

function M.unpack_u64_values(reader, length, width)
  local total_bits = length * width
  local byte_len = math.floor((total_bits + 7) / 8)
  local raw = reader:read_exact(byte_len)
  local out = {}
  local bit_pos = 0
  for _ = 1, length do
    local value = 0
    local written = 0
    while written < width do
      local byte_idx = math.floor(bit_pos / 8) + 1
      if byte_idx > #raw then errors.raise(errors.invalid_data("bitpack underflow")) end
      local bit_off = bit_pos % 8
      local room = 8 - bit_off
      local take = width - written
      if take > room then take = room end
      local mask = (1 << take) - 1
      local part = (string.byte(raw, byte_idx) >> bit_off) & mask
      value = value | (part << written)
      bit_pos = bit_pos + take
      written = written + take
    end
    out[#out + 1] = value
  end
  return out
end

function M.encode_u64_direct_bitpack(values, out)
  wire.encode_varuint(#values, out)
  if #values == 0 then byte_buffer.append(out, 0); return end
  local width = 1
  for i = 1, #values do
    local bw = M.bit_width(values[i])
    if bw > width then width = bw end
  end
  byte_buffer.append(out, width)
  M.pack_u64_values(values, width, out)
end

function M.decode_u64_direct_bitpack(reader)
  local length = reader:read_varuint()
  local width = reader:read_u8()
  if length == 0 then return {} end
  if width == 0 or width > 64 then errors.raise(errors.invalid_data("bitpack width")) end
  return M.unpack_u64_values(reader, length, width)
end

function M.encode_i64_direct_bitpack(values, out)
  wire.encode_varuint(#values, out)
  if #values == 0 then byte_buffer.append(out, 0); return end
  local encoded = {}
  local width = 1
  for i = 1, #values do
    encoded[i] = wire.encode_zigzag(values[i])
    local bw = M.bit_width(encoded[i])
    if bw > width then width = bw end
  end
  byte_buffer.append(out, width)
  M.pack_u64_values(encoded, width, out)
end

function M.decode_i64_direct_bitpack(reader)
  local length = reader:read_varuint()
  local width = reader:read_u8()
  if length == 0 then return {} end
  if width == 0 or width > 64 then errors.raise(errors.invalid_data("bitpack width")) end
  local encoded = M.unpack_u64_values(reader, length, width)
  local out = {}
  for i = 1, #encoded do out[i] = wire.decode_zigzag(encoded[i]) end
  return out
end

function M.encode_u64_rle(values, out)
  local runs = {}
  for i = 1, #values do
    local value = values[i]
    if #runs > 0 and runs[#runs].value == value then
      runs[#runs].count = runs[#runs].count + 1
    else
      runs[#runs + 1] = { value = value, count = 1 }
    end
  end
  wire.encode_varuint(#runs, out)
  for i = 1, #runs do
    wire.encode_varuint(runs[i].value, out)
    wire.encode_varuint(runs[i].count, out)
  end
end

function M.decode_u64_rle(reader)
  local runs_len = reader:read_varuint()
  local out = {}
  for _ = 1, runs_len do
    local value = reader:read_varuint()
    local count = reader:read_varuint()
    for _ = 1, count do out[#out + 1] = value end
  end
  return out
end

function M.encode_i64_rle(values, out)
  local runs = {}
  for i = 1, #values do
    local value = values[i]
    if #runs > 0 and runs[#runs].value == value then
      runs[#runs].count = runs[#runs].count + 1
    else
      runs[#runs + 1] = { value = value, count = 1 }
    end
  end
  wire.encode_varuint(#runs, out)
  for i = 1, #runs do
    wire.encode_varuint(wire.encode_zigzag(runs[i].value), out)
    wire.encode_varuint(runs[i].count, out)
  end
end

function M.decode_i64_rle(reader)
  local runs_len = reader:read_varuint()
  local out = {}
  for _ = 1, runs_len do
    local value = wire.decode_zigzag(reader:read_varuint())
    local count = reader:read_varuint()
    for _ = 1, count do out[#out + 1] = value end
  end
  return out
end

function M.encode_u64_simple8b_inner(values, out)
  wire.encode_varuint(#values, out)
  if #values == 0 then return end
  local max_value = 0
  for i = 1, #values do if values[i] > max_value then max_value = values[i] end end
  if max_value > ((1 << 60) - 1) then
    byte_buffer.append(out, 0)
    for i = 1, #values do wire.encode_varuint(values[i], out) end
    return
  end
  byte_buffer.append(out, 1)
  local idx = 1
  while idx <= #values do
    local zero_run = 0
    while idx + zero_run <= #values and values[idx + zero_run] == 0 and zero_run < 240 do
      zero_run = zero_run + 1
    end
    if zero_run >= 120 then
      local take = zero_run >= 240 and 240 or 120
      local word = take == 240 and 0 or (1 << 60)
      wire.append_u64_le(out, word)
      idx = idx + take
    else
      local packed = false
      for si, slot in ipairs(M.SIMPLE8B_SLOTS) do
        local count, sw = slot[1], slot[2]
        if idx + count - 1 <= #values then
          local max_enc = (1 << sw) - 1
          local all_fit = true
          for j = 0, count - 1 do
            if values[idx + j] > max_enc then all_fit = false; break end
          end
          if all_fit then
            local selector = si + 1
            local payload = 0
            local shift = 0
            for j = 0, count - 1 do
              payload = payload | (values[idx + j] << shift)
              shift = shift + sw
            end
            local word = ((selector << 60) | payload) & model.MAX_U64
            wire.append_u64_le(out, word)
            idx = idx + count
            packed = true
            break
          end
        end
      end
      if not packed then
        local word = ((15 << 60) | (values[idx] & ((1 << 60) - 1))) & model.MAX_U64
        wire.append_u64_le(out, word)
        idx = idx + 1
      end
    end
  end
end

function M.decode_u64_simple8b_inner(reader)
  local length = reader:read_varuint()
  if length == 0 then return {} end
  local mode = reader:read_u8()
  if mode == 0 then
    local out = {}
    for i = 1, length do out[i] = reader:read_varuint() end
    return out
  end
  if mode ~= 1 then errors.raise(errors.invalid_data("simple8b mode")) end
  local out = {}
  while #out < length do
    local packed = wire.read_u64_le(reader)
    local selector = packed >> 60
    local payload = packed & ((1 << 60) - 1)
    if selector == 0 or selector == 1 then
      local count = selector == 1 and 120 or 240
      local remain = length - #out
      local limit = count < remain and count or remain
      for _ = 1, limit do out[#out + 1] = 0 end
    elseif selector >= 2 and selector <= 15 then
      local count, sw
      if selector == 15 then count, sw = 1, 60
      else count, sw = M.SIMPLE8B_SLOTS[selector - 1][1], M.SIMPLE8B_SLOTS[selector - 1][2] end
      local remain = length - #out
      local limit = count < remain and count or remain
      local shift = 0
      for _ = 1, limit do
        local mask = (1 << sw) - 1
        out[#out + 1] = (payload >> shift) & mask
        shift = shift + sw
      end
    else
      errors.raise(errors.invalid_data("simple8b selector"))
    end
  end
  return out
end

function M.encode_u64_simple8b(values, out) M.encode_u64_simple8b_inner(values, out) end
function M.decode_u64_simple8b(reader) return M.decode_u64_simple8b_inner(reader) end
function M.encode_i64_simple8b(values, out)
  local encoded = {}
  for i = 1, #values do encoded[i] = wire.encode_zigzag(values[i]) end
  M.encode_u64_simple8b_inner(encoded, out)
end
function M.decode_i64_simple8b(reader)
  local encoded = M.decode_u64_simple8b_inner(reader)
  local out = {}
  for i = 1, #encoded do out[i] = wire.decode_zigzag(encoded[i]) end
  return out
end

function M.f64_to_u64(value)
  return string.unpack("<I8", string.pack("<d", value))
end

function M.u64_to_f64(bits)
  return string.unpack("<d", string.pack("<I8", bits))
end

function M.encode_xor_float(values, out)
  wire.encode_varuint(#values, out)
  if #values == 0 then return end
  local first_bits = M.f64_to_u64(values[1])
  wire.append_u64_le(out, first_bits)
  local prev = first_bits
  for i = 2, #values do
    local bits_value = M.f64_to_u64(values[i])
    local x = prev ~ bits_value
    if x == 0 then
      byte_buffer.append(out, 0)
    else
      byte_buffer.append(out, 1)
      local leading, trailing, width = M.leading_zeros64(x), M.trailing_zeros64(x), 64 - (M.leading_zeros64(x) + M.trailing_zeros64(x))
      wire.encode_varuint(leading, out)
      wire.encode_varuint(trailing, out)
      wire.encode_varuint(width, out)
      local payload = width == 64 and x or ((x >> trailing) & ((1 << width) - 1))
      wire.encode_varuint(payload, out)
    end
    prev = bits_value
  end
end

function M.decode_xor_float(reader)
  local length = reader:read_varuint()
  if length == 0 then return {} end
  local first_bits = wire.read_u64_le(reader)
  local out = { M.u64_to_f64(first_bits) }
  local prev = first_bits
  for _ = 2, length do
    local flag = reader:read_u8()
    local bits_value = prev
    if flag ~= 0 then
      local leading = reader:read_varuint()
      local trailing = reader:read_varuint()
      local width = reader:read_varuint()
      local payload = reader:read_varuint()
      if leading + trailing + width > 64 then errors.raise(errors.invalid_data("xor-float bit widths")) end
      local x = width == 64 and payload or (payload << trailing)
      bits_value = prev ~ x
    end
    out[#out + 1] = M.u64_to_f64(bits_value)
    prev = bits_value
  end
  return out
end

function M.leading_zeros64(x)
  if x == 0 then return 64 end
  return 64 - M.bit_width(x)
end

function M.trailing_zeros64(x)
  if x == 0 then return 64 end
  local t = x & -x
  return M.bit_width(t) - 1
end

function M.encode_f64_vector(values, codec, out)
  if codec == model.VECTOR_CODEC_XOR_FLOAT then M.encode_xor_float(values, out)
  else
    wire.encode_varuint(#values, out)
    for i = 1, #values do wire.append_f64_le(out, values[i]) end
  end
end

function M.decode_f64_vector(reader, codec)
  if codec == model.VECTOR_CODEC_XOR_FLOAT then return M.decode_xor_float(reader) end
  local length = reader:read_varuint()
  local out = {}
  for i = 1, length do out[i] = wire.read_f64_le(reader) end
  return out
end

function M.encode_i64_delta_delta(values, out)
  wire.encode_varuint(#values, out)
  if #values == 0 then return end
  wire.encode_varuint(wire.encode_zigzag(values[1]), out)
  if #values == 1 then return end
  local d1 = values[2] - values[1]
  wire.encode_varuint(wire.encode_zigzag(d1), out)
  local dd = {}
  local prev_delta = d1
  for i = 2, #values - 1 do
    local d = values[i + 1] - values[i]
    dd[#dd + 1] = d - prev_delta
    prev_delta = d
  end
  M.encode_i64_direct_bitpack(dd, out)
end

function M.decode_i64_delta_delta(reader)
  local length = reader:read_varuint()
  if length == 0 then return {} end
  local first = wire.decode_zigzag(reader:read_varuint())
  if length == 1 then return { first } end
  local first_delta = wire.decode_zigzag(reader:read_varuint())
  local dd = M.decode_i64_direct_bitpack(reader)
  if #dd ~= length - 2 then errors.raise(errors.invalid_data("delta-delta length")) end
  local out = { first }
  local prev, prev_delta = first, first_delta
  local second, ok = M.checked_add_i64(prev, first_delta)
  if not ok then errors.raise(errors.invalid_data("delta-delta overflow")) end
  out[2] = second
  prev, prev_delta = second, first_delta
  for i = 1, #dd do
    local d, ok1 = M.checked_add_i64(prev_delta, dd[i])
    if not ok1 then errors.raise(errors.invalid_data("delta-delta overflow")) end
    local nxt, ok2 = M.checked_add_i64(prev, d)
    if not ok2 then errors.raise(errors.invalid_data("delta-delta overflow")) end
    out[#out + 1] = nxt
    prev, prev_delta = nxt, d
  end
  return out
end

function M.encode_i64_patched_for(values, out)
  if #values == 0 then wire.encode_varuint(0, out); return end
  local base = values[1]
  for i = 2, #values do if values[i] < base then base = values[i] end end
  local shifted = {}
  for i = 1, #values do shifted[i] = values[i] - base end
  wire.encode_varuint(#shifted, out)
  wire.encode_varuint(wire.encode_zigzag(base), out)
  local max_value = 0
  for i = 1, #shifted do if shifted[i] > max_value then max_value = shifted[i] end end
  local base_width = M.bit_width(max_value) > 2 and M.bit_width(max_value) - 2 or 0
  byte_buffer.append(out, base_width)
  local patch_positions = {}
  local main_values = {}
  for idx = 1, #shifted do
    local value = shifted[idx]
    if M.bit_width(value) > base_width then
      patch_positions[#patch_positions + 1] = { pos = idx - 1, value = value }
      local main = 0
      if base_width > 0 then
        local mask = (1 << base_width) - 1
        main = value & mask
        if main < 0 then main = 0 end
      end
      main_values[#main_values + 1] = main
    else
      main_values[#main_values + 1] = value
    end
  end
  for i = 1, #main_values do wire.encode_varuint(main_values[i] & model.MAX_U64, out) end
  wire.encode_varuint(#patch_positions, out)
  for i = 1, #patch_positions do
    wire.encode_varuint(patch_positions[i].pos, out)
    wire.encode_varuint(patch_positions[i].value & model.MAX_U64, out)
  end
end

function M.decode_i64_patched_for(reader)
  local length = reader:read_varuint()
  if length == 0 then return {} end
  local base = wire.decode_zigzag(reader:read_varuint())
  reader:read_u8()
  local values = {}
  for i = 1, length do values[i] = reader:read_varuint() end
  local patch_count = reader:read_varuint()
  for _ = 1, patch_count do
    local pos = reader:read_varuint()
    local patch = reader:read_varuint()
    if pos < #values then values[pos + 1] = patch end
  end
  for i = 1, #values do values[i] = values[i] + base end
  return values
end

function M.encode_i64_vector(values, codec, out)
  if codec == model.VECTOR_CODEC_RLE then M.encode_i64_rle(values, out)
  elseif codec == model.VECTOR_CODEC_DIRECT_BITPACK then M.encode_i64_direct_bitpack(values, out)
  elseif codec == model.VECTOR_CODEC_DELTA_BITPACK then M.encode_i64_direct_bitpack(M.delta(values), out)
  elseif codec == model.VECTOR_CODEC_FOR_BITPACK then
    if #values == 0 then wire.encode_varuint(0, out); return end
    local min_value = values[1]
    for i = 2, #values do if values[i] < min_value then min_value = values[i] end end
    wire.encode_varuint(wire.encode_zigzag(min_value), out)
    local shifted = {}
    for i = 1, #values do shifted[i] = values[i] - min_value end
    M.encode_i64_direct_bitpack(shifted, out)
  elseif codec == model.VECTOR_CODEC_DELTA_FOR_BITPACK then
    local deltas = M.delta(values)
    if #deltas == 0 then wire.encode_varuint(0, out); return end
    local min_value = deltas[1]
    for i = 2, #deltas do if deltas[i] < min_value then min_value = deltas[i] end end
    wire.encode_varuint(wire.encode_zigzag(min_value), out)
    local shifted = {}
    for i = 1, #deltas do shifted[i] = deltas[i] - min_value end
    M.encode_i64_direct_bitpack(shifted, out)
  elseif codec == model.VECTOR_CODEC_DELTA_DELTA_BITPACK then M.encode_i64_delta_delta(values, out)
  elseif codec == model.VECTOR_CODEC_PATCHED_FOR then M.encode_i64_patched_for(values, out)
  elseif codec == model.VECTOR_CODEC_SIMPLE8B then M.encode_i64_simple8b(values, out)
  else M.encode_i64_plain(values, out) end
end

function M.decode_i64_vector(reader, codec)
  if codec == model.VECTOR_CODEC_RLE then return M.decode_i64_rle(reader)
  elseif codec == model.VECTOR_CODEC_DIRECT_BITPACK then return M.decode_i64_direct_bitpack(reader)
  elseif codec == model.VECTOR_CODEC_DELTA_BITPACK then return M.undelta(M.decode_i64_direct_bitpack(reader))
  elseif codec == model.VECTOR_CODEC_FOR_BITPACK then
    local min_value = wire.decode_zigzag(reader:read_varuint())
    if reader:is_eof() then return {} end
    local shifted = M.decode_i64_direct_bitpack(reader)
    local r = {}
    for i = 1, #shifted do r[i] = shifted[i] + min_value end
    return r
  elseif codec == model.VECTOR_CODEC_DELTA_FOR_BITPACK then
    local min_value = wire.decode_zigzag(reader:read_varuint())
    if reader:is_eof() then return {} end
    local shifted = M.decode_i64_direct_bitpack(reader)
    local d = {}
    for i = 1, #shifted do d[i] = shifted[i] + min_value end
    return M.undelta(d)
  elseif codec == model.VECTOR_CODEC_DELTA_DELTA_BITPACK then return M.decode_i64_delta_delta(reader)
  elseif codec == model.VECTOR_CODEC_PATCHED_FOR then return M.decode_i64_patched_for(reader)
  elseif codec == model.VECTOR_CODEC_SIMPLE8B then return M.decode_i64_simple8b(reader)
  else return M.decode_i64_plain(reader) end
end

function M.encode_u64_vector(values, codec, out)
  if codec == model.VECTOR_CODEC_RLE then M.encode_u64_rle(values, out)
  elseif codec == model.VECTOR_CODEC_DIRECT_BITPACK then M.encode_u64_direct_bitpack(values, out)
  elseif codec == model.VECTOR_CODEC_FOR_BITPACK then
    if #values == 0 then wire.encode_varuint(0, out); return end
    local min_value = values[1]
    for i = 2, #values do if values[i] < min_value then min_value = values[i] end end
    wire.encode_varuint(min_value, out)
    local shifted = {}
    for i = 1, #values do shifted[i] = values[i] - min_value end
    M.encode_u64_direct_bitpack(shifted, out)
  elseif codec == model.VECTOR_CODEC_SIMPLE8B then M.encode_u64_simple8b(values, out)
  else M.encode_u64_plain(values, out) end
end

function M.decode_u64_vector(reader, codec)
  if codec == model.VECTOR_CODEC_RLE then return M.decode_u64_rle(reader)
  elseif codec == model.VECTOR_CODEC_DIRECT_BITPACK then return M.decode_u64_direct_bitpack(reader)
  elseif codec == model.VECTOR_CODEC_FOR_BITPACK then
    local min_value = reader:read_varuint()
    if reader:is_eof() then return {} end
    local shifted = M.decode_u64_direct_bitpack(reader)
    local outv = {}
    for i = 1, #shifted do
      local sum, ok = M.checked_add_u64(shifted[i], min_value)
      if not ok then errors.raise(errors.invalid_data("u64 FOR overflow")) end
      outv[i] = sum
    end
    return outv
  elseif codec == model.VECTOR_CODEC_SIMPLE8B then return M.decode_u64_simple8b(reader)
  else return M.decode_u64_plain(reader) end
end

return M
''')
print("wrote", OUT)
