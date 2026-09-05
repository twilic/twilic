"""Vector and numeric codec implementations."""

from __future__ import annotations

import struct

from .errors import invalid_data
from .model import VectorCodec
from .wire import (
    Reader,
    append_f64_le,
    append_u64_le,
    decode_zigzag,
    encode_varuint,
    encode_zigzag,
    read_f64_le,
    read_u64_le,
)

SIMPLE8B_SLOTS: list[tuple[int, int]] = [
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
]


def encode_i64_vector(values: list[int], codec: VectorCodec, out: bytearray) -> None:
    match codec:
        case VectorCodec.RLE:
            encode_i64_rle(values, out)
        case VectorCodec.DIRECT_BITPACK:
            encode_i64_direct_bitpack(values, out)
        case VectorCodec.DELTA_BITPACK:
            encode_i64_direct_bitpack(delta(values), out)
        case VectorCodec.FOR_BITPACK:
            if not values:
                encode_varuint(0, out)
                return
            min_value = min(values)
            encode_varuint(encode_zigzag(min_value), out)
            shifted = [v - min_value for v in values]
            encode_i64_direct_bitpack(shifted, out)
        case VectorCodec.DELTA_FOR_BITPACK:
            deltas = delta(values)
            if not deltas:
                encode_varuint(0, out)
                return
            min_value = min(deltas)
            encode_varuint(encode_zigzag(min_value), out)
            shifted = [v - min_value for v in deltas]
            encode_i64_direct_bitpack(shifted, out)
        case VectorCodec.DELTA_DELTA_BITPACK:
            encode_i64_delta_delta(values, out)
        case VectorCodec.PATCHED_FOR:
            encode_i64_patched_for(values, out)
        case VectorCodec.SIMPLE8B:
            encode_i64_simple8b(values, out)
        case (
            VectorCodec.PLAIN
            | VectorCodec.DICTIONARY
            | VectorCodec.STRING_REF
            | VectorCodec.PREFIX_DELTA
            | VectorCodec.XOR_FLOAT
        ):
            encode_i64_plain(values, out)


def decode_i64_vector(reader: Reader, codec: VectorCodec) -> list[int]:
    match codec:
        case VectorCodec.RLE:
            return decode_i64_rle(reader)
        case VectorCodec.DIRECT_BITPACK:
            return decode_i64_direct_bitpack(reader)
        case VectorCodec.DELTA_BITPACK:
            values = decode_i64_direct_bitpack(reader)
            return undelta(values)
        case VectorCodec.FOR_BITPACK:
            encoded_min = reader.read_varuint()
            min_value = decode_zigzag(encoded_min)
            if reader.is_eof():
                return []
            shifted = decode_i64_direct_bitpack(reader)
            return [v + min_value for v in shifted]
        case VectorCodec.DELTA_FOR_BITPACK:
            encoded_min = reader.read_varuint()
            min_value = decode_zigzag(encoded_min)
            if reader.is_eof():
                return []
            shifted = decode_i64_direct_bitpack(reader)
            deltas = [v + min_value for v in shifted]
            return undelta(deltas)
        case VectorCodec.DELTA_DELTA_BITPACK:
            return decode_i64_delta_delta(reader)
        case VectorCodec.PATCHED_FOR:
            return decode_i64_patched_for(reader)
        case VectorCodec.SIMPLE8B:
            return decode_i64_simple8b(reader)
        case (
            VectorCodec.PLAIN
            | VectorCodec.DICTIONARY
            | VectorCodec.STRING_REF
            | VectorCodec.PREFIX_DELTA
            | VectorCodec.XOR_FLOAT
        ):
            return decode_i64_plain(reader)
        case _:
            raise invalid_data("unsupported vector codec")


def encode_u64_vector(values: list[int], codec: VectorCodec, out: bytearray) -> None:
    match codec:
        case VectorCodec.RLE:
            encode_u64_rle(values, out)
        case VectorCodec.DIRECT_BITPACK:
            encode_u64_direct_bitpack(values, out)
        case VectorCodec.FOR_BITPACK:
            if not values:
                encode_varuint(0, out)
                return
            min_value = min(values)
            encode_varuint(min_value, out)
            shifted = [v - min_value for v in values]
            encode_u64_direct_bitpack(shifted, out)
        case VectorCodec.PLAIN:
            encode_u64_plain(values, out)
        case VectorCodec.SIMPLE8B:
            encode_u64_simple8b(values, out)
        case (
            VectorCodec.DICTIONARY
            | VectorCodec.STRING_REF
            | VectorCodec.PREFIX_DELTA
            | VectorCodec.XOR_FLOAT
            | VectorCodec.DELTA_BITPACK
            | VectorCodec.DELTA_FOR_BITPACK
            | VectorCodec.DELTA_DELTA_BITPACK
            | VectorCodec.PATCHED_FOR
        ):
            encode_u64_plain(values, out)


def decode_u64_vector(reader: Reader, codec: VectorCodec) -> list[int]:
    match codec:
        case VectorCodec.RLE:
            return decode_u64_rle(reader)
        case VectorCodec.DIRECT_BITPACK:
            return decode_u64_direct_bitpack(reader)
        case VectorCodec.FOR_BITPACK:
            min_value = reader.read_varuint()
            if reader.is_eof():
                return []
            shifted = decode_u64_direct_bitpack(reader)
            out: list[int] = []
            for v in shifted:
                total, ok = checked_add_u64(v, min_value)
                if not ok:
                    raise invalid_data("u64 FOR overflow")
                out.append(total)
            return out
        case VectorCodec.PLAIN:
            return decode_u64_plain(reader)
        case VectorCodec.SIMPLE8B:
            return decode_u64_simple8b(reader)
        case (
            VectorCodec.DICTIONARY
            | VectorCodec.STRING_REF
            | VectorCodec.PREFIX_DELTA
            | VectorCodec.XOR_FLOAT
            | VectorCodec.DELTA_BITPACK
            | VectorCodec.DELTA_FOR_BITPACK
            | VectorCodec.DELTA_DELTA_BITPACK
            | VectorCodec.PATCHED_FOR
        ):
            return decode_u64_plain(reader)
        case _:
            raise invalid_data("unsupported vector codec")


def encode_f64_vector(values: list[float], codec: VectorCodec, out: bytearray) -> None:
    if codec == VectorCodec.XOR_FLOAT:
        encode_xor_float(values, out)
        return
    encode_varuint(len(values), out)
    for v in values:
        append_f64_le(out, v)


def decode_f64_vector(reader: Reader, codec: VectorCodec) -> list[float]:
    if codec == VectorCodec.XOR_FLOAT:
        return decode_xor_float(reader)
    length = reader.read_count()
    out: list[float] = []
    for _ in range(length):
        out.append(read_f64_le(reader))
    return out


def encode_u64_plain(values: list[int], out: bytearray) -> None:
    encode_varuint(len(values), out)
    for value in values:
        encode_varuint(value, out)


def decode_u64_plain(reader: Reader) -> list[int]:
    length = reader.read_count()
    return [reader.read_varuint() for _ in range(length)]


def encode_u64_rle(values: list[int], out: bytearray) -> None:
    runs: list[tuple[int, int]] = []
    for value in values:
        if runs and runs[-1][0] == value:
            runs[-1] = (value, runs[-1][1] + 1)
        else:
            runs.append((value, 1))
    encode_varuint(len(runs), out)
    for val, count in runs:
        encode_varuint(val, out)
        encode_varuint(count, out)


def decode_u64_rle(reader: Reader) -> list[int]:
    runs_len = reader.read_count()
    out: list[int] = []
    for _ in range(runs_len):
        value = reader.read_varuint()
        count = reader.read_count()
        out.extend([value] * count)
    return out


def encode_u64_direct_bitpack(values: list[int], out: bytearray) -> None:
    encode_varuint(len(values), out)
    if not values:
        out.append(0)
        return
    width = 1
    for v in values:
        bw = bit_width(v)
        if bw > width:
            width = bw
    out.append(width)
    pack_u64_values(values, width, out)


def decode_u64_direct_bitpack(reader: Reader) -> list[int]:
    length = reader.read_count()
    width = reader.read_u8()
    if length == 0:
        return []
    if width == 0 or width > 64:
        raise invalid_data("bitpack width")
    return unpack_u64_values(reader, length, width)


def encode_i64_plain(values: list[int], out: bytearray) -> None:
    encode_varuint(len(values), out)
    for value in values:
        encode_varuint(encode_zigzag(value), out)


def decode_i64_plain(reader: Reader) -> list[int]:
    length = reader.read_count()
    return [decode_zigzag(reader.read_varuint()) for _ in range(length)]


def encode_i64_simple8b(values: list[int], out: bytearray) -> None:
    encoded = [encode_zigzag(v) for v in values]
    encode_u64_simple8b_inner(encoded, out)


def decode_i64_simple8b(reader: Reader) -> list[int]:
    encoded = decode_u64_simple8b_inner(reader)
    return [decode_zigzag(v) for v in encoded]


def encode_u64_simple8b(values: list[int], out: bytearray) -> None:
    encode_u64_simple8b_inner(values, out)


def decode_u64_simple8b(reader: Reader) -> list[int]:
    return decode_u64_simple8b_inner(reader)


def encode_u64_simple8b_inner(values: list[int], out: bytearray) -> None:
    encode_varuint(len(values), out)
    if not values:
        return
    max_value = max(values)
    if max_value > (1 << 60) - 1:
        out.append(0)
        for value in values:
            encode_varuint(value, out)
        return

    out.append(1)
    idx = 0
    while idx < len(values):
        zero_run = 0
        while idx + zero_run < len(values) and values[idx + zero_run] == 0 and zero_run < 240:
            zero_run += 1
        if zero_run >= 120:
            take = 240 if zero_run >= 240 else 120
            word = 0 if take == 240 else 1 << 60
            append_u64_le(out, word)
            idx += take
            continue

        packed = False
        for selector_idx, (count, slot_width) in enumerate(SIMPLE8B_SLOTS):
            if idx + count > len(values):
                continue
            max_encodable = (1 << 64) - 1 if slot_width == 64 else (1 << slot_width) - 1
            if any(v > max_encodable for v in values[idx : idx + count]):
                continue
            selector = selector_idx + 2
            payload = 0
            shift = 0
            for value in values[idx : idx + count]:
                payload |= value << shift
                shift += slot_width
            word = (selector << 60) | payload
            append_u64_le(out, word)
            idx += count
            packed = True
            break
        if not packed:
            selector = 15
            word = (selector << 60) | (values[idx] & ((1 << 60) - 1))
            append_u64_le(out, word)
            idx += 1


def decode_u64_simple8b_inner(reader: Reader) -> list[int]:
    length = reader.read_count()
    if length == 0:
        return []
    mode = reader.read_u8()
    if mode == 0:
        return [reader.read_varuint() for _ in range(length)]
    if mode != 1:
        raise invalid_data("simple8b mode")

    out: list[int] = []
    while len(out) < length:
        packed = read_u64_le(reader)
        selector = packed >> 60
        payload = packed & ((1 << 60) - 1)
        if selector in (0, 1):
            count = 240 if selector == 0 else 120
            remain = length - len(out)
            limit = min(count, remain)
            out.extend([0] * limit)
        elif 2 <= selector <= 15:
            if selector == 15:
                count = 1
                width = 60
            else:
                count, width = SIMPLE8B_SLOTS[selector - 2]
            mask = (1 << 64) - 1 if width == 64 else (1 << width) - 1
            shift = 0
            remain = length - len(out)
            limit = min(count, remain)
            for _ in range(limit):
                out.append((payload >> shift) & mask)
                shift += width
        else:
            raise invalid_data("simple8b selector")
    return out


def delta(values: list[int]) -> list[int]:
    out: list[int] = []
    prev = 0
    for i, value in enumerate(values):
        if i == 0:
            out.append(value)
        else:
            out.append(value - prev)
        prev = value
    return out


def undelta(values: list[int]) -> list[int]:
    out: list[int] = []
    prev = 0
    for i, value in enumerate(values):
        if i == 0:
            out.append(value)
            prev = value
            continue
        nxt, ok = checked_add_i64(prev, value)
        if not ok:
            raise invalid_data("delta overflow")
        out.append(nxt)
        prev = nxt
    return out


def encode_i64_rle(values: list[int], out: bytearray) -> None:
    runs: list[tuple[int, int]] = []
    for value in values:
        if runs and runs[-1][0] == value:
            runs[-1] = (value, runs[-1][1] + 1)
        else:
            runs.append((value, 1))
    encode_varuint(len(runs), out)
    for val, count in runs:
        encode_varuint(encode_zigzag(val), out)
        encode_varuint(count, out)


def decode_i64_rle(reader: Reader) -> list[int]:
    runs_len = reader.read_count()
    out: list[int] = []
    for _ in range(runs_len):
        value = decode_zigzag(reader.read_varuint())
        count = reader.read_count()
        out.extend([value] * count)
    return out


def encode_i64_patched_for(values: list[int], out: bytearray) -> None:
    if not values:
        encode_varuint(0, out)
        return
    base = min(values)
    shifted = [v - base for v in values]
    encode_varuint(len(shifted), out)
    encode_varuint(encode_zigzag(base), out)

    max_value = max(shifted) if shifted else 0
    bw = bit_width(max_value)
    base_width = bw - 2 if bw > 2 else 0
    out.append(base_width)

    patch_positions: list[tuple[int, int]] = []
    main_values: list[int] = []
    for idx, value in enumerate(shifted):
        if bit_width(value) > base_width:
            patch_positions.append((idx, value))
            main = 0
            if base_width > 0:
                mask = (1 << base_width) - 1
                main = value & mask
                if main < 0:
                    main = 0
            main_values.append(main)
        else:
            main_values.append(value)
    for value in main_values:
        encode_varuint(value, out)
    encode_varuint(len(patch_positions), out)
    for pos, val in patch_positions:
        encode_varuint(pos, out)
        encode_varuint(val, out)


def decode_i64_patched_for(reader: Reader) -> list[int]:
    length = reader.read_count()
    if length == 0:
        return []
    base = decode_zigzag(reader.read_varuint())
    reader.read_u8()
    values = [reader.read_varuint() for _ in range(length)]
    patch_count = reader.read_count()
    for _ in range(patch_count):
        pos = reader.read_varuint()
        patch = reader.read_varuint()
        if pos < len(values):
            values[pos] = patch
    return [v + base for v in values]


def leading_zeros64(x: int) -> int:
    if x == 0:
        return 64
    return 64 - x.bit_length()


def trailing_zeros64(x: int) -> int:
    if x == 0:
        return 64
    return (x & -x).bit_length() - 1


def encode_xor_float(values: list[float], out: bytearray) -> None:
    encode_varuint(len(values), out)
    if not values:
        return
    append_u64_le(out, struct.unpack("<Q", struct.pack("<d", values[0]))[0])
    prev = struct.unpack("<Q", struct.pack("<d", values[0]))[0]
    for value in values[1:]:
        bits_value = struct.unpack("<Q", struct.pack("<d", value))[0]
        x = prev ^ bits_value
        if x == 0:
            out.append(0)
        else:
            out.append(1)
            leading = leading_zeros64(x)
            trailing = trailing_zeros64(x)
            width = 64 - (leading + trailing)
            encode_varuint(leading, out)
            encode_varuint(trailing, out)
            encode_varuint(width, out)
            payload = x if width == 64 else (x >> trailing) & ((1 << width) - 1)
            encode_varuint(payload, out)
        prev = bits_value


def decode_xor_float(reader: Reader) -> list[float]:
    length = reader.read_count()
    if length == 0:
        return []
    first_bits = read_u64_le(reader)
    out = [struct.unpack("<d", struct.pack("<Q", first_bits))[0]]
    prev = first_bits
    for _ in range(1, length):
        flag = reader.read_u8()
        bits_value = prev
        if flag != 0:
            leading = reader.read_varuint()
            trailing = reader.read_varuint()
            width = reader.read_varuint()
            payload = reader.read_varuint()
            if leading + trailing + width > 64:
                raise invalid_data("xor-float bit widths")
            x = payload if width == 64 else payload << trailing
            bits_value = prev ^ x
        out.append(struct.unpack("<d", struct.pack("<Q", bits_value))[0])
        prev = bits_value
    return out


def encode_i64_direct_bitpack(values: list[int], out: bytearray) -> None:
    encode_varuint(len(values), out)
    if not values:
        out.append(0)
        return
    encoded = [encode_zigzag(v) for v in values]
    width = max(bit_width(v) for v in encoded)
    out.append(width)
    pack_u64_values(encoded, width, out)


def decode_i64_direct_bitpack(reader: Reader) -> list[int]:
    length = reader.read_count()
    width = reader.read_u8()
    if length == 0:
        return []
    if width == 0 or width > 64:
        raise invalid_data("bitpack width")
    encoded = unpack_u64_values(reader, length, width)
    return [decode_zigzag(v) for v in encoded]


def encode_i64_delta_delta(values: list[int], out: bytearray) -> None:
    encode_varuint(len(values), out)
    if not values:
        return
    encode_varuint(encode_zigzag(values[0]), out)
    if len(values) == 1:
        return
    d1 = values[1] - values[0]
    encode_varuint(encode_zigzag(d1), out)
    dd: list[int] = []
    prev_delta = d1
    for i in range(1, len(values) - 1):
        d = values[i + 1] - values[i]
        dd.append(d - prev_delta)
        prev_delta = d
    encode_i64_direct_bitpack(dd, out)


def decode_i64_delta_delta(reader: Reader) -> list[int]:
    length = reader.read_count()
    if length == 0:
        return []
    first = decode_zigzag(reader.read_varuint())
    if length == 1:
        return [first]
    first_delta = decode_zigzag(reader.read_varuint())
    dd = decode_i64_direct_bitpack(reader)
    if len(dd) != length - 2:
        raise invalid_data("delta-delta length")
    out = [first]
    prev = first
    second, ok = checked_add_i64(prev, first_delta)
    if not ok:
        raise invalid_data("delta-delta overflow")
    out.append(second)
    prev = second
    prev_delta = first_delta
    for ddv in dd:
        d, ok = checked_add_i64(prev_delta, ddv)
        if not ok:
            raise invalid_data("delta-delta overflow")
        nxt, ok = checked_add_i64(prev, d)
        if not ok:
            raise invalid_data("delta-delta overflow")
        out.append(nxt)
        prev = nxt
        prev_delta = d
    return out


def pack_u64_values(values: list[int], width: int, out: bytearray) -> None:
    total_bits = len(values) * width
    byte_len = (total_bits + 7) // 8
    bytes_arr = bytearray(byte_len)
    bit_pos = 0
    for value in values:
        written = 0
        while written < width:
            byte_idx = bit_pos // 8
            bit_off = bit_pos % 8
            room = 8 - bit_off
            take = min(width - written, room)
            mask = (1 << take) - 1
            part = (value >> written) & mask
            bytes_arr[byte_idx] |= part << bit_off
            bit_pos += take
            written += take
    out.extend(bytes_arr)


def unpack_u64_values(reader: Reader, length: int, width: int) -> list[int]:
    total_bits = length * width
    byte_len = (total_bits + 7) // 8
    raw = reader.read_exact(byte_len)
    out: list[int] = []
    bit_pos = 0
    for _ in range(length):
        value = 0
        written = 0
        while written < width:
            byte_idx = bit_pos // 8
            if byte_idx >= len(raw):
                raise invalid_data("bitpack underflow")
            bit_off = bit_pos % 8
            room = 8 - bit_off
            take = min(width - written, room)
            mask = (1 << take) - 1
            part = (raw[byte_idx] >> bit_off) & mask
            value |= part << written
            bit_pos += take
            written += take
        out.append(value)
    return out


def bit_width(v: int) -> int:
    if v == 0:
        return 1
    return v.bit_length()


_U64_MAX = (1 << 64) - 1


def checked_add_u64(a: int, b: int) -> tuple[int, bool]:
    total = a + b
    if total > _U64_MAX:
        return 0, False
    return total, True


def checked_add_i64(a: int, b: int) -> tuple[int, bool]:
    total = a + b
    if (b > 0 and total < a) or (b < 0 and total > a):
        return 0, False
    return total, True
