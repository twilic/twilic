"""V2 wire profile encoding and decoding."""

from __future__ import annotations

import struct

from .errors import invalid_data, invalid_tag
from .model import (
    MapEntry,
    Value,
    ValueKind,
    entry,
    new_array,
    new_binary,
    new_bool,
    new_f64,
    new_i64,
    new_map,
    new_null,
    new_string,
    new_u64,
)
from .session import shape_key
from .wire import (
    Reader,
    append_f64_le,
    append_u64_le,
    bounded_decode,
    encode_varuint,
    new_reader,
    read_f64_le,
    read_u64_le,
)

NULL_TAG = 0xC0
FALSE_TAG = 0xC1
TRUE_TAG = 0xC2
F64_TAG = 0xC3
U8_TAG = 0xC4
U16_TAG = 0xC5
U32_TAG = 0xC6
U64_TAG = 0xC7
I8_TAG = 0xC8
I16_TAG = 0xC9
I32_TAG = 0xCA
I64_TAG = 0xCB
BIN8_TAG = 0xCC
BIN16_TAG = 0xCD
BIN32_TAG = 0xCE
STR8_TAG = 0xCF
STR16_TAG = 0xD0
STR32_TAG = 0xD1
ARRAY16_TAG = 0xD2
ARRAY32_TAG = 0xD3
MAP16_TAG = 0xD4
MAP32_TAG = 0xD5
SHAPE_DEF_TAG = 0xD6
KEY_REF_TAG = 0xD8
STR_REF_TAG = 0xD9


class _V2EncodeState:
    __slots__ = ("key_ids", "str_ids", "shape_ids", "next_key_id", "next_str_id", "next_shape_id")

    def __init__(self) -> None:
        self.key_ids: dict[str, int] = {}
        self.str_ids: dict[str, int] = {}
        self.shape_ids: dict[str, int] = {}
        self.next_key_id = 0
        self.next_str_id = 0
        self.next_shape_id = 0


class _V2DecodeState:
    __slots__ = ("keys", "strings", "shapes")

    def __init__(self) -> None:
        self.keys: list[str] = []
        self.strings: list[str] = []
        self.shapes: list[list[str] | None] = []


def encode_v2(value: Value) -> bytes:
    out = bytearray()
    state = _V2EncodeState()
    encode_v2_value(value, out, state)
    return bytes(out)


def decode_v2(data: bytes) -> Value:
    reader = new_reader(data)
    state = _V2DecodeState()
    value = decode_v2_value(reader, state)
    if not reader.is_eof():
        raise invalid_data("trailing bytes in v2 decode")
    return value


def encode_v2_value(value: Value, out: bytearray, state: _V2EncodeState) -> None:
    match value.kind:
        case ValueKind.NULL:
            out.append(NULL_TAG)
        case ValueKind.BOOL:
            out.append(TRUE_TAG if value.bool else FALSE_TAG)
        case ValueKind.I64:
            encode_v2_i64(value.i64, out)
        case ValueKind.U64:
            encode_v2_u64(value.u64, out)
        case ValueKind.F64:
            out.append(F64_TAG)
            append_f64_le(out, value.f64)
        case ValueKind.STRING:
            ref_id = state.str_ids.get(value.str)
            if ref_id is not None:
                out.append(STR_REF_TAG)
                encode_varuint(ref_id, out)
            else:
                encode_v2_string_literal(value.str, out)
                state.str_ids[value.str] = state.next_str_id
                state.next_str_id += 1
        case ValueKind.BINARY:
            encode_v2_binary(value.bin, out)
        case ValueKind.ARRAY:
            encode_v2_array(value.arr, out, state)
        case ValueKind.MAP:
            encode_v2_map(value.map, out, state)
        case _:
            raise invalid_data("unsupported value kind")


def encode_v2_array(values: list[Value], out: bytearray, state: _V2EncodeState) -> None:
    shape_keys = detect_shape_keys(values)
    if shape_keys is not None:
        sk = shape_key(shape_keys)
        shape_id = state.shape_ids.get(sk)
        if shape_id is None:
            shape_id = state.next_shape_id
            state.next_shape_id += 1
            state.shape_ids[sk] = shape_id
        write_v2_array_header(len(values), out)
        out.append(SHAPE_DEF_TAG)
        encode_varuint(shape_id, out)
        encode_varuint(len(shape_keys), out)
        for key in shape_keys:
            encode_v2_key(key, out, state)
        for value in values:
            if value.kind != ValueKind.MAP:
                raise invalid_data("shape array row must be map")
            for field in value.map:
                encode_v2_value(field.value, out, state)
        return
    write_v2_array_header(len(values), out)
    for value in values:
        encode_v2_value(value, out, state)


def encode_v2_map(entries: list[MapEntry], out: bytearray, state: _V2EncodeState) -> None:
    write_v2_map_header(len(entries), out)
    for entry_ in entries:
        encode_v2_key(entry_.key, out, state)
        encode_v2_value(entry_.value, out, state)


def encode_v2_key(key: str, out: bytearray, state: _V2EncodeState) -> None:
    ref_id = state.key_ids.get(key)
    if ref_id is not None:
        out.append(KEY_REF_TAG)
        encode_varuint(ref_id, out)
        return
    encode_v2_string_literal(key, out)
    state.key_ids[key] = state.next_key_id
    state.next_key_id += 1


def encode_v2_string_literal(value: str, out: bytearray) -> None:
    raw = value.encode("utf-8")
    length = len(raw)
    if length <= 31:
        out.append(0x80 | length)
    elif length <= 0xFF:
        out.extend([STR8_TAG, length])
    elif length <= 0xFFFF:
        out.extend([STR16_TAG, length & 0xFF, (length >> 8) & 0xFF])
    else:
        out.append(STR32_TAG)
        out.extend(
            [
                length & 0xFF,
                (length >> 8) & 0xFF,
                (length >> 16) & 0xFF,
                (length >> 24) & 0xFF,
            ]
        )
    out.extend(raw)


def encode_v2_binary(value: bytes, out: bytearray) -> None:
    length = len(value)
    if length <= 0xFF:
        out.extend([BIN8_TAG, length])
    elif length <= 0xFFFF:
        out.extend([BIN16_TAG, length & 0xFF, (length >> 8) & 0xFF])
    else:
        out.append(BIN32_TAG)
        out.extend(
            [
                length & 0xFF,
                (length >> 8) & 0xFF,
                (length >> 16) & 0xFF,
                (length >> 24) & 0xFF,
            ]
        )
    out.extend(value)


def encode_v2_u64(value: int, out: bytearray) -> None:
    if value <= 127:
        out.append(value)
    elif value <= 0xFF:
        out.extend([U8_TAG, value])
    elif value <= 0xFFFF:
        out.extend([U16_TAG, value & 0xFF, (value >> 8) & 0xFF])
    elif value <= 0xFFFFFFFF:
        out.extend(
            [
                U32_TAG,
                value & 0xFF,
                (value >> 8) & 0xFF,
                (value >> 16) & 0xFF,
                (value >> 24) & 0xFF,
            ]
        )
    else:
        out.append(U64_TAG)
        append_u64_le(out, value)


def encode_v2_i64(value: int, out: bytearray) -> None:
    if -32 <= value <= -1:
        out.append(value & 0xFF)
    elif 0 <= value <= 127:
        out.append(value)
    elif -128 <= value <= 127:
        out.extend([I8_TAG, value & 0xFF])
    elif -32768 <= value <= 32767:
        out.extend([I16_TAG, value & 0xFF, (value >> 8) & 0xFF])
    elif -2147483648 <= value <= 2147483647:
        out.extend(
            [
                I32_TAG,
                value & 0xFF,
                (value >> 8) & 0xFF,
                (value >> 16) & 0xFF,
                (value >> 24) & 0xFF,
            ]
        )
    else:
        out.append(I64_TAG)
        append_u64_le(out, value & 0xFFFFFFFFFFFFFFFF)


def write_v2_array_header(length: int, out: bytearray) -> None:
    if length <= 15:
        out.append(0xA0 | length)
    elif length <= 0xFFFF:
        out.extend([ARRAY16_TAG, length & 0xFF, (length >> 8) & 0xFF])
    else:
        out.append(ARRAY32_TAG)
        out.extend(
            [
                length & 0xFF,
                (length >> 8) & 0xFF,
                (length >> 16) & 0xFF,
                (length >> 24) & 0xFF,
            ]
        )


def write_v2_map_header(length: int, out: bytearray) -> None:
    if length <= 15:
        out.append(0xB0 | length)
    elif length <= 0xFFFF:
        out.extend([MAP16_TAG, length & 0xFF, (length >> 8) & 0xFF])
    else:
        out.append(MAP32_TAG)
        out.extend(
            [
                length & 0xFF,
                (length >> 8) & 0xFF,
                (length >> 16) & 0xFF,
                (length >> 24) & 0xFF,
            ]
        )


def detect_shape_keys(values: list[Value]) -> list[str] | None:
    if len(values) < 2:
        return None
    if values[0].kind != ValueKind.MAP or not values[0].map:
        return None
    keys = [e.key for e in values[0].map]
    for value in values[1:]:
        if value.kind != ValueKind.MAP or len(value.map) != len(keys):
            return None
        for i, e in enumerate(value.map):
            if e.key != keys[i]:
                return None
    return keys


def decode_v2_value(reader: Reader, state: _V2DecodeState) -> Value:
    tag = reader.read_u8()
    return decode_v2_value_from_tag(reader, state, tag)


def decode_v2_value_from_tag(reader: Reader, state: _V2DecodeState, tag: int) -> Value:
    if tag <= 0x7F:
        return new_u64(tag)
    if 0x80 <= tag <= 0x9F:
        length = tag & 0x1F
        raw = reader.read_exact(length)
        s = raw.decode("utf-8")
        state.strings.append(s)
        return new_string(s)
    if 0xA0 <= tag <= 0xAF:
        return decode_v2_array_body(reader, state, tag & 0x0F)
    if 0xB0 <= tag <= 0xBF:
        return decode_v2_map_body(reader, state, tag & 0x0F)
    if tag >= 0xE0:
        return new_i64(tag if tag < 128 else tag - 256)
    if tag == NULL_TAG:
        return new_null()
    if tag == FALSE_TAG:
        return new_bool(False)
    if tag == TRUE_TAG:
        return new_bool(True)
    if tag == F64_TAG:
        return new_f64(read_f64_le(reader))
    if tag == U8_TAG:
        return new_u64(reader.read_u8())
    if tag == U16_TAG:
        b = reader.read_exact(2)
        return new_u64(b[0] | (b[1] << 8))
    if tag == U32_TAG:
        b = reader.read_exact(4)
        return new_u64(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24))
    if tag == U64_TAG:
        return new_u64(read_u64_le(reader))
    if tag == I8_TAG:
        b = reader.read_u8()
        return new_i64(b if b < 128 else b - 256)
    if tag == I16_TAG:
        b = reader.read_exact(2)
        return new_i64(struct.unpack("<h", b)[0])
    if tag == I32_TAG:
        b = reader.read_exact(4)
        return new_i64(struct.unpack("<i", b)[0])
    if tag == I64_TAG:
        b = reader.read_exact(8)
        return new_i64(struct.unpack("<q", b)[0])
    if tag == BIN8_TAG:
        n = reader.read_u8()
        return new_binary(reader.read_exact(n))
    if tag == BIN16_TAG:
        b = reader.read_exact(2)
        n = b[0] | (b[1] << 8)
        return new_binary(reader.read_exact(n))
    if tag == BIN32_TAG:
        b = reader.read_exact(4)
        n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
        return new_binary(reader.read_exact(n))
    if tag in (STR8_TAG, STR16_TAG, STR32_TAG):
        return decode_v2_string_tag(reader, state, tag)
    if tag == ARRAY16_TAG:
        b = reader.read_exact(2)
        n = b[0] | (b[1] << 8)
        return decode_v2_array_body(reader, state, n)
    if tag == ARRAY32_TAG:
        b = reader.read_exact(4)
        n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
        return decode_v2_array_body(reader, state, n)
    if tag == MAP16_TAG:
        b = reader.read_exact(2)
        n = b[0] | (b[1] << 8)
        return decode_v2_map_body(reader, state, n)
    if tag == MAP32_TAG:
        b = reader.read_exact(4)
        n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
        return decode_v2_map_body(reader, state, n)
    if tag == STR_REF_TAG:
        ref_id = reader.read_varuint()
        if ref_id >= len(state.strings):
            raise invalid_data("unknown str_ref id")
        return new_string(state.strings[ref_id])
    raise invalid_tag(tag)


def decode_v2_string_tag(reader: Reader, state: _V2DecodeState, tag: int) -> Value:
    if tag == STR8_TAG:
        length = reader.read_u8()
    elif tag == STR16_TAG:
        b = reader.read_exact(2)
        length = b[0] | (b[1] << 8)
    elif tag == STR32_TAG:
        b = reader.read_exact(4)
        length = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
    else:
        raise invalid_data("invalid string tag")
    raw = reader.read_exact(length)
    s = raw.decode("utf-8")
    state.strings.append(s)
    return new_string(s)


@bounded_decode
def decode_v2_array_body(reader: Reader, state: _V2DecodeState, length: int) -> Value:
    reader.claim_output(length)
    if length == 0:
        return new_array([])
    first_tag = reader.read_u8()
    if first_tag == SHAPE_DEF_TAG:
        shape_id = reader.read_count(65_535)
        key_count = reader.read_count(256)
        keys: list[str] = []
        for _ in range(key_count):
            keys.append(decode_v2_key(reader, state))
        while shape_id >= len(state.shapes):
            state.shapes.append(None)
        state.shapes[shape_id] = keys
        values: list[Value] = []
        for _ in range(length):
            reader.claim_output(key_count)
            row = [entry(key, decode_v2_value(reader, state)) for key in keys]
            values.append(new_map(*row))
        return new_array(values)
    values = [None] * length  # type: ignore[list-item]
    values[0] = decode_v2_value_from_tag(reader, state, first_tag)
    for i in range(1, length):
        values[i] = decode_v2_value(reader, state)
    return new_array(values)  # type: ignore[arg-type]


@bounded_decode
def decode_v2_map_body(reader: Reader, state: _V2DecodeState, length: int) -> Value:
    reader.claim_output(length)
    entries: list[MapEntry] = []
    for _ in range(length):
        key = decode_v2_key(reader, state)
        value = decode_v2_value(reader, state)
        entries.append(entry(key, value))
    return new_map(*entries)


def decode_v2_key(reader: Reader, state: _V2DecodeState) -> str:
    tag = reader.read_u8()
    if tag == KEY_REF_TAG:
        ref_id = reader.read_varuint()
        if ref_id >= len(state.keys):
            raise invalid_data("unknown key_ref id")
        return state.keys[ref_id]
    if 0x80 <= tag <= 0x9F:
        length = tag & 0x1F
        key = reader.read_exact(length).decode("utf-8")
        state.keys.append(key)
        return key
    if tag in (STR8_TAG, STR16_TAG, STR32_TAG):
        v = decode_v2_value_from_tag(reader, state, tag)
        if v.kind != ValueKind.STRING:
            raise invalid_data("expected string key")
        state.keys.append(v.str)
        return v.str
    raise invalid_data("map key must be key_ref or string")
