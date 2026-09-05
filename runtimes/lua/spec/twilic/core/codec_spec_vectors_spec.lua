local codec_mod = require("twilic.core.codec")
local wire = require("twilic.core.wire")
local model = require("twilic.core.model")
local byte_buffer = require("twilic.core.byte_buffer")
local tw = require("twilic")
local H = require("spec.test_helpers")

describe("codec spec vectors", function()
  it("simple8b i64 roundtrip small values", function()
    local values = { 1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5 }
    local out = byte_buffer.new()
    codec_mod.encode_i64_vector(values, model.VECTOR_CODEC_SIMPLE8B, out)
    local reader = wire.new_reader(byte_buffer.bytes(out))
    local decoded = codec_mod.decode_i64_vector(reader, model.VECTOR_CODEC_SIMPLE8B)
    assert.are.equal(#values, #decoded)
    for i = 1, #values do
      assert.are.equal(values[i], decoded[i], "decoded[" .. i .. "]")
    end
  end)

  it("simple8b u64 roundtrip with long zero runs", function()
    local values = {}
    for _ = 1, 130 do
      values[#values + 1] = 0
    end
    for _, v in ipairs({ 1, 2, 3, 4, 5 }) do
      values[#values + 1] = v
    end
    for _ = 1, 250 do
      values[#values + 1] = 0
    end
    local out = byte_buffer.new()
    codec_mod.encode_u64_vector(values, model.VECTOR_CODEC_SIMPLE8B, out)
    local reader = wire.new_reader(byte_buffer.bytes(out))
    local decoded = codec_mod.decode_u64_vector(reader, model.VECTOR_CODEC_SIMPLE8B)
    assert.are.equal(#values, #decoded)
    for i = 1, #values do
      assert.are.equal(values[i], decoded[i], "decoded[" .. i .. "]")
    end
  end)

  it("simple8b u64 falls back for large values", function()
    local values = { 1 << 61, (1 << 61) + 7, (1 << 61) + 99 }
    local out = byte_buffer.new()
    codec_mod.encode_u64_vector(values, model.VECTOR_CODEC_SIMPLE8B, out)
    local reader = wire.new_reader(byte_buffer.bytes(out))
    local decoded = codec_mod.decode_u64_vector(reader, model.VECTOR_CODEC_SIMPLE8B)
    for i = 1, #values do
      assert.are.equal(values[i], decoded[i], "decoded[" .. i .. "]")
    end
  end)

  it("for u64 overflow is rejected", function()
    local function hex(nibbles)
      local out = {}
      for i = 1, #nibbles, 2 do
        out[#out + 1] = string.char(tonumber(nibbles:sub(i, i + 1), 16))
      end
      return table.concat(out)
    end
    local bytes = hex("ffffffffffffffffff01010101")
    local reader = wire.new_reader(bytes)
    local err = H.assert_raises_twilic(function()
      codec_mod.decode_u64_vector(reader, model.VECTOR_CODEC_FOR_BITPACK)
    end, tw.ERR_INVALID_DATA)
    assert.are.equal("u64 FOR overflow", err.msg)
  end)

  it("direct bitpack invalid width is rejected", function()
    local out = byte_buffer.new()
    wire.encode_varuint(1, out)
    byte_buffer.append(out, 0)
    local reader = wire.new_reader(byte_buffer.bytes(out))
    local err = H.assert_raises_twilic(function()
      codec_mod.decode_i64_vector(reader, model.VECTOR_CODEC_DIRECT_BITPACK)
    end, tw.ERR_INVALID_DATA)
    assert.are.equal("bitpack width", err.msg)
  end)

  it("xor float roundtrip smooth series", function()
    local values = {}
    for i = 0, 63 do
      values[#values + 1] = 1.0 + i * 0.01
    end
    local out = byte_buffer.new()
    codec_mod.encode_f64_vector(values, model.VECTOR_CODEC_XOR_FLOAT, out)
    local reader = wire.new_reader(byte_buffer.bytes(out))
    local decoded = codec_mod.decode_f64_vector(reader, model.VECTOR_CODEC_XOR_FLOAT)
    assert.are.equal(#values, #decoded)
    for i = 1, #values do
      assert.is_near(values[i], decoded[i], 1e-9, "decoded[" .. i .. "]")
    end
  end)
end)
