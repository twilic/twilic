"""Shared pytest helpers ported from twilic-go/internal/core/test_helpers_test.go."""

from __future__ import annotations

import pytest

from twilic import (
    Message,
    MessageKind,
    MessageMapEntry,
    Schema,
    SchemaField,
    TwilicError,
    TwilicErrorKind,
    Value,
    equal,
    key_ref_literal,
)

TAG_STRING = 6


def scalar_string_mode(data: bytes) -> int:
    if len(data) < 3:
        pytest.fail(f"expected at least 3 bytes, got {len(data)}")
    if data[0] != int(MessageKind.SCALAR):
        pytest.fail(f"expected scalar kind byte, got {data[0]}")
    if data[1] != TAG_STRING:
        pytest.fail(f"expected string tag byte, got {data[1]}")
    return data[2]


def require_twilic_error_kind(err: BaseException, kind: TwilicErrorKind) -> TwilicError:
    if not isinstance(err, TwilicError):
        pytest.fail(f"expected TwilicError, got {err!r}")
    if err.kind != kind:
        pytest.fail(f"expected error kind {kind}, got {err.kind}")
    return err


def equal_key_ref(a, b) -> bool:
    return a.is_id == b.is_id and a.id == b.id and a.literal == b.literal


def equal_message(a: Message, b: Message) -> bool:
    if a.kind != b.kind:
        return False
    match a.kind:
        case MessageKind.SCALAR:
            assert a.scalar is not None and b.scalar is not None
            return equal(a.scalar.clone(), b.scalar.clone())
        case MessageKind.ARRAY:
            if len(a.array) != len(b.array):
                return False
            return all(equal(a.array[i], b.array[i]) for i in range(len(a.array)))
        case MessageKind.MAP:
            if len(a.map) != len(b.map):
                return False
            return all(
                equal_key_ref(a.map[i].key, b.map[i].key) and equal(a.map[i].value, b.map[i].value)
                for i in range(len(a.map))
            )
        case _:
            return a.clone().__dict__ == b.clone().__dict__


def message_map_entry(key: str, value: Value) -> MessageMapEntry:
    return MessageMapEntry(key=key_ref_literal(key), value=value)


def sample_schema() -> Schema:
    return Schema(
        schema_id=41,
        name="User",
        fields=[
            SchemaField(
                number=1,
                name="id",
                logical_type="u64",
                required=True,
                min=1000,
                max=1100,
            ),
            SchemaField(number=2, name="name", logical_type="string", required=True),
            SchemaField(
                number=3,
                name="score",
                logical_type="i64",
                required=False,
                min=0,
                max=100,
            ),
        ],
    )
