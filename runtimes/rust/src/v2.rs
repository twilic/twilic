use ahash::HashMap;

use crate::{
    error::{Result, TwilicError},
    model::Value,
    wire::{DEFAULT_MAX_DECODE_COUNT, Reader, check_byte_len, check_decode_count, encode_varuint},
};

const NULL_TAG: u8 = 0xC0;
const FALSE_TAG: u8 = 0xC1;
const TRUE_TAG: u8 = 0xC2;
const F64_TAG: u8 = 0xC3;
const U8_TAG: u8 = 0xC4;
const U16_TAG: u8 = 0xC5;
const U32_TAG: u8 = 0xC6;
const U64_TAG: u8 = 0xC7;
const I8_TAG: u8 = 0xC8;
const I16_TAG: u8 = 0xC9;
const I32_TAG: u8 = 0xCA;
const I64_TAG: u8 = 0xCB;
const BIN8_TAG: u8 = 0xCC;
const BIN16_TAG: u8 = 0xCD;
const BIN32_TAG: u8 = 0xCE;
const STR8_TAG: u8 = 0xCF;
const STR16_TAG: u8 = 0xD0;
const STR32_TAG: u8 = 0xD1;
const ARRAY16_TAG: u8 = 0xD2;
const ARRAY32_TAG: u8 = 0xD3;
const MAP16_TAG: u8 = 0xD4;
const MAP32_TAG: u8 = 0xD5;
const SHAPE_DEF_TAG: u8 = 0xD6;
const KEY_REF_TAG: u8 = 0xD8;
const STR_REF_TAG: u8 = 0xD9;

#[derive(Default)]
struct EncodeState {
    key_ids: HashMap<String, u64>,
    str_ids: HashMap<String, u64>,
    shape_ids: HashMap<Vec<String>, u64>,
    next_key_id: u64,
    next_str_id: u64,
    next_shape_id: u64,
}

pub const DEFAULT_MAX_DECODE_DEPTH: usize = 64;

const DECODE_DEPTH_LIMIT_MSG: &str = "decode depth limit exceeded";
const DECODE_SHAPE_LIMIT_MSG: &str = "decode shape limit exceeded";

fn validate_container_len(len: usize) -> Result<()> {
    check_decode_count(len, DEFAULT_MAX_DECODE_COUNT)
}

#[derive(Default)]
struct DecodeState {
    keys: Vec<String>,
    strings: Vec<String>,
    shapes: Vec<Vec<String>>,
    depth: usize,
    max_depth: usize,
}

impl DecodeState {
    fn new() -> Self {
        Self {
            max_depth: DEFAULT_MAX_DECODE_DEPTH,
            ..Self::default()
        }
    }

    fn enter_container(&mut self) -> Result<()> {
        if self.depth >= self.max_depth {
            return Err(TwilicError::InvalidData(DECODE_DEPTH_LIMIT_MSG));
        }
        self.depth += 1;
        Ok(())
    }

    fn leave_container(&mut self) {
        self.depth = self.depth.saturating_sub(1);
    }
}

pub fn encode(value: &Value) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(256);
    let mut state = EncodeState::default();
    encode_value(value, &mut out, &mut state)?;
    Ok(out)
}

pub fn decode(bytes: &[u8]) -> Result<Value> {
    let mut reader = Reader::new(bytes);
    let mut state = DecodeState::new();
    let value = decode_value(&mut reader, &mut state)?;
    if !reader.is_eof() {
        return Err(TwilicError::InvalidData("trailing bytes in v2 decode"));
    }
    Ok(value)
}

fn encode_value(value: &Value, out: &mut Vec<u8>, state: &mut EncodeState) -> Result<()> {
    match value {
        Value::Null => out.push(NULL_TAG),
        Value::Bool(v) => out.push(if *v { TRUE_TAG } else { FALSE_TAG }),
        Value::I64(v) => encode_i64(*v, out),
        Value::U64(v) => encode_u64(*v, out),
        Value::F64(v) => {
            out.push(F64_TAG);
            out.extend_from_slice(&v.to_le_bytes());
        }
        Value::String(s) => {
            if let Some(id) = state.str_ids.get(s).copied() {
                out.push(STR_REF_TAG);
                encode_varuint(id, out);
            } else {
                encode_string_literal(s, out);
                state.str_ids.insert(s.clone(), state.next_str_id);
                state.next_str_id += 1;
            }
        }
        Value::Binary(bytes) => encode_binary(bytes, out),
        Value::Array(values) => encode_array(values, out, state)?,
        Value::Map(entries) => encode_map(entries, out, state)?,
    }
    Ok(())
}

fn encode_array(values: &[Value], out: &mut Vec<u8>, state: &mut EncodeState) -> Result<()> {
    if let Some(shape_keys) = detect_shape_keys(values) {
        let shape_id = if let Some(id) = state.shape_ids.get(&shape_keys).copied() {
            id
        } else {
            let id = state.next_shape_id;
            state.next_shape_id += 1;
            state.shape_ids.insert(shape_keys.clone(), id);
            id
        };
        write_array_header(values.len(), out);
        out.push(SHAPE_DEF_TAG);
        encode_varuint(shape_id, out);
        encode_varuint(shape_keys.len() as u64, out);
        for key in &shape_keys {
            encode_key(key, out, state);
        }
        for value in values {
            if let Value::Map(entries) = value {
                // detect_shape_keys verified exact key order, so iterate directly
                for (_, field_value) in entries {
                    encode_value(field_value, out, state)?;
                }
            }
        }
        return Ok(());
    }

    write_array_header(values.len(), out);
    for value in values {
        encode_value(value, out, state)?;
    }
    Ok(())
}

fn encode_map(
    entries: &[(String, Value)],
    out: &mut Vec<u8>,
    state: &mut EncodeState,
) -> Result<()> {
    write_map_header(entries.len(), out);
    for (key, value) in entries {
        encode_key(key, out, state);
        encode_value(value, out, state)?;
    }
    Ok(())
}

fn encode_key(key: &str, out: &mut Vec<u8>, state: &mut EncodeState) {
    if let Some(id) = state.key_ids.get(key).copied() {
        out.push(KEY_REF_TAG);
        encode_varuint(id, out);
        return;
    }
    encode_string_literal(key, out);
    state.key_ids.insert(key.to_string(), state.next_key_id);
    state.next_key_id += 1;
}

fn encode_string_literal(value: &str, out: &mut Vec<u8>) {
    let bytes = value.as_bytes();
    if bytes.len() <= 31 {
        out.push(0x80 | (bytes.len() as u8));
    } else if u8::try_from(bytes.len()).is_ok() {
        out.push(STR8_TAG);
        out.push(bytes.len() as u8);
    } else if u16::try_from(bytes.len()).is_ok() {
        out.push(STR16_TAG);
        out.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
    } else {
        out.push(STR32_TAG);
        out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    }
    out.extend_from_slice(bytes);
}

fn encode_binary(value: &[u8], out: &mut Vec<u8>) {
    if u8::try_from(value.len()).is_ok() {
        out.push(BIN8_TAG);
        out.push(value.len() as u8);
    } else if u16::try_from(value.len()).is_ok() {
        out.push(BIN16_TAG);
        out.extend_from_slice(&(value.len() as u16).to_le_bytes());
    } else {
        out.push(BIN32_TAG);
        out.extend_from_slice(&(value.len() as u32).to_le_bytes());
    }
    out.extend_from_slice(value);
}

fn encode_u64(value: u64, out: &mut Vec<u8>) {
    if value <= 127 {
        out.push(value as u8);
    } else if u8::try_from(value).is_ok() {
        out.push(U8_TAG);
        out.push(value as u8);
    } else if u16::try_from(value).is_ok() {
        out.push(U16_TAG);
        out.extend_from_slice(&(value as u16).to_le_bytes());
    } else if u32::try_from(value).is_ok() {
        out.push(U32_TAG);
        out.extend_from_slice(&(value as u32).to_le_bytes());
    } else {
        out.push(U64_TAG);
        out.extend_from_slice(&value.to_le_bytes());
    }
}

fn encode_i64(value: i64, out: &mut Vec<u8>) {
    if (-32..=-1).contains(&value) {
        out.push((value as i8) as u8);
    } else if (0..=127).contains(&value) {
        out.push(value as u8);
    } else if i8::try_from(value).is_ok() {
        out.push(I8_TAG);
        out.push((value as i8) as u8);
    } else if i16::try_from(value).is_ok() {
        out.push(I16_TAG);
        out.extend_from_slice(&(value as i16).to_le_bytes());
    } else if i32::try_from(value).is_ok() {
        out.push(I32_TAG);
        out.extend_from_slice(&(value as i32).to_le_bytes());
    } else {
        out.push(I64_TAG);
        out.extend_from_slice(&value.to_le_bytes());
    }
}

fn write_array_header(len: usize, out: &mut Vec<u8>) {
    if len <= 15 {
        out.push(0xA0 | (len as u8));
    } else if u16::try_from(len).is_ok() {
        out.push(ARRAY16_TAG);
        out.extend_from_slice(&(len as u16).to_le_bytes());
    } else {
        out.push(ARRAY32_TAG);
        out.extend_from_slice(&(len as u32).to_le_bytes());
    }
}

fn write_map_header(len: usize, out: &mut Vec<u8>) {
    if len <= 15 {
        out.push(0xB0 | (len as u8));
    } else if u16::try_from(len).is_ok() {
        out.push(MAP16_TAG);
        out.extend_from_slice(&(len as u16).to_le_bytes());
    } else {
        out.push(MAP32_TAG);
        out.extend_from_slice(&(len as u32).to_le_bytes());
    }
}

fn detect_shape_keys(values: &[Value]) -> Option<Vec<String>> {
    if values.len() < 2 {
        return None;
    }
    let Value::Map(first) = values.first()? else {
        return None;
    };
    let keys: Vec<String> = first.iter().map(|(k, _)| k.clone()).collect();
    if keys.is_empty() {
        return None;
    }
    for value in values.iter().skip(1) {
        let Value::Map(entries) = value else {
            return None;
        };
        if entries.len() != keys.len() {
            return None;
        }
        for ((lhs, _), rhs) in entries.iter().zip(keys.iter()) {
            if lhs != rhs {
                return None;
            }
        }
    }
    Some(keys)
}

fn decode_value(reader: &mut Reader<'_>, state: &mut DecodeState) -> Result<Value> {
    let tag = reader.read_u8()?;
    decode_value_from_tag(reader, state, tag)
}

fn decode_value_from_tag(
    reader: &mut Reader<'_>,
    state: &mut DecodeState,
    tag: u8,
) -> Result<Value> {
    match tag {
        0x00..=0x7F => Ok(Value::U64(tag as u64)),
        0x80..=0x9F => {
            let len = (tag & 0x1F) as usize;
            let bytes = reader.read_exact(len)?;
            let s = std::str::from_utf8(bytes)
                .map_err(|_| TwilicError::Utf8Error)?
                .to_string();
            state.strings.push(s.clone());
            Ok(Value::String(s))
        }
        0xA0..=0xAF => {
            let len = (tag & 0x0F) as usize;
            decode_array_body(reader, state, len)
        }
        0xB0..=0xBF => {
            let len = (tag & 0x0F) as usize;
            decode_map_body(reader, state, len)
        }
        0xE0..=0xFF => Ok(Value::I64((tag as i8) as i64)),
        NULL_TAG => Ok(Value::Null),
        FALSE_TAG => Ok(Value::Bool(false)),
        TRUE_TAG => Ok(Value::Bool(true)),
        F64_TAG => {
            let mut bytes = [0u8; 8];
            bytes.copy_from_slice(reader.read_exact(8)?);
            Ok(Value::F64(f64::from_le_bytes(bytes)))
        }
        U8_TAG => {
            let value = reader.read_u8()? as u64;
            ensure_canonical_u64(value, 1)?;
            Ok(Value::U64(value))
        }
        U16_TAG => {
            let mut bytes = [0u8; 2];
            bytes.copy_from_slice(reader.read_exact(2)?);
            let value = u16::from_le_bytes(bytes) as u64;
            ensure_canonical_u64(value, 2)?;
            Ok(Value::U64(value))
        }
        U32_TAG => {
            let mut bytes = [0u8; 4];
            bytes.copy_from_slice(reader.read_exact(4)?);
            let value = u32::from_le_bytes(bytes) as u64;
            ensure_canonical_u64(value, 4)?;
            Ok(Value::U64(value))
        }
        U64_TAG => {
            let mut bytes = [0u8; 8];
            bytes.copy_from_slice(reader.read_exact(8)?);
            let value = u64::from_le_bytes(bytes);
            ensure_canonical_u64(value, 8)?;
            Ok(Value::U64(value))
        }
        I8_TAG => {
            let value = (reader.read_u8()? as i8) as i64;
            ensure_canonical_i64(value, 1)?;
            Ok(Value::I64(value))
        }
        I16_TAG => {
            let mut bytes = [0u8; 2];
            bytes.copy_from_slice(reader.read_exact(2)?);
            let value = i16::from_le_bytes(bytes) as i64;
            ensure_canonical_i64(value, 2)?;
            Ok(Value::I64(value))
        }
        I32_TAG => {
            let mut bytes = [0u8; 4];
            bytes.copy_from_slice(reader.read_exact(4)?);
            let value = i32::from_le_bytes(bytes) as i64;
            ensure_canonical_i64(value, 4)?;
            Ok(Value::I64(value))
        }
        I64_TAG => {
            let mut bytes = [0u8; 8];
            bytes.copy_from_slice(reader.read_exact(8)?);
            let value = i64::from_le_bytes(bytes);
            ensure_canonical_i64(value, 8)?;
            Ok(Value::I64(value))
        }
        BIN8_TAG => {
            let len = reader.read_u8()? as usize;
            check_byte_len(len, reader.remaining())?;
            Ok(Value::Binary(reader.read_exact(len)?.to_vec()))
        }
        BIN16_TAG => {
            let mut len = [0u8; 2];
            len.copy_from_slice(reader.read_exact(2)?);
            let len = u16::from_le_bytes(len) as usize;
            check_byte_len(len, reader.remaining())?;
            Ok(Value::Binary(reader.read_exact(len)?.to_vec()))
        }
        BIN32_TAG => {
            let mut len = [0u8; 4];
            len.copy_from_slice(reader.read_exact(4)?);
            let len = u32::from_le_bytes(len) as usize;
            check_byte_len(len, reader.remaining())?;
            Ok(Value::Binary(reader.read_exact(len)?.to_vec()))
        }
        STR8_TAG | STR16_TAG | STR32_TAG => decode_string_tag(reader, state, tag),
        ARRAY16_TAG => {
            let mut len = [0u8; 2];
            len.copy_from_slice(reader.read_exact(2)?);
            let len = u16::from_le_bytes(len) as usize;
            validate_container_len(len)?;
            decode_array_body(reader, state, len)
        }
        ARRAY32_TAG => {
            let mut len = [0u8; 4];
            len.copy_from_slice(reader.read_exact(4)?);
            let len = u32::from_le_bytes(len) as usize;
            validate_container_len(len)?;
            decode_array_body(reader, state, len)
        }
        MAP16_TAG => {
            let mut len = [0u8; 2];
            len.copy_from_slice(reader.read_exact(2)?);
            let len = u16::from_le_bytes(len) as usize;
            validate_container_len(len)?;
            decode_map_body(reader, state, len)
        }
        MAP32_TAG => {
            let mut len = [0u8; 4];
            len.copy_from_slice(reader.read_exact(4)?);
            let len = u32::from_le_bytes(len) as usize;
            validate_container_len(len)?;
            decode_map_body(reader, state, len)
        }
        STR_REF_TAG => {
            let id = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
            let Some(value) = state.strings.get(id) else {
                return Err(TwilicError::InvalidData("unknown str_ref id"));
            };
            reader.claim_output(value.len(), 1)?;
            Ok(Value::String(value.clone()))
        }
        // fixmap: 0xb0..=0xbf encodes a map with (tag & 0x0f) entries
        tag if (0xb0..=0xbf).contains(&tag) => {
            decode_map_body(reader, state, (tag & 0x0f) as usize)
        }
        _ => Err(TwilicError::InvalidTag(tag)),
    }
}

fn ensure_canonical_u64(value: u64, width: u8) -> Result<()> {
    let canonical_width = if value <= 127 {
        0
    } else if u8::try_from(value).is_ok() {
        1
    } else if u16::try_from(value).is_ok() {
        2
    } else if u32::try_from(value).is_ok() {
        4
    } else {
        8
    };
    if canonical_width == width {
        Ok(())
    } else {
        Err(TwilicError::InvalidData("non-canonical integer encoding"))
    }
}

fn ensure_canonical_i64(value: i64, width: u8) -> Result<()> {
    let canonical_width = if (-32..=127).contains(&value) {
        0
    } else if i8::try_from(value).is_ok() {
        1
    } else if i16::try_from(value).is_ok() {
        2
    } else if i32::try_from(value).is_ok() {
        4
    } else {
        8
    };
    if canonical_width == width {
        Ok(())
    } else {
        Err(TwilicError::InvalidData("non-canonical integer encoding"))
    }
}

fn decode_string_tag(reader: &mut Reader<'_>, state: &mut DecodeState, tag: u8) -> Result<Value> {
    let len = match tag {
        STR8_TAG => reader.read_u8()? as usize,
        STR16_TAG => {
            let mut len = [0u8; 2];
            len.copy_from_slice(reader.read_exact(2)?);
            u16::from_le_bytes(len) as usize
        }
        STR32_TAG => {
            let mut len = [0u8; 4];
            len.copy_from_slice(reader.read_exact(4)?);
            u32::from_le_bytes(len) as usize
        }
        _ => unreachable!(),
    };
    check_byte_len(len, reader.remaining())?;
    let bytes = reader.read_exact(len)?;
    let s = std::str::from_utf8(bytes)
        .map_err(|_| TwilicError::Utf8Error)?
        .to_string();
    state.strings.push(s.clone());
    Ok(Value::String(s))
}

fn decode_array_body(
    reader: &mut Reader<'_>,
    state: &mut DecodeState,
    len: usize,
) -> Result<Value> {
    state.enter_container()?;
    let decoded = decode_array_body_inner(reader, state, len);
    state.leave_container();
    decoded
}

fn decode_array_body_inner(
    reader: &mut Reader<'_>,
    state: &mut DecodeState,
    len: usize,
) -> Result<Value> {
    validate_container_len(len)?;
    reader.claim_output(len, 8)?;
    let mut values = Vec::with_capacity(len);
    if len == 0 {
        return Ok(Value::Array(values));
    }
    let first_tag = reader.read_u8()?;
    if first_tag == SHAPE_DEF_TAG {
        let shape_id = reader.read_bounded_count(65_535)?;
        let key_count = reader.read_bounded_count(256)?;
        reader.claim_output(key_count, 8)?;
        let mut keys = Vec::with_capacity(key_count);
        for _ in 0..key_count {
            keys.push(decode_key(reader, state)?);
        }
        if shape_id >= DEFAULT_MAX_DECODE_COUNT {
            return Err(TwilicError::InvalidData(DECODE_SHAPE_LIMIT_MSG));
        }
        if shape_id >= state.shapes.len() {
            reader.claim_output(shape_id + 1 - state.shapes.len(), 8)?;
            state.shapes.resize(shape_id + 1, Vec::new());
        }
        state.shapes[shape_id] = keys.clone();
        for _ in 0..len {
            reader.claim_output(keys.len(), 8)?;
            let mut row = Vec::with_capacity(keys.len());
            for key in &keys {
                reader.claim_output(key.len(), 1)?;
                row.push((key.clone(), decode_value(reader, state)?));
            }
            values.push(Value::Map(row));
        }
        return Ok(Value::Array(values));
    }
    values.push(decode_value_from_tag(reader, state, first_tag)?);
    for _ in 1..len {
        values.push(decode_value(reader, state)?);
    }
    Ok(Value::Array(values))
}

fn decode_map_body(reader: &mut Reader<'_>, state: &mut DecodeState, len: usize) -> Result<Value> {
    validate_container_len(len)?;
    reader.claim_output(len, 8)?;
    state.enter_container()?;
    let mut entries = Vec::with_capacity(len);
    let decoded = (|| {
        for _ in 0..len {
            let key = decode_key(reader, state)?;
            let value = decode_value(reader, state)?;
            entries.push((key, value));
        }
        Ok(Value::Map(entries))
    })();
    state.leave_container();
    decoded
}

fn decode_key(reader: &mut Reader<'_>, state: &mut DecodeState) -> Result<String> {
    let tag = reader.read_u8()?;
    if tag == KEY_REF_TAG {
        let id = reader.read_bounded_count(DEFAULT_MAX_DECODE_COUNT)?;
        let Some(value) = state.keys.get(id).cloned() else {
            return Err(TwilicError::InvalidData("unknown key_ref id"));
        };
        return Ok(value);
    }
    if (0x80..=0x9F).contains(&tag) {
        let len = (tag & 0x1F) as usize;
        let bytes = reader.read_exact(len)?;
        let key = std::str::from_utf8(bytes)
            .map_err(|_| TwilicError::Utf8Error)?
            .to_string();
        state.keys.push(key.clone());
        return Ok(key);
    }
    if matches!(tag, STR8_TAG | STR16_TAG | STR32_TAG) {
        let Value::String(key) = decode_value_from_tag(reader, state, tag)? else {
            return Err(TwilicError::InvalidData("expected string key"));
        };
        state.keys.push(key.clone());
        return Ok(key);
    }
    Err(TwilicError::InvalidData(
        "map key must be key_ref or string",
    ))
}
