"""Port of twilic-go/internal/core/dynamic_profile_spec_test.go."""

from __future__ import annotations

from conftest import scalar_string_mode
from twilic import (
    ControlMessage,
    ControlOpcodeResetTables,
    Message,
    MessageKind,
    StringModeEmpty,
    StringModeLiteral,
    StringModePrefixDelta,
    StringModeRef,
    entry,
    new_array,
    new_i64,
    new_map,
    new_string,
    new_twilic_codec,
    new_u64,
)


def test_dynamic_profile_shape_promotes_after_second_three_field_map():
    codec = new_twilic_codec()
    value = new_map(
        entry("id", new_u64(1)),
        entry("name", new_string("alice")),
        entry("role", new_string("admin")),
    )

    first_bytes = codec.encode_value(value.clone())
    first_msg = codec.decode_message(first_bytes)
    assert first_msg.kind == MessageKind.MAP

    second_bytes = codec.encode_value(value.clone())
    second_msg = codec.decode_message(second_bytes)
    assert second_msg.kind == MessageKind.SHAPED_OBJECT

    third_bytes = codec.encode_value(value.clone())
    third_msg = codec.decode_message(third_bytes)
    assert third_msg.kind == MessageKind.SHAPED_OBJECT


def test_dynamic_profile_two_field_map_keeps_map_and_uses_key_ids():
    codec = new_twilic_codec()
    value = new_map(entry("id", new_u64(1)), entry("name", new_string("alice")))

    first_bytes = codec.encode_value(value.clone())
    first_msg = codec.decode_message(first_bytes)
    assert first_msg.kind == MessageKind.MAP
    for entry_item in first_msg.map:
        assert not entry_item.key.is_id, "expected literal keys on first map"

    second_bytes = codec.encode_value(value.clone())
    second_msg = codec.decode_message(second_bytes)
    assert second_msg.kind in (MessageKind.MAP, MessageKind.SHAPED_OBJECT)
    if second_msg.kind == MessageKind.MAP:
        for entry_item in second_msg.map:
            assert entry_item.key.is_id, "expected key ref ids on second map"


def test_dynamic_profile_typed_vector_threshold_is_applied():
    codec = new_twilic_codec()

    short = new_array([new_i64(1), new_i64(2), new_i64(3)])
    short_bytes = codec.encode_value(short)
    short_msg = codec.decode_message(short_bytes)
    assert short_msg.kind == MessageKind.ARRAY

    long = new_array([new_i64(1), new_i64(2), new_i64(3), new_i64(4)])
    long_bytes = codec.encode_value(long)
    long_msg = codec.decode_message(long_bytes)
    assert long_msg.kind == MessageKind.TYPED_VECTOR


def test_dynamic_profile_string_modes_empty_ref_and_prefix_delta_are_used():
    codec = new_twilic_codec()

    empty_bytes = codec.encode_value(new_string(""))
    assert scalar_string_mode(empty_bytes) == int(StringModeEmpty)

    lit_bytes = codec.encode_value(new_string("alpha"))
    assert scalar_string_mode(lit_bytes) == int(StringModeLiteral)

    ref_bytes = codec.encode_value(new_string("alpha"))
    assert scalar_string_mode(ref_bytes) == int(StringModeRef)

    codec.encode_value(new_string("prefix_common_aaaa"))
    prefix_delta_bytes = codec.encode_value(new_string("prefix_common_bbbb"))
    assert scalar_string_mode(prefix_delta_bytes) == int(StringModePrefixDelta)


def test_dynamic_profile_reset_tables_clears_string_interning():
    codec = new_twilic_codec()

    codec.encode_value(new_string("ephemeral"))
    reused_bytes = codec.encode_value(new_string("ephemeral"))
    assert scalar_string_mode(reused_bytes) == int(StringModeRef)

    reset = Message(
        kind=MessageKind.CONTROL,
        control=ControlMessage(opcode=ControlOpcodeResetTables, reset_tables=True),
    )
    reset_bytes = codec.encode_message(reset)
    codec.decode_message(reset_bytes)

    after_bytes = codec.encode_value(new_string("ephemeral"))
    assert scalar_string_mode(after_bytes) == int(StringModeLiteral)
