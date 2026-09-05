# frozen_string_literal: true

require "test_helper"

class DynamicProfileSpecTest < Minitest::Test
  include TwilicTestHelpers
  def test_shape_promotes_after_second_three_field_map
    codec = Twilic.new_twilic_codec
    value = Twilic.map(
      "id" => Twilic.u64(1),
      "name" => Twilic.string("alice"),
      "role" => Twilic.string("admin")
    )

    first_msg = codec.decode_message(codec.encode_value(value))
    assert_equal Twilic::MessageKind::MAP, first_msg.kind

    second_msg = codec.decode_message(codec.encode_value(value))
    assert_equal Twilic::MessageKind::SHAPED_OBJECT, second_msg.kind

    third_msg = codec.decode_message(codec.encode_value(value))
    assert_equal Twilic::MessageKind::SHAPED_OBJECT, third_msg.kind
  end

  def test_two_field_map_keeps_map_and_uses_key_ids
    codec = Twilic.new_twilic_codec
    value = Twilic.map("id" => Twilic.u64(1), "name" => Twilic.string("alice"))

    first_msg = codec.decode_message(codec.encode_value(value))
    assert_equal Twilic::MessageKind::MAP, first_msg.kind
    first_msg.map.each do |entry|
      refute entry.key.is_id, "expected literal keys on first map"
    end

    second_msg = codec.decode_message(codec.encode_value(value))
    assert_includes [Twilic::MessageKind::MAP, Twilic::MessageKind::SHAPED_OBJECT], second_msg.kind
    if second_msg.kind == Twilic::MessageKind::MAP
      second_msg.map.each do |entry|
        assert entry.key.is_id, "expected key ref ids on second map"
      end
    end
  end

  def test_typed_vector_threshold_is_applied
    codec = Twilic.new_twilic_codec
    short = Twilic.array([Twilic.i64(1), Twilic.i64(2), Twilic.i64(3)])
    short_msg = codec.decode_message(codec.encode_value(short))
    assert_equal Twilic::MessageKind::ARRAY, short_msg.kind

    long_items = Array.new(16) { |i| Twilic.i64(1000 + i * 10) }
    long = Twilic.array(long_items)
    long_msg = codec.decode_message(codec.encode_value(long))
    assert_equal Twilic::MessageKind::TYPED_VECTOR, long_msg.kind
  end

  def test_string_modes_empty_ref_and_prefix_delta_are_used
    codec = Twilic.new_twilic_codec

    empty_bytes = codec.encode_value(Twilic.string(""))
    assert_equal Twilic::StringMode::EMPTY.value, scalar_string_mode(empty_bytes)

    lit_bytes = codec.encode_value(Twilic.string("alpha"))
    assert_equal Twilic::StringMode::LITERAL.value, scalar_string_mode(lit_bytes)

    ref_bytes = codec.encode_value(Twilic.string("alpha"))
    assert_equal Twilic::StringMode::REF.value, scalar_string_mode(ref_bytes)

    codec.encode_value(Twilic.string("prefix_common_aaaa"))
    prefix_delta_bytes = codec.encode_value(Twilic.string("prefix_common_bbbb"))
    assert_equal Twilic::StringMode::PREFIX_DELTA.value, scalar_string_mode(prefix_delta_bytes)
  end

  def test_reset_tables_clears_string_interning
    codec = Twilic.new_twilic_codec

    codec.encode_value(Twilic.string("ephemeral"))
    reused_bytes = codec.encode_value(Twilic.string("ephemeral"))
    assert_equal Twilic::StringMode::REF.value, scalar_string_mode(reused_bytes)

    reset = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::RESET_TABLES,
        reset_tables: true
      )
    )
    codec.decode_message(codec.encode_message(reset))

    after_bytes = codec.encode_value(Twilic.string("ephemeral"))
    assert_equal Twilic::StringMode::LITERAL.value, scalar_string_mode(after_bytes)
  end
end
