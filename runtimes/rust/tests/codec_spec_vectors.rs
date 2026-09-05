use twilic as twilic_rust;

use twilic_rust::{
    TwilicError,
    codec::{
        decode_f64_vector, decode_i64_vector, decode_u64_vector, encode_f64_vector,
        encode_i64_vector, encode_u64_vector,
    },
    model::VectorCodec,
    wire::{DECODE_OUTPUT_RATIO_MSG, Reader, encode_varuint},
};

#[test]
fn vector_rle_rejects_decompression_bomb_despite_trailing_column_bytes() {
    let mut rle = Vec::new();
    encode_varuint(1, &mut rle);
    encode_varuint(0, &mut rle);
    encode_varuint(100_000, &mut rle);
    let rle_byte_len = rle.len();
    let mut bytes = rle;
    bytes.extend(std::iter::repeat_n(0u8, 16 * 1024));

    let mut reader = Reader::new(&bytes);
    let err =
        decode_u64_vector(&mut reader, VectorCodec::Rle).expect_err("expected output ratio error");
    assert!(err.to_string().contains(DECODE_OUTPUT_RATIO_MSG));
    assert_eq!(reader.position(), rle_byte_len);
}

#[test]
fn simple8b_i64_roundtrip_small_values() {
    let values = vec![1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5];
    let mut out = Vec::new();
    encode_i64_vector(&values, VectorCodec::Simple8b, &mut out);
    let mut reader = Reader::new(&out);
    let decoded =
        decode_i64_vector(&mut reader, VectorCodec::Simple8b).expect("decode simple8b i64");
    assert_eq!(decoded, values);
}

#[test]
fn simple8b_u64_roundtrip_with_long_zero_runs() {
    let mut values = vec![0u64; 130];
    values.extend(vec![1, 2, 3, 4, 5]);
    values.extend(vec![0u64; 250]);

    let mut out = Vec::new();
    encode_u64_vector(&values, VectorCodec::Simple8b, &mut out);
    let mut reader = Reader::new(&out);
    let decoded =
        decode_u64_vector(&mut reader, VectorCodec::Simple8b).expect("decode simple8b u64");
    assert_eq!(decoded, values);
}

#[test]
fn simple8b_u64_falls_back_for_large_values() {
    let values = vec![1u64 << 61, (1u64 << 61) + 7, (1u64 << 61) + 99];
    let mut out = Vec::new();
    encode_u64_vector(&values, VectorCodec::Simple8b, &mut out);
    let mut reader = Reader::new(&out);
    let decoded =
        decode_u64_vector(&mut reader, VectorCodec::Simple8b).expect("decode fallback simple8b");
    assert_eq!(decoded, values);
}

#[test]
fn for_u64_overflow_is_rejected() {
    let mut bytes = Vec::new();
    encode_varuint(u64::MAX, &mut bytes);
    encode_varuint(1, &mut bytes);
    bytes.push(1);
    bytes.push(0x01);

    let mut reader = Reader::new(&bytes);
    let err =
        decode_u64_vector(&mut reader, VectorCodec::ForBitpack).expect_err("overflow expected");
    assert!(matches!(err, TwilicError::InvalidData("u64 FOR overflow")));
}

#[test]
fn direct_bitpack_invalid_width_is_rejected() {
    let mut bytes = Vec::new();
    encode_varuint(1, &mut bytes);
    bytes.push(0);
    let mut reader = Reader::new(&bytes);
    let err = decode_i64_vector(&mut reader, VectorCodec::DirectBitpack)
        .expect_err("invalid width expected");
    assert!(matches!(err, TwilicError::InvalidData("bitpack width")));
}

#[test]
fn xor_float_roundtrip_smooth_series() {
    let values = vec![1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5];
    let mut out = Vec::new();
    encode_f64_vector(&values, VectorCodec::XorFloat, &mut out);
    let mut reader = Reader::new(&out);
    let decoded = decode_f64_vector(&mut reader, VectorCodec::XorFloat).expect("decode xor float");
    assert_eq!(decoded, values);
}
