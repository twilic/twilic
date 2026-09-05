import pytest

from twilic.codec import decode_u64_rle
from twilic.errors import TwilicError
from twilic.v2 import decode_v2
from twilic.wire import Reader


def test_depth_rejection_and_clean_next_decode():
    with pytest.raises(TwilicError, match="depth limit"):
        decode_v2(bytes([0xA1]) * 70 + bytes([0xC0]))
    assert decode_v2(bytes([0xA0])).arr == []


def test_rle_rejects_excessive_expansion_before_allocating():
    from twilic.wire import encode_varuint

    data = bytearray()
    for item in [1, 0, 100_000]:
        encode_varuint(item, data)
    with pytest.raises(TwilicError, match="output ratio"):
        decode_u64_rle(Reader(bytes(data)))


def test_budget_and_negative_length():
    reader = Reader(b"\0")
    reader.claim_output(100)
    with pytest.raises(TwilicError, match="output ratio"):
        reader.claim_output(100)
    with pytest.raises(TwilicError):
        Reader(b"\0").read_exact(-1)
