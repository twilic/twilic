"""Low-level wire encoding and decoding primitives."""

from __future__ import annotations

import struct
from contextlib import contextmanager
from functools import wraps

from .errors import invalid_data, unexpected_eof, utf8_error


def encode_varuint(value: int, out: bytearray) -> None:
    if value < 0x80:
        out.append(value)
        return
    while True:
        b = value & 0x7F
        value >>= 7
        if value != 0:
            b |= 0x80
        out.append(b)
        if value == 0:
            break


def encode_zigzag(value: int) -> int:
    return (value << 1) ^ (value >> 63)


def decode_zigzag(value: int) -> int:
    return (value >> 1) ^ -(value & 1)


def encode_bytes(data: bytes, out: bytearray) -> None:
    encode_varuint(len(data), out)
    out.extend(data)


def encode_string(value: str, out: bytearray) -> None:
    encode_bytes(value.encode("utf-8"), out)


def encode_bitmap(bits: list[bool], out: bytearray) -> None:
    encode_varuint(len(bits), out)
    current = 0
    for i, bit in enumerate(bits):
        if bit:
            current |= 1 << (i % 8)
        if i % 8 == 7:
            out.append(current)
            current = 0
    if len(bits) % 8 != 0:
        out.append(current)


class Reader:
    __slots__ = ("_input", "_offset", "_depth", "_budget")

    def __init__(self, input_data: bytes) -> None:
        self._input = input_data
        self._offset = 0
        self._depth = 0
        self._budget = min(1 << 20, len(input_data) * 1024)

    def claim_output(self, count: int, width: int = 8) -> None:
        if count < 0 or count > 1 << 20:
            raise invalid_data("decode count limit exceeded")
        size = count * width
        if size > self._budget:
            raise invalid_data("decode output ratio exceeded")
        self._budget -= size

    def read_count(self, maximum: int = 1 << 20) -> int:
        count = self.read_varuint()
        if count > maximum:
            raise invalid_data("decode count limit exceeded")
        self.claim_output(count)
        return count

    @contextmanager
    def nested(self):
        if self._depth >= 64:
            raise invalid_data("decode depth limit exceeded")
        self._depth += 1
        try:
            yield
        finally:
            self._depth -= 1

    def position(self) -> int:
        return self._offset

    def is_eof(self) -> bool:
        return self._offset >= len(self._input)

    def read_u8(self) -> int:
        if self._offset >= len(self._input):
            raise unexpected_eof()
        b = self._input[self._offset]
        self._offset += 1
        return b

    def read_exact(self, n: int) -> bytes:
        end = self._offset + n
        if n < 0 or n > len(self._input) - self._offset:
            raise unexpected_eof()
        slice_ = self._input[self._offset : end]
        self._offset = end
        return slice_

    def read_varuint(self) -> int:
        shift = 0
        result = 0
        while True:
            if shift >= 64:
                raise invalid_data("varuint too large")
            b = self.read_u8()
            if shift == 63 and b & 0x7E:
                raise invalid_data("varuint too large")
            result |= (b & 0x7F) << shift
            if b & 0x80 == 0:
                return result
            shift += 7

    def read_i64_zigzag(self) -> int:
        encoded = self.read_varuint()
        return decode_zigzag(encoded)

    def read_bytes(self) -> bytes:
        n = self.read_varuint()
        return self.read_exact(n)

    def read_string(self) -> str:
        n = self.read_varuint()
        data = self.read_exact(n)
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise utf8_error() from exc

    def read_bitmap(self) -> list[bool]:
        bit_count = self.read_count()
        byte_count = (bit_count + 7) // 8
        raw = self.read_exact(byte_count)
        bits = [False] * bit_count
        for i in range(bit_count):
            bits[i] = ((raw[i // 8] >> (i % 8)) & 1) == 1
        return bits


def new_reader(input_data: bytes) -> Reader:
    return Reader(input_data)


def read_u64_le(reader: Reader) -> int:
    b = reader.read_exact(8)
    return struct.unpack("<Q", b)[0]


def read_f64_le(reader: Reader) -> float:
    u = read_u64_le(reader)
    return struct.unpack("<d", struct.pack("<Q", u))[0]


def append_u64_le(out: bytearray, v: int) -> None:
    out.extend(struct.pack("<Q", v & 0xFFFFFFFFFFFFFFFF))


def append_f64_le(out: bytearray, v: float) -> None:
    append_u64_le(out, struct.unpack("<Q", struct.pack("<d", v))[0])


def bounded_decode(function):
    """Apply one shared recursion budget to nested decode operations."""

    @wraps(function)
    def wrapped(*args, **kwargs):
        reader = next(arg for arg in args if isinstance(arg, Reader))
        with reader.nested():
            return function(*args, **kwargs)

    return wrapped
