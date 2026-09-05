--- Low-level wire encoding and decoding primitives.
local errors = require("twilic.core.errors")
local byte_buffer = require("twilic.core.byte_buffer")

local M = {}

local U64_MOD = 0x10000000000000000

function M.to_unsigned(value)
  value = value & 0xFFFFFFFFFFFFFFFF
  if value < 0 then
    value = value + U64_MOD
  end
  return value
end

function M.encode_varuint(value, out)
  value = value & 0xFFFFFFFFFFFFFFFF
  -- Full-range u64 values use negative Lua integers; never treat them as single-byte varuints.
  if value >= 0 and value < 0x80 then
    byte_buffer.append(out, value)
    return
  end
  while true do
    local b = value & 0x7F
    value = value >> 7
    if value ~= 0 then
      b = b | 0x80
    end
    byte_buffer.append(out, b)
    if value == 0 then
      break
    end
  end
end

function M.encode_zigzag(value)
  -- Lua >> on negatives is not PHP's i64 arithmetic shift; use canonical zigzag.
  if value < 0 then
    return ((-value << 1) - 1) & 0xFFFFFFFFFFFFFFFF
  end
  return (value << 1) & 0xFFFFFFFFFFFFFFFF
end

function M.decode_zigzag(value)
  value = value & 0xFFFFFFFFFFFFFFFF
  local u = (value >> 1) ~ -(value & 1)
  if u >= 0x8000000000000000 then
    u = u - 0x10000000000000000
  end
  return u
end

function M.encode_bytes(data, out)
  M.encode_varuint(#data, out)
  byte_buffer.append_bytes(out, data)
end

function M.encode_string(value, out)
  M.encode_bytes(value, out)
end

function M.encode_bitmap(bits, out)
  M.encode_varuint(#bits, out)
  local current = 0
  for i, bit in ipairs(bits) do
    local idx = i - 1
    if bit then
      current = current | (1 << (idx % 8))
    end
    if idx % 8 == 7 then
      byte_buffer.append(out, current)
      current = 0
    end
  end
  if #bits % 8 ~= 0 then
    byte_buffer.append(out, current)
  end
end

local Reader = {}
Reader.__index = Reader

function M.new_reader(input_data)
  return setmetatable({ input = input_data, offset = 1, depth = 0, budget = math.min(#input_data, 1024) * 1024 }, Reader)
end

function Reader:claim_output(count)
  if math.type(count) ~= "integer" or count < 0 or count > (1 << 20) then
    errors.raise(errors.invalid_data("decode count limit exceeded"))
  end
  if count > self.budget // 8 then errors.raise(errors.invalid_data("decode output ratio exceeded")) end
  self.budget = self.budget - count * 8
end

function Reader:read_count(maximum)
  local count = self:read_varuint()
  if count < 0 or count > (maximum or (1 << 20)) then errors.raise(errors.invalid_data("decode count limit exceeded")) end
  self:claim_output(count)
  return count
end

function Reader:with_depth(decode)
  if self.depth >= 64 then errors.raise(errors.invalid_data("decode depth limit exceeded")) end
  self.depth = self.depth + 1
  local result = table.pack(pcall(decode))
  self.depth = self.depth - 1
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
end

function Reader:position()
  return self.offset - 1
end

function Reader:is_eof()
  return self.offset > #self.input
end

function Reader:read_u8()
  if self.offset > #self.input then
    errors.raise(errors.unexpected_eof())
  end
  local b = string.byte(self.input, self.offset)
  self.offset = self.offset + 1
  return b
end

function Reader:read_exact(n)
  local start = self.offset
  local end_ = start + n - 1
  if n < 0 or n > #self.input - self.offset + 1 then
    errors.raise(errors.unexpected_eof())
  end
  local slice = string.sub(self.input, start, end_)
  self.offset = end_ + 1
  return slice
end

function Reader:read_varuint()
  local shift = 0
  local result = 0
  while true do
    if shift >= 64 then
      errors.raise(errors.invalid_data("varuint too large"))
    end
    local b = self:read_u8()
    if shift == 63 and (b & 0x7E) ~= 0 then errors.raise(errors.invalid_data("varuint too large")) end
    result = result | ((b & 0x7F) << shift)
    if (b & 0x80) == 0 then
      return result & 0xFFFFFFFFFFFFFFFF
    end
    shift = shift + 7
  end
end

function Reader:read_i64_zigzag()
  return M.decode_zigzag(self:read_varuint())
end

function Reader:read_bytes()
  local n = self:read_varuint()
  return self:read_exact(n)
end

function Reader:read_string()
  local n = self:read_varuint()
  local data = self:read_exact(n)
  if not utf8.len(data) then
    errors.raise(errors.utf8_error())
  end
  return data
end

function Reader:read_bitmap()
  local bit_count = self:read_count()
  local byte_count = math.floor((bit_count + 7) / 8)
  local raw = self:read_exact(byte_count)
  local bits = {}
  for i = 1, bit_count do
    local idx = i - 1
    local byte = string.byte(raw, math.floor(idx / 8) + 1)
    bits[i] = ((byte >> (idx % 8)) & 1) == 1
  end
  return bits
end

function M.read_u64_le(reader)
  local b = reader:read_exact(8)
  local lo = string.unpack("<I4", b:sub(1, 4))
  local hi = string.unpack("<I4", b:sub(5, 8))
  return lo + (hi << 32)
end

function M.read_f64_le(reader)
  return select(1, string.unpack("<d", reader:read_exact(8)))
end

function M.append_u64_le(out, v)
  v = v & 0xFFFFFFFFFFFFFFFF
  byte_buffer.append_bytes(out, string.pack("<I4I4", v & 0xFFFFFFFF, (v >> 32) & 0xFFFFFFFF))
end

function M.append_f64_le(out, v)
  byte_buffer.append_bytes(out, string.pack("<d", v))
end

return M
