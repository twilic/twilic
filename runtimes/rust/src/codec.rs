use crate::{
    error::{Result, TwilicError},
    model::VectorCodec,
    wire::{
        DEFAULT_MAX_DECODE_COUNT, Reader, check_byte_len, check_decode_count, check_element_bytes,
        decode_zigzag, encode_varuint, encode_zigzag, extend_repeat_with_budget,
    },
};

pub fn encode_i64_vector(values: &[i64], codec: VectorCodec, out: &mut Vec<u8>) {
    match codec {
        VectorCodec::Rle => encode_i64_rle(values, out),
        VectorCodec::DirectBitpack => encode_i64_direct_bitpack(values, out),
        VectorCodec::DeltaBitpack => {
            encode_bitpacked_values(delta(values).map(encode_zigzag), out);
        }
        VectorCodec::ForBitpack => {
            if values.is_empty() {
                encode_varuint(0, out);
                return;
            }
            let min = *values.iter().min().unwrap_or(&0);
            encode_varuint(encode_zigzag(min), out);
            encode_bitpacked_values(values.iter().map(|v| encode_zigzag(*v - min)), out);
        }
        VectorCodec::DeltaForBitpack => {
            if values.is_empty() {
                encode_varuint(0, out);
                return;
            }
            let deltas = delta(values);
            let min = deltas.clone().min().unwrap_or(0);
            encode_varuint(encode_zigzag(min), out);
            encode_bitpacked_values(deltas.map(|v| encode_zigzag(v - min)), out);
        }
        VectorCodec::DeltaDeltaBitpack => {
            encode_i64_delta_delta(values, out);
        }
        VectorCodec::PatchedFor => encode_i64_patched_for(values, out),
        VectorCodec::Simple8b => encode_i64_simple8b(values, out),
        VectorCodec::Plain
        | VectorCodec::Dictionary
        | VectorCodec::StringRef
        | VectorCodec::PrefixDelta
        | VectorCodec::XorFloat => encode_i64_plain(values, out),
    }
}

pub fn decode_i64_vector(reader: &mut Reader<'_>, codec: VectorCodec) -> Result<Vec<i64>> {
    match codec {
        VectorCodec::Rle => decode_i64_rle(reader),
        VectorCodec::DirectBitpack => decode_i64_direct_bitpack(reader),
        VectorCodec::DeltaBitpack => undelta(decode_i64_direct_bitpack(reader)?),
        VectorCodec::ForBitpack => {
            let min = decode_zigzag(reader.read_varuint()?);
            if reader.is_eof() {
                return Ok(Vec::new());
            }
            let shifted = decode_i64_direct_bitpack(reader)?;
            Ok(shifted.into_iter().map(|v| v + min).collect())
        }
        VectorCodec::DeltaForBitpack => {
            let min = decode_zigzag(reader.read_varuint()?);
            if reader.is_eof() {
                return Ok(Vec::new());
            }
            let shifted = decode_i64_direct_bitpack(reader)?;
            let deltas: Vec<i64> = shifted.into_iter().map(|v| v + min).collect();
            undelta(deltas)
        }
        VectorCodec::DeltaDeltaBitpack => decode_i64_delta_delta(reader),
        VectorCodec::PatchedFor => decode_i64_patched_for(reader),
        VectorCodec::Simple8b => decode_i64_simple8b(reader),
        VectorCodec::Plain
        | VectorCodec::Dictionary
        | VectorCodec::StringRef
        | VectorCodec::PrefixDelta
        | VectorCodec::XorFloat => decode_i64_plain(reader),
    }
}

pub fn encode_u64_vector(values: &[u64], codec: VectorCodec, out: &mut Vec<u8>) {
    match codec {
        VectorCodec::Rle => encode_u64_rle(values, out),
        VectorCodec::DirectBitpack => encode_u64_direct_bitpack(values, out),
        VectorCodec::ForBitpack => {
            if values.is_empty() {
                encode_varuint(0, out);
                return;
            }
            let min = *values.iter().min().unwrap_or(&0);
            encode_varuint(min, out);
            encode_bitpacked_values(values.iter().map(|v| *v - min), out);
        }
        VectorCodec::Plain => encode_u64_plain(values, out),
        VectorCodec::Simple8b => encode_u64_simple8b(values, out),
        VectorCodec::Dictionary
        | VectorCodec::StringRef
        | VectorCodec::PrefixDelta
        | VectorCodec::XorFloat
        | VectorCodec::DeltaBitpack
        | VectorCodec::DeltaForBitpack
        | VectorCodec::DeltaDeltaBitpack
        | VectorCodec::PatchedFor => encode_u64_plain(values, out),
    }
}

pub fn decode_u64_vector(reader: &mut Reader<'_>, codec: VectorCodec) -> Result<Vec<u64>> {
    match codec {
        VectorCodec::Rle => decode_u64_rle(reader),
        VectorCodec::DirectBitpack => decode_u64_direct_bitpack(reader),
        VectorCodec::ForBitpack => {
            let min = reader.read_varuint()?;
            if reader.is_eof() {
                return Ok(Vec::new());
            }
            let shifted = decode_u64_direct_bitpack(reader)?;
            shifted
                .into_iter()
                .map(|v| {
                    v.checked_add(min)
                        .ok_or(TwilicError::InvalidData("u64 FOR overflow"))
                })
                .collect()
        }
        VectorCodec::Plain => decode_u64_plain(reader),
        VectorCodec::Simple8b => decode_u64_simple8b(reader),
        VectorCodec::Dictionary
        | VectorCodec::StringRef
        | VectorCodec::PrefixDelta
        | VectorCodec::XorFloat
        | VectorCodec::DeltaBitpack
        | VectorCodec::DeltaForBitpack
        | VectorCodec::DeltaDeltaBitpack
        | VectorCodec::PatchedFor => decode_u64_plain(reader),
    }
}

fn encode_u64_plain(values: &[u64], out: &mut Vec<u8>) {
    encode_varuint(values.len() as u64, out);
    for value in values {
        encode_varuint(*value, out);
    }
}

fn decode_u64_plain(reader: &mut Reader<'_>) -> Result<Vec<u64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        out.push(reader.read_varuint()?);
    }
    Ok(out)
}

fn encode_u64_rle(values: &[u64], out: &mut Vec<u8>) {
    let mut runs: Vec<(u64, u64)> = Vec::new();
    for value in values {
        if let Some((last, count)) = runs.last_mut()
            && *last == *value
        {
            *count += 1;
            continue;
        }
        runs.push((*value, 1));
    }
    encode_varuint(runs.len() as u64, out);
    for (value, count) in runs {
        encode_varuint(value, out);
        encode_varuint(count, out);
    }
}

fn decode_u64_rle(reader: &mut Reader<'_>) -> Result<Vec<u64>> {
    let start = reader.position();
    let runs_len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    let mut runs = Vec::with_capacity(runs_len);
    for _ in 0..runs_len {
        let value = reader.read_varuint()?;
        let count = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
        runs.push((value, count));
    }
    let budget_input = reader.position() - start;
    let mut out = Vec::new();
    for (value, count) in runs {
        reader.claim_output(count, 8)?;
        extend_repeat_with_budget(&mut out, value, count, 8, Some(budget_input))?;
    }
    Ok(out)
}

fn encode_u64_direct_bitpack(values: &[u64], out: &mut Vec<u8>) {
    encode_bitpacked_values(values.iter().copied(), out);
}

fn decode_u64_direct_bitpack(reader: &mut Reader<'_>) -> Result<Vec<u64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    let width = reader.read_u8()?;
    if len == 0 {
        return Ok(Vec::new());
    }
    if width == 0 || width > 64 {
        return Err(TwilicError::InvalidData("bitpack width"));
    }
    unpack_u64_values(reader, len, width)
}

pub fn encode_f64_vector(values: &[f64], codec: VectorCodec, out: &mut Vec<u8>) {
    if matches!(codec, VectorCodec::XorFloat) {
        encode_xor_float(values, out);
        return;
    }
    encode_varuint(values.len() as u64, out);
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

pub fn decode_f64_vector(reader: &mut Reader<'_>, codec: VectorCodec) -> Result<Vec<f64>> {
    if matches!(codec, VectorCodec::XorFloat) {
        return decode_xor_float(reader);
    }
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    check_element_bytes(len, 8, reader.remaining(), DEFAULT_MAX_DECODE_COUNT)?;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(reader.read_exact(8)?);
        out.push(f64::from_le_bytes(bytes));
    }
    Ok(out)
}

fn encode_i64_plain(values: &[i64], out: &mut Vec<u8>) {
    encode_varuint(values.len() as u64, out);
    for value in values {
        encode_varuint(encode_zigzag(*value), out);
    }
}

fn decode_i64_plain(reader: &mut Reader<'_>) -> Result<Vec<i64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        out.push(decode_zigzag(reader.read_varuint()?));
    }
    Ok(out)
}

fn encode_i64_simple8b(values: &[i64], out: &mut Vec<u8>) {
    let encoded: Vec<u64> = values.iter().map(|v| encode_zigzag(*v)).collect();
    encode_u64_simple8b_inner(&encoded, out);
}

fn decode_i64_simple8b(reader: &mut Reader<'_>) -> Result<Vec<i64>> {
    let encoded = decode_u64_simple8b_inner(reader)?;
    Ok(encoded.into_iter().map(decode_zigzag).collect())
}

fn encode_u64_simple8b(values: &[u64], out: &mut Vec<u8>) {
    encode_u64_simple8b_inner(values, out);
}

fn decode_u64_simple8b(reader: &mut Reader<'_>) -> Result<Vec<u64>> {
    decode_u64_simple8b_inner(reader)
}

const SIMPLE8B_SLOTS: [(usize, u8); 14] = [
    (60, 1),
    (30, 2),
    (20, 3),
    (15, 4),
    (12, 5),
    (10, 6),
    (8, 7),
    (7, 8),
    (6, 10),
    (5, 12),
    (4, 15),
    (3, 20),
    (2, 30),
    (1, 60),
];

fn encode_u64_simple8b_inner(values: &[u64], out: &mut Vec<u8>) {
    encode_varuint(values.len() as u64, out);
    if values.is_empty() {
        return;
    }
    let max_value = values.iter().copied().max().unwrap_or(0);
    if max_value > ((1u64 << 60) - 1) {
        out.push(0);
        for value in values {
            encode_varuint(*value, out);
        }
        return;
    }

    out.push(1);
    let mut idx = 0usize;
    while idx < values.len() {
        let mut zero_run = 0usize;
        while idx + zero_run < values.len() && values[idx + zero_run] == 0 && zero_run < 240 {
            zero_run += 1;
        }
        if zero_run >= 120 {
            let take = if zero_run >= 240 { 240 } else { 120 };
            let word = if take == 240 { 0u64 } else { 1u64 << 60 };
            out.extend_from_slice(&word.to_le_bytes());
            idx += take;
            continue;
        }

        let mut packed = false;
        for (selector_idx, (count, width)) in SIMPLE8B_SLOTS.iter().enumerate() {
            if idx + count > values.len() {
                continue;
            }
            let max_encodable = if *width == 64 {
                u64::MAX
            } else {
                (1u64 << *width) - 1
            };
            if values[idx..idx + count]
                .iter()
                .all(|value| *value <= max_encodable)
            {
                let selector = (selector_idx as u64) + 2;
                let mut payload = 0u64;
                let mut shift = 0u32;
                for value in &values[idx..idx + count] {
                    payload |= *value << shift;
                    shift += *width as u32;
                }
                let word = (selector << 60) | payload;
                out.extend_from_slice(&word.to_le_bytes());
                idx += count;
                packed = true;
                break;
            }
        }
        if !packed {
            let selector = 15u64;
            let word = (selector << 60) | (values[idx] & ((1u64 << 60) - 1));
            out.extend_from_slice(&word.to_le_bytes());
            idx += 1;
        }
    }
}

fn decode_u64_simple8b_inner(reader: &mut Reader<'_>) -> Result<Vec<u64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    if len == 0 {
        return Ok(Vec::new());
    }
    let mode = reader.read_u8()?;
    if mode == 0 {
        let mut out = Vec::with_capacity(len);
        for _ in 0..len {
            out.push(reader.read_varuint()?);
        }
        return Ok(out);
    }
    if mode != 1 {
        return Err(TwilicError::InvalidData("simple8b mode"));
    }

    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        let mut word = [0u8; 8];
        word.copy_from_slice(reader.read_exact(8)?);
        let packed = u64::from_le_bytes(word);
        let selector = (packed >> 60) as usize;
        let payload = packed & ((1u64 << 60) - 1);
        match selector {
            0 | 1 => {
                let count = if selector == 0 { 240 } else { 120 };
                let remain = len.saturating_sub(out.len());
                out.extend(std::iter::repeat_n(0u64, count.min(remain)));
            }
            2..=15 => {
                let (count, width) = if selector == 15 {
                    (1usize, 60u8)
                } else {
                    SIMPLE8B_SLOTS[selector - 2]
                };
                let mask = if width == 64 {
                    u64::MAX
                } else {
                    (1u64 << width) - 1
                };
                let mut shift = 0u32;
                let remain = len.saturating_sub(out.len());
                for _ in 0..count.min(remain) {
                    out.push((payload >> shift) & mask);
                    shift += width as u32;
                }
            }
            _ => return Err(TwilicError::InvalidData("simple8b selector")),
        }
    }
    Ok(out)
}

fn delta(values: &[i64]) -> impl ExactSizeIterator<Item = i64> + Clone + '_ {
    values.iter().enumerate().map(|(idx, value)| {
        if idx == 0 {
            *value
        } else {
            *value - values[idx - 1]
        }
    })
}

fn undelta(values: Vec<i64>) -> Result<Vec<i64>> {
    let mut out = Vec::with_capacity(values.len());
    let mut prev = 0i64;
    for (idx, value) in values.into_iter().enumerate() {
        if idx == 0 {
            out.push(value);
            prev = value;
            continue;
        }
        let next = prev
            .checked_add(value)
            .ok_or(TwilicError::InvalidData("delta overflow"))?;
        out.push(next);
        prev = next;
    }
    Ok(out)
}

fn encode_i64_rle(values: &[i64], out: &mut Vec<u8>) {
    let mut runs: Vec<(i64, u64)> = Vec::new();
    for value in values {
        if let Some((last, count)) = runs.last_mut()
            && *last == *value
        {
            *count += 1;
            continue;
        }
        runs.push((*value, 1));
    }
    encode_varuint(runs.len() as u64, out);
    for (value, count) in runs {
        encode_varuint(encode_zigzag(value), out);
        encode_varuint(count, out);
    }
}

fn decode_i64_rle(reader: &mut Reader<'_>) -> Result<Vec<i64>> {
    let start = reader.position();
    let runs_len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    let mut runs = Vec::with_capacity(runs_len);
    for _ in 0..runs_len {
        let value = decode_zigzag(reader.read_varuint()?);
        let count = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
        runs.push((value, count));
    }
    let budget_input = reader.position() - start;
    let mut out = Vec::new();
    for (value, count) in runs {
        reader.claim_output(count, 8)?;
        extend_repeat_with_budget(&mut out, value, count, 8, Some(budget_input))?;
    }
    Ok(out)
}

fn encode_i64_patched_for(values: &[i64], out: &mut Vec<u8>) {
    if values.is_empty() {
        encode_varuint(0, out);
        return;
    }
    let base = *values.iter().min().unwrap_or(&0);
    let shifted: Vec<i64> = values.iter().map(|v| *v - base).collect();
    encode_varuint(shifted.len() as u64, out);
    encode_varuint(encode_zigzag(base), out);

    let mut max = 0i64;
    for value in &shifted {
        if *value > max {
            max = *value;
        }
    }
    let base_width = bit_width(max as u64).saturating_sub(2);
    out.push(base_width);

    let mut patch_positions = Vec::new();
    let mut main_values = Vec::with_capacity(shifted.len());
    for (idx, value) in shifted.into_iter().enumerate() {
        if bit_width(value as u64) > base_width {
            patch_positions.push((idx as u64, value));
            main_values.push((value & ((1i64 << base_width) - 1)).max(0));
        } else {
            main_values.push(value);
        }
    }
    for value in main_values {
        encode_varuint(value as u64, out);
    }
    encode_varuint(patch_positions.len() as u64, out);
    for (pos, value) in patch_positions {
        encode_varuint(pos, out);
        encode_varuint(value as u64, out);
    }
}

fn decode_i64_patched_for(reader: &mut Reader<'_>) -> Result<Vec<i64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    if len == 0 {
        return Ok(Vec::new());
    }
    let base = decode_zigzag(reader.read_varuint()?);
    let _base_width = reader.read_u8()?;
    let mut values = Vec::with_capacity(len);
    for _ in 0..len {
        values.push(reader.read_varuint()? as i64);
    }
    let patch_count = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    for _ in 0..patch_count {
        let pos = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
        let patch = reader.read_varuint()? as i64;
        if let Some(slot) = values.get_mut(pos) {
            *slot = patch;
        }
    }
    Ok(values.into_iter().map(|v| v + base).collect())
}

fn encode_xor_float(values: &[f64], out: &mut Vec<u8>) {
    encode_varuint(values.len() as u64, out);
    if values.is_empty() {
        return;
    }
    out.extend_from_slice(&values[0].to_bits().to_le_bytes());
    let mut prev = values[0].to_bits();
    for value in values.iter().skip(1) {
        let bits = value.to_bits();
        let x = prev ^ bits;
        if x == 0 {
            out.push(0);
        } else {
            out.push(1);
            let leading = x.leading_zeros() as u64;
            let trailing = x.trailing_zeros() as u64;
            let width = 64u64.saturating_sub(leading + trailing);
            encode_varuint(leading, out);
            encode_varuint(trailing, out);
            encode_varuint(width, out);
            let payload = if width == 64 {
                x
            } else {
                (x >> trailing) & ((1u64 << width) - 1)
            };
            encode_varuint(payload, out);
        }
        prev = bits;
    }
}

fn decode_xor_float(reader: &mut Reader<'_>) -> Result<Vec<f64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    if len == 0 {
        return Ok(Vec::new());
    }
    let mut first = [0u8; 8];
    first.copy_from_slice(reader.read_exact(8)?);
    let first_bits = u64::from_le_bytes(first);
    let mut out = Vec::with_capacity(len);
    out.push(f64::from_bits(first_bits));
    let mut prev = first_bits;
    for _ in 1..len {
        let flag = reader.read_u8()?;
        let bits = if flag == 0 {
            prev
        } else {
            let leading = reader.read_varuint()?;
            let trailing = reader.read_varuint()?;
            let width = reader.read_varuint()?;
            let payload = reader.read_varuint()?;
            if leading + trailing + width > 64 {
                return Err(TwilicError::InvalidData("xor-float bit widths"));
            }
            let x = if width == 64 {
                payload
            } else {
                payload << trailing
            };
            prev ^ x
        };
        out.push(f64::from_bits(bits));
        prev = bits;
    }
    Ok(out)
}

fn encode_i64_direct_bitpack(values: &[i64], out: &mut Vec<u8>) {
    encode_bitpacked_values(values.iter().map(|v| encode_zigzag(*v)), out);
}

fn decode_i64_direct_bitpack(reader: &mut Reader<'_>) -> Result<Vec<i64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    let width = reader.read_u8()?;
    if len == 0 {
        return Ok(Vec::new());
    }
    if width == 0 || width > 64 {
        return Err(TwilicError::InvalidData("bitpack width"));
    }
    let encoded = unpack_u64_values(reader, len, width)?;
    Ok(encoded.into_iter().map(decode_zigzag).collect())
}

fn encode_i64_delta_delta(values: &[i64], out: &mut Vec<u8>) {
    encode_varuint(values.len() as u64, out);
    if values.is_empty() {
        return;
    }
    encode_varuint(encode_zigzag(values[0]), out);
    if values.len() == 1 {
        return;
    }
    let d1 = values[1] - values[0];
    encode_varuint(encode_zigzag(d1), out);
    let dd = values.windows(3).map(|triple| {
        let previous_delta = triple[1] - triple[0];
        let next_delta = triple[2] - triple[1];
        encode_zigzag(next_delta - previous_delta)
    });
    encode_bitpacked_values(dd, out);
}

fn decode_i64_delta_delta(reader: &mut Reader<'_>) -> Result<Vec<i64>> {
    let len = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
    if len == 0 {
        return Ok(Vec::new());
    }
    let first = decode_zigzag(reader.read_varuint()?);
    if len == 1 {
        return Ok(vec![first]);
    }
    let first_delta = decode_zigzag(reader.read_varuint()?);
    let dd = decode_i64_direct_bitpack(reader)?;
    if dd.len() != len.saturating_sub(2) {
        return Err(TwilicError::InvalidData("delta-delta length"));
    }
    let mut out = Vec::with_capacity(len);
    out.push(first);
    let mut prev = first;
    let second = prev
        .checked_add(first_delta)
        .ok_or(TwilicError::InvalidData("delta-delta overflow"))?;
    out.push(second);
    prev = second;
    let mut prev_delta = first_delta;
    for ddv in dd {
        let d = prev_delta
            .checked_add(ddv)
            .ok_or(TwilicError::InvalidData("delta-delta overflow"))?;
        let next = prev
            .checked_add(d)
            .ok_or(TwilicError::InvalidData("delta-delta overflow"))?;
        out.push(next);
        prev = next;
        prev_delta = d;
    }
    Ok(out)
}

// Replay cheap transformations instead of materializing temporary vectors. OR
// preserves the highest set bit, so one bit-width calculation gives exactly the
// same width as taking the maximum of each value's width (including all zeros).
fn encode_bitpacked_values(values: impl ExactSizeIterator<Item = u64> + Clone, out: &mut Vec<u8>) {
    encode_varuint(values.len() as u64, out);
    if values.len() == 0 {
        out.push(0);
        return;
    }
    let width = bit_width(values.clone().fold(0, |bits, value| bits | value));
    out.push(width);
    pack_u64_values(values, width, out);
}

fn pack_u64_values(values: impl Iterator<Item = u64>, width: u8, out: &mut Vec<u8>) {
    let mut acc = 0u128;
    let mut acc_bits = 0u32;
    for value in values {
        acc |= (value as u128) << acc_bits;
        acc_bits += width as u32;
        while acc_bits >= 8 {
            out.push((acc & 0xFF) as u8);
            acc >>= 8;
            acc_bits -= 8;
        }
    }
    if acc_bits > 0 {
        out.push(acc as u8);
    }
}

fn unpack_u64_values(reader: &mut Reader<'_>, len: usize, width: u8) -> Result<Vec<u64>> {
    check_decode_count(len, DEFAULT_MAX_DECODE_COUNT)?;
    let total_bits = len.saturating_mul(width as usize);
    let byte_len = total_bits.div_ceil(8);
    check_byte_len(byte_len, reader.remaining())?;
    let bytes = reader.read_exact(byte_len)?;
    let mut out = Vec::with_capacity(len);
    let mut acc = 0u128;
    let mut acc_bits = 0u32;
    let mut idx = 0usize;
    for _ in 0..len {
        while acc_bits < width as u32 {
            let b = *bytes
                .get(idx)
                .ok_or(TwilicError::InvalidData("bitpack underflow"))?;
            idx += 1;
            acc |= (b as u128) << acc_bits;
            acc_bits += 8;
        }
        let mask = if width == 64 {
            u128::from(u64::MAX)
        } else {
            (1u128 << width) - 1
        };
        out.push((acc & mask) as u64);
        acc >>= width;
        acc_bits -= width as u32;
    }
    Ok(out)
}

fn bit_width(v: u64) -> u8 {
    if v == 0 {
        1
    } else {
        (u64::BITS - v.leading_zeros()) as u8
    }
}
