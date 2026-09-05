--- Trained dictionary encoding and decoding.
local errors = require("twilic.core.errors")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local byte_buffer = require("twilic.core.byte_buffer")
local session = require("twilic.core.session")

local M = {}

local function u64(v)
  return v & model.MAX_U64
end

local function u64_mask_width(width)
  if width <= 0 then return 0 end
  if width >= 64 then return model.MAX_U64 end
  return (1 << width) - 1
end

local function wide_new(lo, hi)
  return { lo = u64(lo or 0), hi = u64(hi or 0) }
end

local function wide_from_u64(v)
  return wide_new(v, 0)
end

local function wide_mask(width)
  if width == 0 then return wide_new(0, 0) end
  if width <= 64 then return wide_new(u64_mask_width(width), 0) end
  return wide_new(model.MAX_U64, u64_mask_width(width - 64))
end

local function wide_is_zero(w)
  return w.lo == 0 and w.hi == 0
end

local function wide_and(a, b)
  return wide_new(a.lo & b.lo, a.hi & b.hi)
end

local function wide_or(a, b)
  return wide_new(a.lo | b.lo, a.hi | b.hi)
end

local function wide_shl(w, n)
  if n == 0 then return wide_new(w.lo, w.hi) end
  if n >= 128 then return wide_new(0, 0) end
  if n < 64 then
    local hi = u64((w.hi << n) | (w.lo >> (64 - n)))
    local lo = u64(w.lo << n)
    return wide_new(lo, hi)
  end
  n = n - 64
  return wide_new(0, u64(w.lo << n))
end

local function wide_shr(w, n)
  if n == 0 then return wide_new(w.lo, w.hi) end
  if n >= 128 then return wide_new(0, 0) end
  if n < 64 then
    local lo = u64((w.lo >> n) | (w.hi << (64 - n)))
    local hi = u64(w.hi >> n)
    return wide_new(lo, hi)
  end
  n = n - 64
  return wide_new(u64(w.hi >> n), 0)
end

function M.decode_trained_dictionary_payload(payload)
  local reader = wire.new_reader(payload)
  local n = reader:read_count()
  local values = {}
  for i = 1, n do
    values[i] = reader:read_string()
  end
  if not reader:is_eof() then
    errors.raise(errors.invalid_data("trained dictionary payload trailing bytes"))
  end
  return values
end

function M.encode_trained_dictionary_block(values, dictionary)
  if #values == 0 then
    local out = byte_buffer.new()
    byte_buffer.append(out, 0)
    wire.encode_varuint(0, out)
    return byte_buffer.bytes(out), true
  end
  local by_value = {}
  for idx = 1, #dictionary do
    by_value[dictionary[idx]] = idx - 1
  end
  local ids = {}
  for i = 1, #values do
    local id = by_value[values[i]]
    if id == nil then
      return nil, false
    end
    ids[i] = id
  end
  local raw = byte_buffer.new()
  byte_buffer.append(raw, 0)
  wire.encode_varuint(#ids, raw)
  for i = 1, #ids do
    wire.encode_varuint(ids[i], raw)
  end
  local max_id = 0
  for i = 1, #ids do
    if ids[i] > max_id then max_id = ids[i] end
  end
  local bit_width = max_id == 0 and 0 or math.floor(math.log(max_id, 2)) + 1
  local packed = byte_buffer.new()
  M.pack_fixed_width_u64(ids, bit_width, packed)
  local bitpacked = byte_buffer.new()
  byte_buffer.append(bitpacked, 1)
  wire.encode_varuint(#ids, bitpacked)
  byte_buffer.append(bitpacked, bit_width)
  byte_buffer.append_bytes(bitpacked, byte_buffer.bytes(packed))
  if #byte_buffer.bytes(bitpacked) < #byte_buffer.bytes(raw) then
    return byte_buffer.bytes(bitpacked), true
  end
  return byte_buffer.bytes(raw), true
end

function M.decode_trained_dictionary_block(block, dictionary)
  local reader = wire.new_reader(block)
  local mode = reader:read_u8()
  local n = reader:read_count()
  local ids
  if mode == 0 then
    ids = {}
    for i = 1, n do ids[i] = reader:read_varuint() end
  elseif mode == 1 then
    local bit_width = reader:read_u8()
    local remaining = #block - reader:position()
    local packed = reader:read_exact(remaining)
    ids = M.unpack_fixed_width_u64(packed, n, bit_width)
  else
    errors.raise(errors.invalid_data("trained dictionary block mode"))
  end
  if not reader:is_eof() then
    errors.raise(errors.invalid_data("trained dictionary block trailing bytes"))
  end
  local out = {}
  for i = 1, #ids do
    local ref_id = ids[i]
    if ref_id >= #dictionary then
      errors.raise(errors.invalid_data("trained dictionary block id"))
    end
    out[i] = dictionary[ref_id + 1]
  end
  return out
end

function M.pack_fixed_width_u64(values, width, out)
  if width > 64 then
    errors.raise(errors.invalid_data("fixed-width u64 bit width"))
  end
  if width == 0 then
    for i = 1, #values do
      if values[i] ~= 0 then
        errors.raise(errors.invalid_data("fixed-width u64 value overflow"))
      end
    end
    return
  end
  local acc = wide_new(0, 0)
  local acc_bits = 0
  for i = 1, #values do
    local value = values[i]
    if width < 64 and (value >> width) ~= 0 then
      errors.raise(errors.invalid_data("fixed-width u64 value overflow"))
    end
    acc = wide_or(acc, wide_shl(wide_from_u64(value), acc_bits))
    acc_bits = acc_bits + width
    while acc_bits >= 8 do
      byte_buffer.append(out, acc.lo & 0xFF)
      acc = wide_shr(acc, 8)
      acc_bits = acc_bits - 8
    end
  end
  if acc_bits > 0 then
    byte_buffer.append(out, acc.lo & 0xFF)
  end
end

function M.unpack_fixed_width_u64(data, count, width)
  if width > 64 then
    errors.raise(errors.invalid_data("fixed-width u64 bit width"))
  end
  if width == 0 then
    for i = 1, #data do
      if string.byte(data, i) ~= 0 then
        errors.raise(errors.invalid_data("fixed-width u64 trailing bytes"))
      end
    end
    local out = {}
    for i = 1, count do out[i] = 0 end
    return out
  end
  local out = {}
  local acc = wide_new(0, 0)
  local acc_bits = 0
  local idx = 1
  local mask = wide_mask(width)
  for _ = 1, count do
    while acc_bits < width do
      if idx > #data then
        errors.raise(errors.invalid_data("fixed-width u64 underflow"))
      end
      acc = wide_or(acc, wide_shl(wide_from_u64(string.byte(data, idx)), acc_bits))
      idx = idx + 1
      acc_bits = acc_bits + 8
    end
    out[#out + 1] = wide_and(acc, mask).lo
    acc = wide_shr(acc, width)
    acc_bits = acc_bits - width
  end
  if not wide_is_zero(acc) then
    errors.raise(errors.invalid_data("fixed-width u64 trailing bytes"))
  end
  for j = idx, #data do
    if string.byte(data, j) ~= 0 then
      errors.raise(errors.invalid_data("fixed-width u64 trailing bytes"))
    end
  end
  return out
end

function M.dictionary_payload_hash(payload)
  local h = 0xCBF29CE484222325
  for i = 1, #payload do
    h = u64(h ~ string.byte(payload, i))
    h = u64(h * 0x100000001B3)
  end
  return h
end

function M.apply_dictionary_references(state, columns)
  for ci = 1, #columns do
    local column = columns[ci]
    if column.values.kind ~= model.ELEMENT_TYPE_STRING then
      goto continue
    end
    local values = column.values.strings
    if #values < 16 then goto continue end
    local seen = {}
    local unique_count = 0
    for i = 1, #values do
      if not seen[values[i]] then
        seen[values[i]] = true
        unique_count = unique_count + 1
      end
    end
    if unique_count / #values > 0.5 then goto continue end
    if column.codec ~= model.VECTOR_CODEC_DICTIONARY and column.codec ~= model.VECTOR_CODEC_STRING_REF then
      goto continue
    end
    local dict_id = session.allocate_dictionary_id(state)
    local keys = {}
    for s in pairs(seen) do keys[#keys + 1] = s end
    table.sort(keys)
    local payload = byte_buffer.new()
    wire.encode_varuint(#keys, payload)
    for i = 1, #keys do
      wire.encode_string(keys[i], payload)
    end
    local profile = {
      version = 1,
      hash = M.dictionary_payload_hash(byte_buffer.bytes(payload)),
      expires_at = 0,
      fallback = session.DICTIONARY_FALLBACK_FAIL_FAST,
    }
    if state.options.unknown_reference_policy == session.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY then
      profile.fallback = session.DICTIONARY_FALLBACK_STATELESS_RETRY
    end
    state.dictionaries[dict_id] = byte_buffer.bytes(payload)
    state.dictionary_profiles[dict_id] = profile
    column.dictionary_id = dict_id
    ::continue::
  end
end

return M
