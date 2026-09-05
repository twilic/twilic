"""Trained dictionary encoding and decoding."""

from __future__ import annotations

from .errors import invalid_data
from .model import Column, ElementType, VectorCodec
from .session import (
    DictionaryFallbackFailFast,
    DictionaryFallbackStatelessRetry,
    DictionaryProfile,
    SessionState,
    UnknownReferencePolicyStatelessRetry,
    allocate_dictionary_id,
)
from .wire import encode_string, encode_varuint, new_reader


def decode_trained_dictionary_payload(payload: bytes) -> list[str]:
    reader = new_reader(payload)
    n = reader.read_count()
    values: list[str] = []
    for _ in range(n):
        values.append(reader.read_string())
    if not reader.is_eof():
        raise invalid_data("trained dictionary payload trailing bytes")
    return values


def encode_trained_dictionary_block(
    values: list[str], dictionary: list[str]
) -> tuple[bytes | None, bool, None]:
    if not values:
        out = bytearray()
        out.append(0)
        encode_varuint(0, out)
        return bytes(out), True, None
    by_value = {value: idx for idx, value in enumerate(dictionary)}
    ids: list[int] = []
    for value in values:
        ref_id = by_value.get(value)
        if ref_id is None:
            return None, False, None
        ids.append(ref_id)
    raw = bytearray([0])
    encode_varuint(len(ids), raw)
    for ref_id in ids:
        encode_varuint(ref_id, raw)
    max_id = max(ids) if ids else 0
    bit_width = 0 if max_id == 0 else max_id.bit_length()
    packed = bytearray()
    pack_fixed_width_u64(ids, bit_width, packed)
    bitpacked = bytearray([1])
    encode_varuint(len(ids), bitpacked)
    bitpacked.append(bit_width)
    bitpacked.extend(packed)
    if len(bitpacked) < len(raw):
        return bytes(bitpacked), True, None
    return bytes(raw), True, None


def decode_trained_dictionary_block(block: bytes, dictionary: list[str]) -> list[str]:
    reader = new_reader(block)
    mode = reader.read_u8()
    n = reader.read_count()
    ids: list[int]
    if mode == 0:
        ids = [reader.read_varuint() for _ in range(n)]
    elif mode == 1:
        bit_width = reader.read_u8()
        remaining = len(block) - reader.position()
        packed = reader.read_exact(remaining)
        ids = unpack_fixed_width_u64(packed, n, bit_width)
    else:
        raise invalid_data("trained dictionary block mode")
    if not reader.is_eof():
        raise invalid_data("trained dictionary block trailing bytes")
    out: list[str] = []
    for ref_id in ids:
        if ref_id >= len(dictionary):
            raise invalid_data("trained dictionary block id")
        out.append(dictionary[ref_id])
    return out


class _WideU128:
    __slots__ = ("lo", "hi")

    def __init__(self, lo: int = 0, hi: int = 0) -> None:
        self.lo = lo & 0xFFFFFFFFFFFFFFFF
        self.hi = hi & 0xFFFFFFFFFFFFFFFF

    @staticmethod
    def from_u64(v: int) -> _WideU128:
        return _WideU128(lo=v)

    @staticmethod
    def mask(width: int) -> _WideU128:
        if width == 64:
            return _WideU128(lo=(1 << 64) - 1, hi=(1 << 64) - 1)
        if width == 0:
            return _WideU128()
        if width <= 64:
            return _WideU128(lo=(1 << width) - 1)
        lo = (1 << 64) - 1
        hi = (1 << (width - 64)) - 1
        return _WideU128(lo=lo, hi=hi)

    def is_zero(self) -> bool:
        return self.lo == 0 and self.hi == 0

    def and_(self, other: _WideU128) -> _WideU128:
        return _WideU128(lo=self.lo & other.lo, hi=self.hi & other.hi)

    def or_(self, other: _WideU128) -> _WideU128:
        return _WideU128(lo=self.lo | other.lo, hi=self.hi | other.hi)

    def shl(self, n: int) -> _WideU128:
        if n == 0:
            return _WideU128(lo=self.lo, hi=self.hi)
        if n >= 128:
            return _WideU128()
        if n < 64:
            hi = ((self.hi << n) | (self.lo >> (64 - n))) & 0xFFFFFFFFFFFFFFFF
            lo = (self.lo << n) & 0xFFFFFFFFFFFFFFFF
            return _WideU128(lo=lo, hi=hi)
        n -= 64
        return _WideU128(lo=0, hi=(self.lo << n) & 0xFFFFFFFFFFFFFFFF)

    def shr(self, n: int) -> _WideU128:
        if n == 0:
            return _WideU128(lo=self.lo, hi=self.hi)
        if n >= 128:
            return _WideU128()
        if n < 64:
            lo = ((self.lo >> n) | (self.hi << (64 - n))) & 0xFFFFFFFFFFFFFFFF
            hi = (self.hi >> n) & 0xFFFFFFFFFFFFFFFF
            return _WideU128(lo=lo, hi=hi)
        n -= 64
        return _WideU128(lo=(self.hi >> n) & 0xFFFFFFFFFFFFFFFF, hi=0)


def pack_fixed_width_u64(values: list[int], width: int, out: bytearray) -> None:
    if width > 64:
        raise invalid_data("fixed-width u64 bit width")
    if width == 0:
        for value in values:
            if value != 0:
                raise invalid_data("fixed-width u64 value overflow")
        return
    acc = _WideU128()
    acc_bits = 0
    for value in values:
        if width < 64 and value >> width:
            raise invalid_data("fixed-width u64 value overflow")
        acc = acc.or_(_WideU128.from_u64(value).shl(acc_bits))
        acc_bits += width
        while acc_bits >= 8:
            out.append(acc.lo & 0xFF)
            acc = acc.shr(8)
            acc_bits -= 8
    if acc_bits > 0:
        out.append(acc.lo & 0xFF)


def unpack_fixed_width_u64(data: bytes, count: int, width: int) -> list[int]:
    if width > 64:
        raise invalid_data("fixed-width u64 bit width")
    if width == 0:
        for b in data:
            if b != 0:
                raise invalid_data("fixed-width u64 trailing bytes")
        return [0] * count
    out: list[int] = []
    acc = _WideU128()
    acc_bits = 0
    idx = 0
    mask = _WideU128.mask(width)
    for _ in range(count):
        while acc_bits < width:
            if idx >= len(data):
                raise invalid_data("fixed-width u64 underflow")
            acc = acc.or_(_WideU128.from_u64(data[idx]).shl(acc_bits))
            idx += 1
            acc_bits += 8
        out.append(acc.and_(mask).lo)
        acc = acc.shr(width)
        acc_bits -= width
    if not acc.is_zero():
        raise invalid_data("fixed-width u64 trailing bytes")
    for j in range(idx, len(data)):
        if data[j] != 0:
            raise invalid_data("fixed-width u64 trailing bytes")
    return out


def apply_dictionary_references(state: SessionState, columns: list[Column]) -> None:
    for column in columns:
        if column.values.kind != ElementType.STRING:
            continue
        values = column.values.strings
        if len(values) < 16:
            continue
        unique = set(values)
        if len(unique) / len(values) > 0.5:
            continue
        if column.codec not in (VectorCodec.DICTIONARY, VectorCodec.STRING_REF):
            continue
        dict_id = allocate_dictionary_id(state)
        payload = bytearray()
        keys = sorted(unique)
        encode_varuint(len(keys), payload)
        for item in keys:
            encode_string(item, payload)
        profile = DictionaryProfile(
            version=1,
            hash=dictionary_payload_hash(bytes(payload)),
            expires_at=0,
            fallback=DictionaryFallbackFailFast,
        )
        if state.options.unknown_reference_policy == UnknownReferencePolicyStatelessRetry:
            profile.fallback = DictionaryFallbackStatelessRetry
        state.dictionaries[dict_id] = bytes(payload)
        state.dictionary_profiles[dict_id] = profile
        column.dictionary_id = dict_id


def fnv1a64(payload: bytes) -> int:
    h = 0xCBF29CE484222325
    for b in payload:
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def dictionary_payload_hash(payload: bytes) -> int:
    return fnv1a64(payload)
