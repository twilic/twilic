# frozen_string_literal: true

require "test_helper"

class CodecSpecVectorsTest < Minitest::Test
  include TwilicTestHelpers

  def test_simple8b_i64_roundtrip_small_values
    values = [1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5]
    out = +""
    Twilic::Core::Codec.encode_i64_vector(values, Twilic::VectorCodec::SIMPLE8B, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_i64_vector(reader, Twilic::VectorCodec::SIMPLE8B)
    assert_equal values.length, decoded.length
    values.each_with_index { |v, i| assert_equal v, decoded[i], "decoded[#{i}]" }
  end

  def test_simple8b_u64_roundtrip_with_long_zero_runs
    values = Array.new(130, 0) + [1, 2, 3, 4, 5] + Array.new(250, 0)
    out = +""
    Twilic::Core::Codec.encode_u64_vector(values, Twilic::VectorCodec::SIMPLE8B, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_u64_vector(reader, Twilic::VectorCodec::SIMPLE8B)
    assert_equal values.length, decoded.length
    values.each_with_index { |v, i| assert_equal v, decoded[i], "decoded[#{i}]" }
  end

  def test_simple8b_u64_falls_back_for_large_values
    values = [(1 << 61), (1 << 61) + 7, (1 << 61) + 99]
    out = +""
    Twilic::Core::Codec.encode_u64_vector(values, Twilic::VectorCodec::SIMPLE8B, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_u64_vector(reader, Twilic::VectorCodec::SIMPLE8B)
    values.each_with_index { |v, i| assert_equal v, decoded[i], "decoded[#{i}]" }
  end

  def test_for_u64_overflow_is_rejected
    bytes = +""
    Twilic::Core::Wire.encode_varuint(0xFFFFFFFFFFFFFFFF, bytes)
    Twilic::Core::Wire.encode_varuint(1, bytes)
    bytes << [1, 0x01].pack("C*")

    reader = Twilic::Core::Wire::Reader.new(bytes)
    err = assert_raises(Twilic::TwilicError) do
      Twilic::Core::Codec.decode_u64_vector(reader, Twilic::VectorCodec::FOR_BITPACK)
    end
    te = require_twilic_error_kind(err, Twilic::ERR_INVALID_DATA)
    assert_equal "u64 FOR overflow", te.msg
  end

  def test_direct_bitpack_invalid_width_is_rejected
    bytes = +""
    Twilic::Core::Wire.encode_varuint(1, bytes)
    bytes << 0.chr
    reader = Twilic::Core::Wire::Reader.new(bytes)
    err = assert_raises(Twilic::TwilicError) do
      Twilic::Core::Codec.decode_i64_vector(reader, Twilic::VectorCodec::DIRECT_BITPACK)
    end
    te = require_twilic_error_kind(err, Twilic::ERR_INVALID_DATA)
    assert_equal "bitpack width", te.msg
  end

  def test_xor_float_roundtrip_smooth_series
    values = [1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5]
    out = +""
    Twilic::Core::Codec.encode_f64_vector(values, Twilic::VectorCodec::XOR_FLOAT, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_f64_vector(reader, Twilic::VectorCodec::XOR_FLOAT)
    values.each_with_index { |v, i| assert_equal v, decoded[i], "decoded[#{i}]" }
  end
end
