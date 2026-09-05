use twilic::{
    codec::{decode_i64_vector, decode_u64_vector, encode_i64_vector, encode_u64_vector},
    model::VectorCodec,
    wire::Reader,
};

// Independent, deliberately simple wire oracle: write one bit at a time instead
// of using the production accumulator, bit-width helper, or varuint encoder.
fn varuint(mut value: u64, out: &mut Vec<u8>) {
    while value >= 128 {
        out.push((value % 128) as u8 | 0x80);
        value /= 128;
    }
    out.push(value as u8);
}

fn zigzag(value: i64) -> u64 {
    if value < 0 {
        (-2 * i128::from(value) - 1) as u64
    } else {
        (2 * i128::from(value)) as u64
    }
}

fn bitpack(values: &[u64], out: &mut Vec<u8>) {
    varuint(values.len() as u64, out);
    if values.is_empty() {
        out.push(0);
        return;
    }
    let mut width = 1usize;
    while width < 64 && values.iter().any(|value| value >> width != 0) {
        width += 1;
    }
    out.push(width as u8);
    let start = out.len();
    out.resize(start + (values.len() * width).div_ceil(8), 0);
    for (index, value) in values.iter().enumerate() {
        for bit in 0..width {
            let position = index * width + bit;
            out[start + position / 8] |= (((value >> bit) & 1) as u8) << (position % 8);
        }
    }
}

fn deltas(values: &[i64]) -> Vec<i64> {
    values
        .iter()
        .enumerate()
        .map(|(i, value)| {
            if i == 0 {
                *value
            } else {
                value.checked_sub(values[i - 1]).unwrap()
            }
        })
        .collect()
}

fn reference_i64(values: &[i64], codec: VectorCodec) -> Vec<u8> {
    let mut out = Vec::new();
    let transformed = match codec {
        VectorCodec::DirectBitpack => values.to_vec(),
        VectorCodec::DeltaBitpack => deltas(values),
        VectorCodec::ForBitpack | VectorCodec::DeltaForBitpack => {
            if values.is_empty() {
                return vec![0];
            }
            let source = if codec == VectorCodec::ForBitpack {
                values.to_vec()
            } else {
                deltas(values)
            };
            let min = *source.iter().min().unwrap();
            varuint(zigzag(min), &mut out);
            source
                .iter()
                .map(|value| value.checked_sub(min).unwrap())
                .collect()
        }
        VectorCodec::DeltaDeltaBitpack => {
            varuint(values.len() as u64, &mut out);
            if values.is_empty() {
                return out;
            }
            varuint(zigzag(values[0]), &mut out);
            if values.len() == 1 {
                return out;
            }
            let delta = deltas(values);
            varuint(zigzag(delta[1]), &mut out);
            delta[1..]
                .windows(2)
                .map(|pair| pair[1].checked_sub(pair[0]).unwrap())
                .collect()
        }
        _ => unreachable!(),
    };
    bitpack(
        &transformed.into_iter().map(zigzag).collect::<Vec<_>>(),
        &mut out,
    );
    out
}

fn check_i64(values: &[i64], codec: VectorCodec) {
    let expected = reference_i64(values, codec);
    // The codec must append without changing a preceding envelope.
    let mut actual = vec![0xAA, 0x55];
    encode_i64_vector(values, codec, &mut actual);
    assert_eq!(&actual[..2], &[0xAA, 0x55]);
    assert_eq!(&actual[2..], expected, "codec={codec:?}, values={values:?}");
    let mut reader = Reader::new(&actual[2..]);
    assert_eq!(decode_i64_vector(&mut reader, codec).unwrap(), values);
    assert!(reader.is_eof());
}

#[test]
fn signed_bitpack_matches_reference_for_all_widths() {
    for width in 1..=64 {
        let mask = u64::MAX >> (64 - width);
        let values: Vec<i64> = [0, 1, mask / 2, mask, 2, mask - 1, mask, 0, 1]
            .iter()
            .map(|v| ((v >> 1) as i64) ^ -((v & 1) as i64))
            .collect();
        check_i64(&values, VectorCodec::DirectBitpack);
    }
    check_i64(&[i64::MIN, i64::MAX, -1, 0, 1], VectorCodec::DirectBitpack);
}

#[test]
fn signed_transforms_preserve_empty_short_and_random_blocks() {
    let codecs = [
        VectorCodec::DirectBitpack,
        VectorCodec::DeltaBitpack,
        VectorCodec::ForBitpack,
        VectorCodec::DeltaForBitpack,
        VectorCodec::DeltaDeltaBitpack,
    ];
    let mut seed = 0x1234_5678_9ABC_DEF0u64;
    for length in [0, 1, 2, 3, 4, 7, 8, 9, 63, 64, 65, 127, 128, 129, 256] {
        let random: Vec<i64> = (0..length)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                (seed % 2_000_001) as i64 - 1_000_000
            })
            .collect();
        for values in [
            random,
            vec![0; length],
            vec![-42; length],
            (0..length).map(|i| 1000 - i as i64 * 7).collect(),
        ] {
            for codec in codecs {
                check_i64(&values, codec);
            }
        }
    }
    for codec in [
        VectorCodec::ForBitpack,
        VectorCodec::DeltaBitpack,
        VectorCodec::DeltaForBitpack,
        VectorCodec::DeltaDeltaBitpack,
    ] {
        check_i64(&[i64::MAX - 2, i64::MAX - 1, i64::MAX], codec);
    }
    check_i64(
        &[i64::MIN, i64::MIN + 1, i64::MIN + 2],
        VectorCodec::ForBitpack,
    );
}

#[test]
fn unsigned_bitpack_preserves_all_widths_and_for_bases() {
    for width in 1..=64 {
        let max = u64::MAX >> (64 - width);
        for values in [
            vec![],
            vec![0],
            vec![u64::MAX],
            vec![0, max, max / 2, 1],
            vec![u64::MAX - 7, u64::MAX - 3, u64::MAX],
        ] {
            for codec in [VectorCodec::DirectBitpack, VectorCodec::ForBitpack] {
                let mut expected = Vec::new();
                if codec == VectorCodec::ForBitpack {
                    let min = values.iter().copied().min().unwrap_or(0);
                    varuint(min, &mut expected);
                    if !values.is_empty() {
                        bitpack(
                            &values.iter().map(|v| v - min).collect::<Vec<_>>(),
                            &mut expected,
                        );
                    }
                } else {
                    bitpack(&values, &mut expected);
                }
                let mut actual = vec![0xAA];
                encode_u64_vector(&values, codec, &mut actual);
                assert_eq!(actual[0], 0xAA);
                assert_eq!(&actual[1..], expected);
                let mut reader = Reader::new(&actual[1..]);
                assert_eq!(decode_u64_vector(&mut reader, codec).unwrap(), values);
                assert!(reader.is_eof());
            }
        }
    }
}
