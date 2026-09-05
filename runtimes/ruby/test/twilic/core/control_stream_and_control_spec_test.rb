# frozen_string_literal: true

require "test_helper"

class ControlStreamAndControlSpecTest < Minitest::Test
  include TwilicTestHelpers

  CONTROL_STREAM_CODECS = [
    Twilic::ControlStreamCodec::PLAIN,
    Twilic::ControlStreamCodec::RLE,
    Twilic::ControlStreamCodec::BITPACK,
    Twilic::ControlStreamCodec::HUFFMAN,
    Twilic::ControlStreamCodec::FSE
  ].freeze

  def test_control_stream_roundtrips_for_all_declared_codecs
    codec = Twilic.new_twilic_codec
    payload = [0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4].pack("C*")

    CONTROL_STREAM_CODECS.each do |stream_codec|
      msg = Twilic::Core::Model.message(
        kind: Twilic::MessageKind::CONTROL_STREAM,
        control_stream: Twilic::ControlStreamMessage.new(codec: stream_codec, payload: payload.b)
      )
      bytes = codec.encode_message(msg)
      decoded = codec.decode_message(bytes)
      assert equal_message(decoded, msg), "control stream mismatch for codec #{stream_codec.value}"
    end
  end

  def test_control_stream_bitpack_huffman_fse_compact_repetitive_payloads
    binary_payload = Array.new(512) { |i| i % 2 }.pack("C*")
    plain_binary_len = encoded_control_stream_len(Twilic::ControlStreamCodec::PLAIN, binary_payload)
    bitpack_len = encoded_control_stream_len(Twilic::ControlStreamCodec::BITPACK, binary_payload)
    assert_operator bitpack_len, :<=, plain_binary_len, "expected bitpack <= plain for binary payload"

    rle_friendly = Array.new(512, 7).pack("C*")
    plain_rle_len = encoded_control_stream_len(Twilic::ControlStreamCodec::PLAIN, rle_friendly)
    huffman_len = encoded_control_stream_len(Twilic::ControlStreamCodec::HUFFMAN, rle_friendly)
    assert_operator huffman_len, :<=, plain_rle_len, "expected huffman <= plain for repetitive payload"

    low_card = Array.new(512) { |i| i % 4 }.pack("C*")
    plain_low_card_len = encoded_control_stream_len(Twilic::ControlStreamCodec::PLAIN, low_card)
    fse_len = encoded_control_stream_len(Twilic::ControlStreamCodec::FSE, low_card)
    assert_operator fse_len, :<=, plain_low_card_len, "expected fse <= plain for low-cardinality payload"
  end

  def test_control_stream_fse_uses_fse_frame_mode
    codec = Twilic.new_twilic_codec
    payload = Array.new(512) { |i| i % 4 }.pack("C*")
    msg = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL_STREAM,
      control_stream: Twilic::ControlStreamMessage.new(
        codec: Twilic::ControlStreamCodec::FSE,
        payload: payload.b
      )
    )
    bytes = codec.encode_message(msg)

    reader = Twilic::Core::Wire::Reader.new(bytes)
    assert_equal Twilic::MessageKind::CONTROL_STREAM.value, reader.read_u8
    assert_equal Twilic::ControlStreamCodec::FSE.value, reader.read_u8
    framed = reader.read_bytes
    refute_empty framed
  end

  def test_register_shape_with_key_ids_roundtrips
    codec = Twilic.new_twilic_codec

    reg_keys = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::REGISTER_KEYS,
        register_keys: %w[id name]
      )
    )
    codec.decode_message(codec.encode_message(reg_keys))

    reg_shape = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::REGISTER_SHAPE,
        register_shape: Twilic::RegisterShapeControl.new(
          shape_id: 99,
          keys: [Twilic::KeyRef.id_ref(0), Twilic::KeyRef.id_ref(1)]
        )
      )
    )
    decoded = codec.decode_message(codec.encode_message(reg_shape))
    assert_equal Twilic::MessageKind::CONTROL, decoded.kind
    refute_nil decoded.control.register_shape

    shaped = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::SHAPED_OBJECT,
      shaped_object: Twilic::ShapedObjectMessage.new(
        shape_id: 99,
        presence: nil,
        has_presence: false,
        values: [Twilic.u64(1), Twilic.string("alice")]
      )
    )
    shaped_bytes = codec.encode_message(shaped)
    value = codec.decode_value(shaped_bytes)
    assert_equal Twilic::ValueKind::MAP, value.kind
  end

  def test_reset_state_clears_shape_resolution
    codec = Twilic.new_twilic_codec

    reg_shape = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::REGISTER_SHAPE,
        register_shape: Twilic::RegisterShapeControl.new(
          shape_id: 7,
          keys: [Twilic::KeyRef.literal("id"), Twilic::KeyRef.literal("name")]
        )
      )
    )
    codec.decode_message(codec.encode_message(reg_shape))

    reset = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::RESET_STATE,
        reset_state: true
      )
    )
    codec.decode_message(codec.encode_message(reset))

    shaped = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::SHAPED_OBJECT,
      shaped_object: Twilic::ShapedObjectMessage.new(
        shape_id: 7,
        presence: nil,
        has_presence: false,
        values: [Twilic.u64(1), Twilic.string("alice")]
      )
    )
    shaped_bytes = codec.encode_message(shaped)
    err = assert_raises(Twilic::TwilicError) { codec.decode_value(shaped_bytes) }
    te = require_twilic_error_kind(err, Twilic::ERR_UNKNOWN_REFERENCE)
    assert_equal "shape_id", te.ref_kind
    assert_equal 7, te.ref_id
  end
end
