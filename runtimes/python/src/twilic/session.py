"""Session state and intern tables."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum

from .model import Column, Message, Schema, TemplateDescriptor


class UnknownReferencePolicy(IntEnum):
    FAIL_FAST = 0
    STATELESS_RETRY = 1


UnknownReferencePolicyFailFast = UnknownReferencePolicy.FAIL_FAST
UnknownReferencePolicyStatelessRetry = UnknownReferencePolicy.STATELESS_RETRY


class DictionaryFallback(IntEnum):
    FAIL_FAST = 0
    STATELESS_RETRY = 1


DictionaryFallbackFailFast = DictionaryFallback.FAIL_FAST
DictionaryFallbackStatelessRetry = DictionaryFallback.STATELESS_RETRY


def dictionary_fallback_from_byte(b: int) -> tuple[DictionaryFallback, bool]:
    if b == 0:
        return DictionaryFallback.FAIL_FAST, True
    if b == 1:
        return DictionaryFallback.STATELESS_RETRY, True
    return DictionaryFallback(0), False


@dataclass
class DictionaryProfile:
    version: int
    hash: int
    expires_at: int
    fallback: DictionaryFallback


@dataclass
class SessionOptions:
    max_base_snapshots: int = 8
    enable_state_patch: bool = True
    enable_template_batch: bool = True
    enable_trained_dictionary: bool = True
    unknown_reference_policy: UnknownReferencePolicy = UnknownReferencePolicy.FAIL_FAST


def default_session_options() -> SessionOptions:
    return SessionOptions()


class InternTable:
    __slots__ = ("by_value", "by_id")

    def __init__(self) -> None:
        self.by_value: dict[str, int] = {}
        self.by_id: list[str] = []

    def get_id(self, value: str) -> tuple[int, bool]:
        ref_id = self.by_value.get(value)
        return (ref_id, ref_id is not None)

    def get_value(self, ref_id: int) -> tuple[str, bool]:
        if ref_id >= len(self.by_id):
            return "", False
        return self.by_id[ref_id], True

    def register(self, value: str) -> int:
        existing = self.by_value.get(value)
        if existing is not None:
            return existing
        ref_id = len(self.by_id)
        self.by_id.append(value)
        self.by_value[value] = ref_id
        return ref_id

    def clear(self) -> None:
        self.by_value = {}
        self.by_id = []


def shape_key(keys: list[str]) -> str:
    return "\0".join(keys)


class ShapeTable:
    __slots__ = ("by_keys", "by_id", "observations", "next_id")

    def __init__(self) -> None:
        self.by_keys: dict[str, int] = {}
        self.by_id: dict[int, list[str]] = {}
        self.observations: dict[str, int] = {}
        self.next_id = 0

    def get_id(self, keys: list[str]) -> tuple[int, bool]:
        sk = shape_key(keys)
        ref_id = self.by_keys.get(sk)
        return (ref_id, ref_id is not None)

    def get_keys(self, ref_id: int) -> tuple[list[str], bool]:
        keys = self.by_id.get(ref_id)
        return (keys, keys is not None)

    def register(self, keys: list[str]) -> int:
        sk = shape_key(keys)
        existing = self.by_keys.get(sk)
        if existing is not None:
            return existing
        ref_id = self.next_id
        self.next_id += 1
        self.by_id[ref_id] = list(keys)
        self.by_keys[sk] = ref_id
        return ref_id

    def register_with_id(self, shape_id: int, keys: list[str]) -> bool:
        sk = shape_key(keys)
        existing = self.by_id.get(shape_id)
        if existing is not None:
            return shape_key(existing) == sk
        existing_id = self.by_keys.get(sk)
        if existing_id is not None and existing_id != shape_id:
            return False
        self.by_id[shape_id] = list(keys)
        self.by_keys[sk] = shape_id
        if shape_id + 1 > self.next_id:
            self.next_id = shape_id + 1
        return True

    def observe(self, keys: list[str]) -> int:
        sk = shape_key(keys)
        self.observations[sk] = self.observations.get(sk, 0) + 1
        return self.observations[sk]

    def clear(self) -> None:
        self.by_keys = {}
        self.by_id = {}
        self.observations = {}
        self.next_id = 0


@dataclass
class _BaseSnapshotEntry:
    id: int
    message: Message


@dataclass
class SessionState:
    options: SessionOptions = field(default_factory=default_session_options)
    key_table: InternTable = field(default_factory=InternTable)
    string_table: InternTable = field(default_factory=InternTable)
    shape_table: ShapeTable = field(default_factory=ShapeTable)
    encode_shape_observations: dict[str, int] = field(default_factory=dict)
    base_snapshots: list[_BaseSnapshotEntry] = field(default_factory=list)
    templates: dict[int, TemplateDescriptor] = field(default_factory=dict)
    template_columns: dict[int, list[Column]] = field(default_factory=dict)
    field_enums: dict[str, list[str]] = field(default_factory=dict)
    dictionaries: dict[int, bytes] = field(default_factory=dict)
    dictionary_profiles: dict[int, DictionaryProfile] = field(default_factory=dict)
    schemas: dict[int, Schema] = field(default_factory=dict)
    last_schema_id: int | None = None
    previous_message: Message | None = None
    previous_message_size: int | None = None
    next_base_id: int = 0
    next_template_id: int = 0
    next_dictionary_id: int = 0


def new_session_state() -> SessionState:
    return SessionState()


def new_session_state_with_options(options: SessionOptions) -> SessionState:
    return SessionState(options=options)


def register_base_snapshot(state: SessionState, base_id: int, message: Message) -> None:
    filtered = [e for e in state.base_snapshots if e.id != base_id]
    filtered.append(_BaseSnapshotEntry(id=base_id, message=message.clone()))
    while len(filtered) > state.options.max_base_snapshots:
        filtered.pop(0)
    state.base_snapshots = filtered


def allocate_base_id(state: SessionState) -> int:
    ref_id = state.next_base_id
    state.next_base_id += 1
    return ref_id


def allocate_template_id(state: SessionState) -> int:
    ref_id = state.next_template_id
    state.next_template_id += 1
    return ref_id


def allocate_dictionary_id(state: SessionState) -> int:
    ref_id = state.next_dictionary_id
    state.next_dictionary_id += 1
    return ref_id


def get_base_snapshot(state: SessionState, base_id: int) -> tuple[Message | None, bool]:
    for entry in state.base_snapshots:
        if entry.id == base_id:
            return entry.message.clone(), True
    return None, False


def reset_tables(state: SessionState) -> None:
    state.key_table.clear()
    state.string_table.clear()
    state.shape_table.clear()
    state.encode_shape_observations = {}
    state.field_enums = {}


def reset_state(state: SessionState) -> None:
    reset_tables(state)
    state.base_snapshots = []
    state.templates = {}
    state.template_columns = {}
    state.dictionaries = {}
    state.dictionary_profiles = {}
    state.schemas = {}
    state.last_schema_id = None
    state.previous_message = None
    state.previous_message_size = None
    state.next_base_id = 0
    state.next_template_id = 0
    state.next_dictionary_id = 0
