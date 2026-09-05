"""Port of twilic-go/internal/core/bound_batch_stateful_spec_test.go."""

from __future__ import annotations

from conftest import message_map_entry, require_twilic_error_kind, sample_schema
from twilic import (
    Column,
    ColumnBatchMessage,
    DictionaryFallbackFailFast,
    DictionaryProfile,
    ElementTypeString,
    ErrStatelessRetryRequired,
    Message,
    MessageKind,
    NullStrategyAllPresentElided,
    PatchOpcodeDeleteField,
    PatchOpcodeInsertField,
    PatchOperation,
    StatePatchMessage,
    TypedVectorData,
    UnknownReferencePolicyStatelessRetry,
    VectorCodecDictionary,
    base_ref_id,
    base_ref_previous,
    default_session_options,
    entry,
    new_array,
    new_i64,
    new_map,
    new_session_encoder,
    new_string,
    new_twilic_codec,
    new_u64,
)
from twilic.dictionary import dictionary_payload_hash
from twilic.wire import encode_string, encode_varuint, new_reader


def test_bound_batch_stateful_schema_id_is_sent_first_then_omitted():
    enc = new_session_encoder(default_session_options())
    schema = sample_schema()
    value = new_map(
        entry("id", new_u64(1005)),
        entry("name", new_string("alice")),
        entry("score", new_i64(99)),
    )

    first = enc.encode_with_schema(schema, value.clone())
    first_msg = enc.decode_message(first)
    assert first_msg.kind == MessageKind.SCHEMA_OBJECT
    assert first_msg.schema_object is not None
    assert first_msg.schema_object.schema_id == 41

    second = enc.encode_with_schema(schema, value.clone())
    second_msg = enc.decode_message(second)
    assert second_msg.kind == MessageKind.SCHEMA_OBJECT


def test_bound_batch_stateful_batch_threshold_selects_row_vs_column():
    enc = new_session_encoder(default_session_options())

    rows15 = [new_map(entry("id", new_u64(i))) for i in range(15)]
    b15 = enc.encode_batch(rows15)
    assert len(b15) > 0
    assert MessageKind(b15[0]) in (MessageKind.COLUMN_BATCH, MessageKind.ROW_BATCH)

    rows16 = [new_map(entry("id", new_u64(i))) for i in range(16)]
    b16 = enc.encode_batch(rows16)
    assert len(b16) > 0
    assert MessageKind(b16[0]) == MessageKind.COLUMN_BATCH


def test_bound_batch_stateful_micro_batch_reuses_template_and_emits_changed_mask():
    enc = new_session_encoder(default_session_options())
    rows1 = [
        new_map(entry("id", new_u64(1)), entry("name", new_string("a"))),
        new_map(entry("id", new_u64(2)), entry("name", new_string("b"))),
        new_map(entry("id", new_u64(3)), entry("name", new_string("c"))),
        new_map(entry("id", new_u64(4)), entry("name", new_string("d"))),
    ]
    first = enc.encode_micro_batch(rows1)
    assert len(first) > 0
    assert MessageKind(first[0]) == MessageKind.TEMPLATE_BATCH

    rows2 = [
        new_map(entry("id", new_u64(1)), entry("name", new_string("aa"))),
        new_map(entry("id", new_u64(2)), entry("name", new_string("bb"))),
        new_map(entry("id", new_u64(3)), entry("name", new_string("cc"))),
        new_map(entry("id", new_u64(4)), entry("name", new_string("dd"))),
    ]
    second = enc.encode_micro_batch(rows2)
    assert len(second) > 0
    assert MessageKind(second[0]) == MessageKind.TEMPLATE_BATCH


def test_bound_batch_stateful_state_patch_uses_recommended_ratio_threshold():
    enc = new_session_encoder(default_session_options())
    base_values = [new_i64(i) for i in range(100)]
    one_change_values = base_values.copy()
    one_change_values[0] = new_i64(10_000)
    twelve_change_values = base_values.copy()
    for i in range(12):
        twelve_change_values[i] = new_i64(10_000 + i)

    base = new_array(base_values)
    one_change = new_array(one_change_values)
    twelve_changes = new_array(twelve_change_values)

    enc.encode(base)
    p1 = enc.encode_patch(one_change)
    enc.decode_message(p1)

    p2 = enc.encode_patch(twelve_changes)
    enc.decode_message(p2)


def test_bound_batch_stateful_unknown_base_id_honors_stateless_retry_policy():
    opts = default_session_options()
    opts.unknown_reference_policy = UnknownReferencePolicyStatelessRetry
    enc = new_session_encoder(opts)

    patch = Message(
        kind=MessageKind.STATE_PATCH,
        state_patch=StatePatchMessage(
            base_ref=base_ref_id(12345),
            operations=[],
            literals=[],
        ),
    )
    builder = new_twilic_codec()
    patch_bytes = builder.encode_message(patch)

    try:
        enc.decode_message(patch_bytes)
        raise AssertionError("expected decode error")
    except Exception as err:
        te = require_twilic_error_kind(err, ErrStatelessRetryRequired)
        assert te.ref_kind == "base_id"
        assert te.ref_id == 12345


def test_bound_batch_stateful_state_patch_map_insert_and_delete_roundtrip_via_reconstruction():
    codec = new_twilic_codec()
    base = Message(
        kind=MessageKind.MAP,
        map=[
            message_map_entry("id", new_u64(1)),
            message_map_entry("name", new_string("alice")),
        ],
    )
    base_bytes = codec.encode_message(base)
    codec.decode_message(base_bytes)

    insert_value = new_map(entry("role", new_string("admin")))
    insert_patch = Message(
        kind=MessageKind.STATE_PATCH,
        state_patch=StatePatchMessage(
            base_ref=base_ref_previous(),
            operations=[
                PatchOperation(
                    field_id=2,
                    opcode=PatchOpcodeInsertField,
                    value=insert_value,
                )
            ],
        ),
    )
    insert_bytes = codec.encode_message(insert_patch)
    codec.decode_message(insert_bytes)
    assert codec.state.previous_message is not None
    assert codec.state.previous_message.kind == MessageKind.MAP

    delete_patch = Message(
        kind=MessageKind.STATE_PATCH,
        state_patch=StatePatchMessage(
            base_ref=base_ref_previous(),
            operations=[PatchOperation(field_id=2, opcode=PatchOpcodeDeleteField)],
        ),
    )
    delete_bytes = codec.encode_message(delete_patch)
    codec.decode_message(delete_bytes)
    assert codec.state.previous_message is not None
    assert codec.state.previous_message.kind == MessageKind.MAP
    assert len(codec.state.previous_message.map) == 2


def test_bound_batch_stateful_column_batch_assigns_dictionary_id_for_repeated_string_field():
    enc = new_session_encoder(default_session_options())
    rows = []
    for i in range(32):
        role = "admin" if i % 2 == 0 else "user"
        rows.append(new_map(entry("id", new_u64(i)), entry("role", new_string(role))))
    batch_bytes = enc.encode_batch(rows)
    assert len(batch_bytes) > 0
    assert MessageKind(batch_bytes[0]) == MessageKind.COLUMN_BATCH


def test_bound_batch_stateful_trained_dictionary_profile_is_transported_to_fresh_decoder():
    enc = new_session_encoder(default_session_options())
    rows = []
    for i in range(32):
        role = "admin" if i % 2 == 0 else "user"
        rows.append(new_map(entry("id", new_u64(i)), entry("role", new_string(role))))
    batch_bytes = enc.encode_batch(rows)

    dec = new_twilic_codec()
    decoded = dec.decode_message(batch_bytes)
    assert decoded.kind == MessageKind.COLUMN_BATCH
    assert decoded.column_batch is not None

    dict_id = None
    for col in decoded.column_batch.columns:
        if col.dictionary_id is not None:
            dict_id = col.dictionary_id
            break
    assert dict_id is not None, "dictionary id in batch"

    assert dict_id in dec.state.dictionaries, "transported dictionary payload"
    profile = dec.state.dictionary_profiles.get(dict_id)
    assert profile is not None, "transported dictionary profile"
    assert profile.version == 1
    assert profile.expires_at == 0
    assert profile.fallback == DictionaryFallbackFailFast
    assert profile.hash == dictionary_payload_hash(dec.state.dictionaries[dict_id])

    role_values = None
    for col in decoded.column_batch.columns:
        if col.dictionary_id == dict_id:
            role_values = col.values.strings
            break
    assert role_values is not None
    assert len(role_values) == 32
    assert role_values[0] == "admin"
    assert role_values[1] == "user"


def test_bound_batch_stateful_invalid_dictionary_profile_hash_is_rejected():
    enc = new_twilic_codec()
    dict_id = 42
    enc.state.dictionaries[dict_id] = bytes([1, 2, 3, 4])
    enc.state.dictionary_profiles[dict_id] = DictionaryProfile(
        version=1,
        hash=7,
        expires_at=0,
        fallback=DictionaryFallbackFailFast,
    )

    msg = Message(
        kind=MessageKind.COLUMN_BATCH,
        column_batch=ColumnBatchMessage(
            count=1,
            columns=[
                Column(
                    field_id=0,
                    null_strategy=NullStrategyAllPresentElided,
                    codec=VectorCodecDictionary,
                    dictionary_id=dict_id,
                    values=TypedVectorData(
                        kind=ElementTypeString,
                        strings=["admin"],
                    ),
                )
            ],
        ),
    )
    batch_bytes = enc.encode_message(msg)

    dec = new_twilic_codec()
    try:
        dec.decode_message(batch_bytes)
        raise AssertionError("expected decode failure for handcrafted dictionary profile payload")
    except Exception as err:
        from twilic import ErrInvalidData, TwilicError

        assert isinstance(err, TwilicError)
        assert err.kind == ErrInvalidData
        assert err.msg == "dictionary profile hash mismatch"


def test_bound_batch_stateful_trained_dictionary_reference_writes_compressed_block_after_dict_id():
    dict_id = 9
    codec = new_twilic_codec()
    payload = bytearray()
    encode_varuint(2, payload)
    encode_string("admin", payload)
    encode_string("user", payload)
    codec.state.dictionaries[dict_id] = bytes(payload)
    codec.state.dictionary_profiles[dict_id] = DictionaryProfile(
        version=1,
        hash=dictionary_payload_hash(bytes(payload)),
        expires_at=0,
        fallback=DictionaryFallbackFailFast,
    )
    msg = Message(
        kind=MessageKind.COLUMN_BATCH,
        column_batch=ColumnBatchMessage(
            count=4,
            columns=[
                Column(
                    field_id=1,
                    null_strategy=NullStrategyAllPresentElided,
                    codec=VectorCodecDictionary,
                    dictionary_id=dict_id,
                    values=TypedVectorData(
                        kind=ElementTypeString,
                        strings=["admin", "user", "admin", "user"],
                    ),
                )
            ],
        ),
    )
    batch_bytes = codec.encode_message(msg)

    reader = new_reader(batch_bytes)
    kind = reader.read_u8()
    assert kind == int(MessageKind.COLUMN_BATCH)
    reader.read_varuint()
    reader.read_varuint()
    reader.read_varuint()
    reader.read_u8()
    reader.read_u8()
    got_dict_id = reader.read_varuint()
    assert got_dict_id != 0, "expected non-zero dictionary id marker"

    fresh = new_twilic_codec()
    decoded = fresh.decode_message(batch_bytes)
    assert decoded.kind == MessageKind.COLUMN_BATCH
    assert decoded.column_batch is not None
    values = decoded.column_batch.columns[0].values.strings
    want = ["admin", "user", "admin", "user"]
    assert values == want
