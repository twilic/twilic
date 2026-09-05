"""Port of twilic-go/internal/core/control_stream_and_control_spec_test.go."""

from __future__ import annotations

from conftest import equal_message, require_twilic_error_kind
from twilic import (
    ControlMessage,
    ControlOpcodeRegisterKeys,
    ControlOpcodeRegisterShape,
    ControlOpcodeResetState,
    ControlStreamCodec,
    ControlStreamCodecBitpack,
    ControlStreamCodecFse,
    ControlStreamCodecHuffman,
    ControlStreamCodecPlain,
    ControlStreamCodecRle,
    ControlStreamMessage,
    Message,
    MessageKind,
    RegisterShapeControl,
    ShapedObjectMessage,
    ValueKind,
    key_ref_id,
    key_ref_literal,
    new_string,
    new_twilic_codec,
    new_u64,
)
from twilic.wire import new_reader


def _encoded_control_stream_len(codec: ControlStreamCodec, payload: bytes) -> int:
    codec_impl = new_twilic_codec()
    msg = Message(
        kind=MessageKind.CONTROL_STREAM,
        control_stream=ControlStreamMessage(codec=codec, payload=payload),
    )
    data = codec_impl.encode_message(msg)
    return len(data)


def test_control_stream_and_control_spec_control_stream_roundtrips_for_all_declared_codecs():
    codec = new_twilic_codec()
    payload = bytes([0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4])
    for stream_codec in (
        ControlStreamCodecPlain,
        ControlStreamCodecRle,
        ControlStreamCodecBitpack,
        ControlStreamCodecHuffman,
        ControlStreamCodecFse,
    ):
        msg = Message(
            kind=MessageKind.CONTROL_STREAM,
            control_stream=ControlStreamMessage(codec=stream_codec, payload=payload),
        )
        data = codec.encode_message(msg)
        decoded = codec.decode_message(data)
        assert equal_message(decoded, msg), f"control stream mismatch for codec {stream_codec}"


def test_control_stream_and_control_spec_control_stream_bitpack_huffman_fse_compact_repetitive_payloads():
    binary_payload = bytes(i % 2 for i in range(512))
    plain_binary_len = _encoded_control_stream_len(ControlStreamCodecPlain, binary_payload)
    bitpack_len = _encoded_control_stream_len(ControlStreamCodecBitpack, binary_payload)
    assert bitpack_len <= plain_binary_len, "expected bitpack <= plain for binary payload"

    rle_friendly = bytes(7 for _ in range(512))
    plain_rle_len = _encoded_control_stream_len(ControlStreamCodecPlain, rle_friendly)
    huffman_len = _encoded_control_stream_len(ControlStreamCodecHuffman, rle_friendly)
    assert huffman_len <= plain_rle_len, "expected huffman <= plain for repetitive payload"

    low_card = bytes(i % 4 for i in range(512))
    plain_low_card_len = _encoded_control_stream_len(ControlStreamCodecPlain, low_card)
    fse_len = _encoded_control_stream_len(ControlStreamCodecFse, low_card)
    assert fse_len <= plain_low_card_len, "expected fse <= plain for low-cardinality payload"


def test_control_stream_and_control_spec_control_stream_fse_uses_fse_frame_mode():
    codec = new_twilic_codec()
    payload = bytes(i % 4 for i in range(512))
    msg = Message(
        kind=MessageKind.CONTROL_STREAM,
        control_stream=ControlStreamMessage(codec=ControlStreamCodecFse, payload=payload),
    )
    data = codec.encode_message(msg)

    reader = new_reader(data)
    kind = reader.read_u8()
    assert kind == int(MessageKind.CONTROL_STREAM)
    codec_byte = reader.read_u8()
    assert codec_byte == int(ControlStreamCodecFse)
    framed = reader.read_bytes()
    assert len(framed) > 0, "expected non-empty framed payload"


def test_control_stream_and_control_spec_register_shape_with_key_ids_roundtrips():
    codec = new_twilic_codec()
    reg_keys = Message(
        kind=MessageKind.CONTROL,
        control=ControlMessage(
            opcode=ControlOpcodeRegisterKeys,
            register_keys=["id", "name"],
        ),
    )
    reg_keys_bytes = codec.encode_message(reg_keys)
    codec.decode_message(reg_keys_bytes)

    reg_shape = Message(
        kind=MessageKind.CONTROL,
        control=ControlMessage(
            opcode=ControlOpcodeRegisterShape,
            register_shape=RegisterShapeControl(
                shape_id=99,
                keys=[key_ref_id(0), key_ref_id(1)],
            ),
        ),
    )
    reg_shape_bytes = codec.encode_message(reg_shape)
    decoded = codec.decode_message(reg_shape_bytes)
    assert decoded.kind == MessageKind.CONTROL
    assert decoded.control is not None
    assert decoded.control.register_shape is not None

    shaped = Message(
        kind=MessageKind.SHAPED_OBJECT,
        shaped_object=ShapedObjectMessage(
            shape_id=99,
            values=[new_u64(1), new_string("alice")],
        ),
    )
    shaped_bytes = codec.encode_message(shaped)
    value = codec.decode_value(shaped_bytes)
    assert value.kind == ValueKind.MAP


def test_control_stream_and_control_spec_reset_state_clears_shape_resolution():
    from twilic import ErrUnknownReference

    codec = new_twilic_codec()
    reg_shape = Message(
        kind=MessageKind.CONTROL,
        control=ControlMessage(
            opcode=ControlOpcodeRegisterShape,
            register_shape=RegisterShapeControl(
                shape_id=7,
                keys=[key_ref_literal("id"), key_ref_literal("name")],
            ),
        ),
    )
    reg_bytes = codec.encode_message(reg_shape)
    codec.decode_message(reg_bytes)

    reset = Message(
        kind=MessageKind.CONTROL,
        control=ControlMessage(opcode=ControlOpcodeResetState, reset_state=True),
    )
    reset_bytes = codec.encode_message(reset)
    codec.decode_message(reset_bytes)

    shaped = Message(
        kind=MessageKind.SHAPED_OBJECT,
        shaped_object=ShapedObjectMessage(
            shape_id=7,
            values=[new_u64(1), new_string("alice")],
        ),
    )
    shaped_bytes = codec.encode_message(shaped)
    try:
        codec.decode_value(shaped_bytes)
        raise AssertionError("expected decode error")
    except Exception as err:
        te = require_twilic_error_kind(err, ErrUnknownReference)
        assert te.ref_kind == "shape_id"
        assert te.ref_id == 7
