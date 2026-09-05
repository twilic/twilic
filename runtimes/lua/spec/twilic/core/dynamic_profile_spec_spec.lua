local tw = require("twilic")
local model = require("twilic.core.model")
local H = require("spec.test_helpers")

describe("dynamic profile spec", function()
  it("shape promotes after second three field map", function()
    local codec = tw.new_twilic_codec()
    local value = tw.map({
      id = tw.u64(1),
      name = tw.string("alice"),
      role = tw.string("admin"),
    })
    local first_msg = codec:decode_message(codec:encode_value(value))
    assert.are.equal(model.MESSAGE_KIND_MAP, first_msg.kind)
    local second_msg = codec:decode_message(codec:encode_value(value))
    assert.are.equal(model.MESSAGE_KIND_SHAPED_OBJECT, second_msg.kind)
    local third_msg = codec:decode_message(codec:encode_value(value))
    assert.are.equal(model.MESSAGE_KIND_SHAPED_OBJECT, third_msg.kind)
  end)

  it("two field map keeps map and uses key ids", function()
    local codec = tw.new_twilic_codec()
    local value = tw.map({ id = tw.u64(1), name = tw.string("alice") })
    local first_msg = codec:decode_message(codec:encode_value(value))
    assert.are.equal(model.MESSAGE_KIND_MAP, first_msg.kind)
    for i = 1, #first_msg.map do
      assert.is_false(first_msg.map[i].key.is_id)
    end
    local second_msg = codec:decode_message(codec:encode_value(value))
    assert.is_true(
      second_msg.kind == model.MESSAGE_KIND_MAP or second_msg.kind == model.MESSAGE_KIND_SHAPED_OBJECT
    )
    if second_msg.kind == model.MESSAGE_KIND_MAP then
      for i = 1, #second_msg.map do
        assert.is_true(second_msg.map[i].key.is_id)
      end
    end
  end)

  it("typed vector threshold is applied", function()
    local codec = tw.new_twilic_codec()
    local short = tw.array({ tw.i64(1), tw.i64(2), tw.i64(3) })
    local short_msg = codec:decode_message(codec:encode_value(short))
    assert.are.equal(model.MESSAGE_KIND_ARRAY, short_msg.kind)
    local long_items = {}
    for i = 1, 16 do
      long_items[i] = tw.i64(1000 + i * 10)
    end
    local long = tw.array(long_items)
    local long_msg = codec:decode_message(codec:encode_value(long))
    assert.are.equal(model.MESSAGE_KIND_TYPED_VECTOR, long_msg.kind)
  end)

  it("string modes empty ref and prefix delta are used", function()
    local codec = tw.new_twilic_codec()
    assert.are.equal(model.STRING_MODE_EMPTY, H.scalar_string_mode(codec:encode_value(tw.string(""))))
    assert.are.equal(model.STRING_MODE_LITERAL, H.scalar_string_mode(codec:encode_value(tw.string("alpha"))))
    assert.are.equal(model.STRING_MODE_REF, H.scalar_string_mode(codec:encode_value(tw.string("alpha"))))
    codec:encode_value(tw.string("prefix_common_aaaa"))
    assert.are.equal(
      model.STRING_MODE_PREFIX_DELTA,
      H.scalar_string_mode(codec:encode_value(tw.string("prefix_common_bbbb")))
    )
  end)

  it("reset tables clears string interning", function()
    local codec = tw.new_twilic_codec()
    codec:encode_value(tw.string("ephemeral"))
    assert.are.equal(model.STRING_MODE_REF, H.scalar_string_mode(codec:encode_value(tw.string("ephemeral"))))
    local reset = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({
        opcode = model.CONTROL_OPCODE_RESET_TABLES,
        reset_tables = true,
      }),
    })
    codec:decode_message(codec:encode_message(reset))
    assert.are.equal(model.STRING_MODE_LITERAL, H.scalar_string_mode(codec:encode_value(tw.string("ephemeral"))))
  end)
end)
