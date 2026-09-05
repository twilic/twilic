"""Port of twilic-go/internal/core/codec_spec_vectors_test.go."""

from __future__ import annotations

from conftest import require_twilic_error_kind
from twilic import (
    VectorCodecDirectBitpack,
    VectorCodecForBitpack,
    VectorCodecSimple8b,
    VectorCodecXorFloat,
)
from twilic.codec import (
    decode_f64_vector,
    decode_i64_vector,
    decode_u64_vector,
    encode_f64_vector,
    encode_i64_vector,
    encode_u64_vector,
)
from twilic.wire import encode_varuint, new_reader


def test_codec_spec_vectors_simple8b_i64_roundtrip_small_values():
    values = [1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5]
    out = bytearray()
    encode_i64_vector(values, VectorCodecSimple8b, out)
    decoded = decode_i64_vector(new_reader(bytes(out)), VectorCodecSimple8b)
    assert len(decoded) == len(values)
    assert decoded == values


def test_codec_spec_vectors_simple8b_u64_roundtrip_with_long_zero_runs():
    values = [0] * 130 + [1, 2, 3, 4, 5] + [0] * 250
    out = bytearray()
    encode_u64_vector(values, VectorCodecSimple8b, out)
    decoded = decode_u64_vector(new_reader(bytes(out)), VectorCodecSimple8b)
    assert len(decoded) == len(values)
    assert decoded == values


def test_codec_spec_vectors_simple8b_u64_falls_back_for_large_values():
    values = [1 << 61, (1 << 61) + 7, (1 << 61) + 99]
    out = bytearray()
    encode_u64_vector(values, VectorCodecSimple8b, out)
    decoded = decode_u64_vector(new_reader(bytes(out)), VectorCodecSimple8b)
    assert decoded == values


def test_codec_spec_vectors_for_u64_overflow_is_rejected():
    out = bytearray()
    encode_varuint((1 << 64) - 1, out)
    encode_varuint(1, out)
    out.extend([1, 0x01])

    try:
        decode_u64_vector(new_reader(bytes(out)), VectorCodecForBitpack)
        raise AssertionError("expected decode error")
    except Exception as err:
        from twilic import ErrInvalidData

        te = require_twilic_error_kind(err, ErrInvalidData)
        assert te.msg == "u64 FOR overflow"


def test_codec_spec_vectors_direct_bitpack_invalid_width_is_rejected():
    out = bytearray()
    encode_varuint(1, out)
    out.append(0)

    try:
        decode_i64_vector(new_reader(bytes(out)), VectorCodecDirectBitpack)
        raise AssertionError("expected decode error")
    except Exception as err:
        from twilic import ErrInvalidData

        te = require_twilic_error_kind(err, ErrInvalidData)
        assert te.msg == "bitpack width"


def test_codec_spec_vectors_xor_float_roundtrip_smooth_series():
    values = [1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5]
    out = bytearray()
    encode_f64_vector(values, VectorCodecXorFloat, out)
    decoded = decode_f64_vector(new_reader(bytes(out)), VectorCodecXorFloat)
    assert decoded == values
