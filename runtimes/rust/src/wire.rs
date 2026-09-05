use crate::error::{Result, TwilicError};

pub const DEFAULT_MAX_DECODE_COUNT: usize = 1 << 20;
pub const DEFAULT_MAX_DECODE_OUTPUT_RATIO: usize = 1 << 10;

pub const DECODE_COUNT_LIMIT_MSG: &str = "decode count limit exceeded";
pub const DECODE_LENGTH_OVERFLOW_MSG: &str = "decode length overflow";
pub const DECODE_OUTPUT_RATIO_MSG: &str = "decode output ratio exceeded";

#[inline]
pub fn check_decode_count(count: usize, max: usize) -> Result<()> {
    if count > max {
        return Err(TwilicError::InvalidData(DECODE_COUNT_LIMIT_MSG));
    }
    Ok(())
}

#[inline]
pub fn check_byte_len(len: usize, remaining: usize) -> Result<()> {
    if len > remaining {
        return Err(TwilicError::InvalidData(DECODE_LENGTH_OVERFLOW_MSG));
    }
    Ok(())
}

#[inline]
pub fn check_element_bytes(
    count: usize,
    element_bytes: usize,
    remaining: usize,
    max: usize,
) -> Result<()> {
    check_decode_count(count, max)?;
    match count.checked_mul(element_bytes) {
        Some(needed) if needed <= remaining => Ok(()),
        _ => Err(TwilicError::InvalidData(DECODE_LENGTH_OVERFLOW_MSG)),
    }
}

#[inline]
pub fn max_decode_output_bytes(input_len: usize) -> usize {
    input_len
        .saturating_mul(DEFAULT_MAX_DECODE_OUTPUT_RATIO)
        .min(DEFAULT_MAX_DECODE_COUNT)
}

#[inline]
pub fn check_decode_output_bytes(output_bytes: usize, input_len: usize) -> Result<()> {
    if output_bytes > max_decode_output_bytes(input_len) {
        return Err(TwilicError::InvalidData(DECODE_OUTPUT_RATIO_MSG));
    }
    Ok(())
}

pub fn extend_repeat<T: Clone>(out: &mut Vec<T>, value: T, count: usize) -> Result<()> {
    extend_repeat_with_budget(out, value, count, 1, None)
}

pub fn extend_repeat_with_budget<T: Clone>(
    out: &mut Vec<T>,
    value: T,
    count: usize,
    element_bytes: usize,
    input_len: Option<usize>,
) -> Result<()> {
    let new_len = out
        .len()
        .checked_add(count)
        .ok_or(TwilicError::InvalidData(DECODE_COUNT_LIMIT_MSG))?;
    check_decode_count(new_len, DEFAULT_MAX_DECODE_COUNT)?;
    if let Some(input_len) = input_len {
        let output_bytes = new_len
            .checked_mul(element_bytes)
            .ok_or(TwilicError::InvalidData(DECODE_OUTPUT_RATIO_MSG))?;
        check_decode_output_bytes(output_bytes, input_len)?;
    }
    out.extend(std::iter::repeat_n(value, count));
    Ok(())
}

#[inline(always)]
pub fn encode_varuint(mut value: u64, out: &mut Vec<u8>) {
    if value < 0x80 {
        out.push(value as u8);
        return;
    }
    loop {
        let mut byte = (value & 0x7F) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
}

#[inline(always)]
pub fn encode_zigzag(value: i64) -> u64 {
    ((value << 1) ^ (value >> 63)) as u64
}

#[inline(always)]
pub fn decode_zigzag(value: u64) -> i64 {
    ((value >> 1) as i64) ^ -((value & 1) as i64)
}

#[inline(always)]
pub fn encode_bytes(bytes: &[u8], out: &mut Vec<u8>) {
    encode_varuint(bytes.len() as u64, out);
    out.extend_from_slice(bytes);
}

#[inline(always)]
pub fn encode_string(value: &str, out: &mut Vec<u8>) {
    encode_bytes(value.as_bytes(), out);
}

pub fn encode_bitmap(bits: &[bool], out: &mut Vec<u8>) {
    encode_varuint(bits.len() as u64, out);
    let mut current = 0u8;
    for (i, bit) in bits.iter().enumerate() {
        if *bit {
            current |= 1 << (i % 8);
        }
        if i % 8 == 7 {
            out.push(current);
            current = 0;
        }
    }
    if !bits.len().is_multiple_of(8) {
        out.push(current);
    }
}

pub struct Reader<'a> {
    input: &'a [u8],
    offset: usize,
    depth: usize,
    output_bytes: usize,
}

impl<'a> Reader<'a> {
    pub fn new(input: &'a [u8]) -> Self {
        Self {
            input,
            offset: 0,
            depth: 0,
            output_bytes: 0,
        }
    }

    pub fn enter_depth(&mut self) -> Result<()> {
        if self.depth >= crate::v2::DEFAULT_MAX_DECODE_DEPTH {
            return Err(TwilicError::InvalidData("decode depth limit exceeded"));
        }
        self.depth += 1;
        Ok(())
    }

    pub fn leave_depth(&mut self) {
        self.depth -= 1;
    }

    pub fn claim_output(&mut self, count: usize, width: usize) -> Result<()> {
        check_decode_count(count, DEFAULT_MAX_DECODE_COUNT)?;
        let bytes = count
            .checked_mul(width)
            .and_then(|n| self.output_bytes.checked_add(n))
            .ok_or(TwilicError::InvalidData(DECODE_OUTPUT_RATIO_MSG))?;
        check_decode_output_bytes(bytes, self.input.len())?;
        self.output_bytes = bytes;
        Ok(())
    }

    pub fn position(&self) -> usize {
        self.offset
    }

    pub fn input_len(&self) -> usize {
        self.input.len()
    }

    pub fn remaining(&self) -> usize {
        self.input.len().saturating_sub(self.offset)
    }

    pub fn is_eof(&self) -> bool {
        self.offset >= self.input.len()
    }

    pub fn read_bounded_count(&mut self, max: usize) -> Result<usize> {
        let raw = self.read_varuint()?;
        let count =
            usize::try_from(raw).map_err(|_| TwilicError::InvalidData(DECODE_COUNT_LIMIT_MSG))?;
        check_decode_count(count, max)?;
        Ok(count)
    }

    pub fn read_u8(&mut self) -> Result<u8> {
        let byte = *self
            .input
            .get(self.offset)
            .ok_or(TwilicError::UnexpectedEof)?;
        self.offset += 1;
        Ok(byte)
    }

    pub fn read_exact(&mut self, len: usize) -> Result<&'a [u8]> {
        check_byte_len(len, self.remaining())?;
        let end = self
            .offset
            .checked_add(len)
            .ok_or(TwilicError::InvalidData("offset overflow"))?;
        let slice = self
            .input
            .get(self.offset..end)
            .ok_or(TwilicError::UnexpectedEof)?;
        self.offset = end;
        Ok(slice)
    }

    #[inline(always)]
    pub fn read_varuint(&mut self) -> Result<u64> {
        let start = self.offset;
        let mut shift = 0u32;
        let mut result = 0u64;
        loop {
            if shift >= 64 {
                return Err(TwilicError::InvalidData("varuint too large"));
            }
            let byte = self.read_u8()?;
            if shift == 63 && (byte & 0x7E) != 0 {
                return Err(TwilicError::InvalidData("varuint too large"));
            }
            result |= ((byte & 0x7F) as u64) << shift;
            if (byte & 0x80) == 0 {
                let len = self.offset.saturating_sub(start);
                if len != varuint_encoded_len(result) {
                    return Err(TwilicError::InvalidData("varuint overlong"));
                }
                return Ok(result);
            }
            shift += 7;
        }
    }

    pub fn read_i64_zigzag(&mut self) -> Result<i64> {
        let encoded = self.read_varuint()?;
        Ok(decode_zigzag(encoded))
    }

    pub fn read_bytes(&mut self) -> Result<Vec<u8>> {
        let len = self.read_bounded_count(self.remaining())?;
        Ok(self.read_exact(len)?.to_vec())
    }

    pub fn read_string(&mut self) -> Result<String> {
        let len = self.read_bounded_count(self.remaining())?;
        let bytes = self.read_exact(len)?;
        let value = std::str::from_utf8(bytes).map_err(|_| TwilicError::Utf8Error)?;
        Ok(value.to_owned())
    }

    pub fn read_bitmap(&mut self) -> Result<Vec<bool>> {
        let bit_count = self.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
        let byte_count = bit_count.div_ceil(8);
        check_byte_len(byte_count, self.remaining())?;
        let bytes = self.read_exact(byte_count)?;
        let mut bits = Vec::with_capacity(bit_count);
        for i in 0..bit_count {
            let byte = bytes[i / 8];
            bits.push(((byte >> (i % 8)) & 1) == 1);
        }
        Ok(bits)
    }
}

#[inline]
fn varuint_encoded_len(value: u64) -> usize {
    if value == 0 {
        return 1;
    }
    ((u64::BITS - value.leading_zeros()) as usize).div_ceil(7)
}
