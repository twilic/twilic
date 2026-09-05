local tw = require("twilic")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local H = require("spec.test_helpers")

local CONTROL_STREAM_CODECS = {
  model.CONTROL_STREAM_CODEC_PLAIN,
  model.CONTROL_STREAM_CODEC_RLE,
  model.CONTROL_STREAM_CODEC_BITPACK,
  model.CONTROL_STREAM_CODEC_HUFFMAN,
  model.CONTROL_STREAM_CODEC_FSE,
}

describe("control stream and control spec", function()
  it("control stream roundtrips for all declared codecs", function()
    local codec = tw.new_twilic_codec()
    local payload = string.char(0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4)
    for _, stream_codec in ipairs(CONTROL_STREAM_CODECS) do
      local msg = model.message({
        kind = model.MESSAGE_KIND_CONTROL_STREAM,
        control_stream = { codec = stream_codec, payload = payload },
      })
      local bytes = codec:encode_message(msg)
      local decoded = codec:decode_message(bytes)
      assert.is_true(H.equal_message(decoded, msg), "control stream mismatch")
    end
  end)

  it("control stream bitpack huffman fse compact repetitive payloads", function()
    local binary_parts = {}
    for i = 0, 511 do
      binary_parts[i + 1] = string.char(i % 2)
    end
    local binary_payload = table.concat(binary_parts)
    local plain_binary_len = H.encoded_control_stream_len(model.CONTROL_STREAM_CODEC_PLAIN, binary_payload)
    local bitpack_len = H.encoded_control_stream_len(model.CONTROL_STREAM_CODEC_BITPACK, binary_payload)
    assert.is_true(bitpack_len <= plain_binary_len)

    local rle_friendly = string.rep(string.char(7), 512)
    local plain_rle_len = H.encoded_control_stream_len(model.CONTROL_STREAM_CODEC_PLAIN, rle_friendly)
    local huffman_len = H.encoded_control_stream_len(model.CONTROL_STREAM_CODEC_HUFFMAN, rle_friendly)
    assert.is_true(huffman_len <= plain_rle_len)

    local low_parts = {}
    for i = 0, 511 do
      low_parts[i + 1] = string.char(i % 4)
    end
    local low_card = table.concat(low_parts)
    local plain_low_len = H.encoded_control_stream_len(model.CONTROL_STREAM_CODEC_PLAIN, low_card)
    local fse_len = H.encoded_control_stream_len(model.CONTROL_STREAM_CODEC_FSE, low_card)
    assert.is_true(fse_len <= plain_low_len)
  end)

  it("control stream fse uses fse frame mode", function()
    local codec = tw.new_twilic_codec()
    local parts = {}
    for i = 0, 511 do
      parts[i + 1] = string.char(i % 4)
    end
    local payload = table.concat(parts)
    local msg = model.message({
      kind = model.MESSAGE_KIND_CONTROL_STREAM,
      control_stream = { codec = model.CONTROL_STREAM_CODEC_FSE, payload = payload },
    })
    local bytes = codec:encode_message(msg)
    local reader = wire.new_reader(bytes)
    assert.are.equal(model.MESSAGE_KIND_CONTROL_STREAM, reader:read_u8())
    assert.are.equal(model.CONTROL_STREAM_CODEC_FSE, reader:read_u8())
    local framed = reader:read_bytes()
    assert.is_true(#framed > 0)
  end)

  it("register shape with key ids roundtrips", function()
    local codec = tw.new_twilic_codec()
    local reg_keys = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({
        opcode = model.CONTROL_OPCODE_REGISTER_KEYS,
        register_keys = { "id", "name" },
      }),
    })
    codec:decode_message(codec:encode_message(reg_keys))
    local reg_shape = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({
        opcode = model.CONTROL_OPCODE_REGISTER_SHAPE,
        register_shape = {
          shape_id = 99,
          keys = { model.key_ref_id(0), model.key_ref_id(1) },
        },
      }),
    })
    local decoded = codec:decode_message(codec:encode_message(reg_shape))
    assert.are.equal(model.MESSAGE_KIND_CONTROL, decoded.kind)
    assert.is_not_nil(decoded.control.register_shape)
    local shaped = model.message({
      kind = model.MESSAGE_KIND_SHAPED_OBJECT,
      shaped_object = {
        shape_id = 99,
        presence = nil,
        has_presence = false,
        values = { tw.u64(1), tw.string("alice") },
      },
    })
    local value = codec:decode_value(codec:encode_message(shaped))
    assert.are.equal(model.VALUE_MAP, value.kind)
  end)

  it("reset state clears shape resolution", function()
    local codec = tw.new_twilic_codec()
    local reg_shape = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({
        opcode = model.CONTROL_OPCODE_REGISTER_SHAPE,
        register_shape = {
          shape_id = 7,
          keys = { model.key_ref_literal("id"), model.key_ref_literal("name") },
        },
      }),
    })
    codec:decode_message(codec:encode_message(reg_shape))
    local reset = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({
        opcode = model.CONTROL_OPCODE_RESET_STATE,
        reset_state = true,
      }),
    })
    codec:decode_message(codec:encode_message(reset))
    local shaped = model.message({
      kind = model.MESSAGE_KIND_SHAPED_OBJECT,
      shaped_object = {
        shape_id = 7,
        presence = nil,
        has_presence = false,
        values = { tw.u64(1), tw.string("alice") },
      },
    })
    local err = H.assert_raises_twilic(function()
      codec:decode_value(codec:encode_message(shaped))
    end, tw.ERR_UNKNOWN_REFERENCE)
    assert.are.equal("shape_id", err.ref_kind)
    assert.are.equal(7, err.ref_id)
  end)
end)
