"""Twilic session protocol codec."""

from __future__ import annotations

import struct

from .codec import (
    decode_f64_vector,
    decode_i64_vector,
    decode_u64_vector,
    encode_f64_vector,
    encode_i64_vector,
    encode_u64_vector,
)
from .dictionary import (
    apply_dictionary_references,
    decode_trained_dictionary_block,
    decode_trained_dictionary_payload,
    dictionary_payload_hash,
    encode_trained_dictionary_block,
)
from .errors import (
    invalid_data,
    invalid_kind,
    invalid_tag,
    is_stateless_retry,
    is_unknown_reference,
    stateless_retry_required,
    unknown_reference,
)
from .model import (
    BaseRef,
    BaseSnapshotMessage,
    Column,
    ColumnBatchMessage,
    ControlMessage,
    ControlOpcode,
    ControlStreamCodec,
    ControlStreamMessage,
    ElementType,
    ExtMessage,
    KeyRef,
    MapEntry,
    Message,
    MessageKind,
    MessageMapEntry,
    NullStrategy,
    PatchOpcode,
    PatchOperation,
    PromoteEnumControl,
    RegisterShapeControl,
    RowBatchMessage,
    Schema,
    SchemaField,
    SchemaObjectMessage,
    ShapedObjectMessage,
    StatePatchMessage,
    StringMode,
    TemplateBatchMessage,
    TemplateDescriptor,
    TypedVector,
    TypedVectorData,
    Value,
    ValueKind,
    VectorCodec,
    base_ref_id,
    base_ref_previous,
    clone_typed_vector_data,
    control_opcode_from_byte,
    control_stream_codec_from_byte,
    element_type_from_byte,
    entry,
    equal,
    key_ref_id,
    key_ref_literal,
    message_kind_from_byte,
    new_array,
    new_binary,
    new_bool,
    new_f64,
    new_i64,
    new_map,
    new_null,
    new_string,
    new_u64,
    null_strategy_from_byte,
    patch_opcode_from_byte,
    string_mode_from_byte,
    vector_codec_from_byte,
)
from .session import (
    SessionOptions,
    SessionState,
    UnknownReferencePolicy,
    allocate_base_id,
    allocate_template_id,
    default_session_options,
    dictionary_fallback_from_byte,
    get_base_snapshot,
    new_session_state,
    new_session_state_with_options,
    register_base_snapshot,
    reset_state,
    reset_tables,
    shape_key,
)
from .wire import (
    Reader,
    append_f64_le,
    append_u64_le,
    bounded_decode,
    decode_zigzag,
    encode_bitmap,
    encode_bytes,
    encode_string,
    encode_varuint,
    encode_zigzag,
    new_reader,
    read_f64_le,
)

TAG_NULL = 0
TAG_BOOL_FALSE = 1
TAG_BOOL_TRUE = 2
TAG_I64 = 3
TAG_U64 = 4
TAG_F64 = 5
TAG_STRING = 6
TAG_BINARY = 7
TAG_ARRAY = 8
TAG_MAP = 9


class TwilicCodec:
    def __init__(self, state: SessionState | None = None) -> None:
        self.state = state if state is not None else new_session_state()

    def encode_message(self, message: Message) -> bytes:
        out = bytearray()
        self._write_message(message, out)
        return bytes(out)

    def decode_message(self, data: bytes) -> Message:
        reader = new_reader(data)
        msg = self._read_message(reader)
        if not reader.is_eof():
            raise invalid_data("trailing bytes in message")
        match msg.kind:
            case MessageKind.CONTROL:
                pass
            case MessageKind.STATE_PATCH:
                sp = msg.state_patch
                assert sp is not None
                try:
                    reconstructed = self._apply_state_patch(sp.base_ref, sp.operations, sp.literals)
                except Exception as err:
                    if is_unknown_reference(err) or is_stateless_retry(err):
                        raise
                else:
                    size = len(data)
                    self.state.previous_message = reconstructed
                    self.state.previous_message_size = size
            case MessageKind.TEMPLATE_BATCH:
                if self.state.previous_message is None:
                    cl = msg.clone()
                    self.state.previous_message = cl
                    self.state.previous_message_size = len(data)
            case _:
                cl = msg.clone()
                self.state.previous_message = cl
                self.state.previous_message_size = len(data)
        return msg

    def encode_value(self, value: Value) -> bytes:
        msg = self._message_for_value(value)
        out = self.encode_message(msg)
        self.state.previous_message = msg.clone()
        self.state.previous_message_size = len(out)
        return out

    def decode_value(self, data: bytes) -> Value:
        msg = self.decode_message(data)
        self.state.previous_message = msg.clone()
        match msg.kind:
            case MessageKind.SCALAR:
                assert msg.scalar is not None
                return msg.scalar.clone()
            case MessageKind.ARRAY:
                return new_array([v.clone() for v in msg.array])
            case MessageKind.MAP:
                entries = entries_to_map(msg.map, self.state)
                return new_map(*entries)
            case MessageKind.SHAPED_OBJECT:
                so = msg.shaped_object
                assert so is not None
                keys, ok = self.state.shape_table.get_keys(so.shape_id)
                if not ok:
                    raise self._reference_error("shape_id", so.shape_id)
                return new_map(*shape_values_to_map(keys, so.presence, so.has_presence, so.values))
            case MessageKind.TYPED_VECTOR:
                assert msg.typed_vector is not None
                return typed_vector_to_value(msg.typed_vector)
            case _:
                raise invalid_data("decode_value expects scalar/array/map/vector message")

    def _reference_error(self, kind: str, ref_id: int) -> Exception:
        if self.state.options.unknown_reference_policy == UnknownReferencePolicy.STATELESS_RETRY:
            return stateless_retry_required(kind, ref_id)
        return unknown_reference(kind, ref_id)

    def _message_for_value(self, value: Value) -> Message:
        match value.kind:
            case ValueKind.ARRAY:
                vec, ok = self._try_make_typed_vector(value.arr)
                if ok:
                    return Message(kind=MessageKind.TYPED_VECTOR, typed_vector=vec)
                return Message(
                    kind=MessageKind.ARRAY,
                    array=[v.clone() for v in value.arr],
                )
            case ValueKind.MAP:
                keys = [e.key for e in value.map]
                had_observation = shape_key(keys) in self.state.encode_shape_observations
                obs = self._observe_encode_shape_candidate(keys)
                shape_id, ok = self.state.shape_table.get_id(keys)
                if ok and (not had_observation or obs >= 2):
                    return self._shaped_message(shape_id, value.map)
                return self._map_message(value.map)
            case _:
                sc = value.clone()
                return Message(kind=MessageKind.SCALAR, scalar=sc)

    def _map_message(self, entries: list[MapEntry]) -> Message:
        out: list[MessageMapEntry] = []
        for e in entries:
            key = e.key
            ref_id, ok = self.state.key_table.get_id(key)
            if ok:
                key_ref = key_ref_id(ref_id)
            else:
                self.state.key_table.register(key)
                key_ref = key_ref_literal(key)
            out.append(MessageMapEntry(key=key_ref, value=e.value.clone()))
        return Message(kind=MessageKind.MAP, map=out)

    def _shaped_message(self, shape_id: int, entries: list[MapEntry]) -> Message:
        keys, _ = self.state.shape_table.get_keys(shape_id)
        index = {e.key: e.value for e in entries}
        values: list[Value] = []
        presence: list[bool] = []
        all_present = True
        for key in keys:
            v = index.get(key)
            if v is not None:
                presence.append(True)
                values.append(v.clone())
            else:
                presence.append(False)
                all_present = False
        msg = ShapedObjectMessage(shape_id=shape_id, values=values)
        if not all_present:
            msg.has_presence = True
            msg.presence = presence
        return Message(kind=MessageKind.SHAPED_OBJECT, shaped_object=msg)

    def _try_make_typed_vector(self, values: list[Value]) -> tuple[TypedVector, bool]:
        if len(values) < 4:
            from .model import VectorCodec

            return (
                TypedVector(ElementType.BOOL, VectorCodec.PLAIN, TypedVectorData()),
                False,
            )
        all_bool = all(v.kind == ValueKind.BOOL for v in values)
        all_i64 = all(v.kind == ValueKind.I64 for v in values)
        all_u64 = all(v.kind == ValueKind.U64 for v in values)
        all_f64 = all(v.kind == ValueKind.F64 for v in values)
        all_str = all(v.kind == ValueKind.STRING for v in values)
        if not (all_bool or all_i64 or all_u64 or all_f64 or all_str):
            return TypedVector(ElementType.BOOL, VectorCodec.PLAIN, TypedVectorData()), False
        from .model import VectorCodec

        if all_bool:
            return TypedVector(
                element_type=ElementType.BOOL,
                codec=VectorCodec.DIRECT_BITPACK,
                data=TypedVectorData(kind=ElementType.BOOL, bools=[v.bool for v in values]),
            ), True
        if all_i64:
            vals = [v.i64 for v in values]
            return TypedVector(
                element_type=ElementType.I64,
                codec=select_integer_codec(vals),
                data=TypedVectorData(kind=ElementType.I64, i64s=vals),
            ), True
        if all_u64:
            vals = [v.u64 for v in values]
            return TypedVector(
                element_type=ElementType.U64,
                codec=select_u64_codec(vals),
                data=TypedVectorData(kind=ElementType.U64, u64s=vals),
            ), True
        if all_f64:
            vals = [v.f64 for v in values]
            return TypedVector(
                element_type=ElementType.F64,
                codec=select_float_codec(vals),
                data=TypedVectorData(kind=ElementType.F64, f64s=vals),
            ), True
        vals = [v.str for v in values]
        return TypedVector(
            element_type=ElementType.STRING,
            codec=select_string_codec(vals),
            data=TypedVectorData(kind=ElementType.STRING, strings=vals),
        ), True

    def _write_message(self, message: Message, out: bytearray) -> None:

        match message.kind:
            case MessageKind.SCALAR:
                out.append(int(MessageKind.SCALAR))
                assert message.scalar is not None
                self._write_value(message.scalar, out)
            case MessageKind.ARRAY:
                out.append(int(MessageKind.ARRAY))
                encode_varuint(len(message.array), out)
                for v in message.array:
                    self._write_value(v, out)
            case MessageKind.MAP:
                out.append(int(MessageKind.MAP))
                encode_varuint(len(message.map), out)
                for e in message.map:
                    self._write_key_ref(e.key, out)
                    field_id = key_ref_field_identity(e.key, self.state)
                    self._write_value_with_field(e.value, field_id, out)
            case MessageKind.SHAPED_OBJECT:
                out.append(int(MessageKind.SHAPED_OBJECT))
                so = message.shaped_object
                assert so is not None
                encode_varuint(so.shape_id, out)
                self._write_presence(so.presence, so.has_presence, out)
                encode_varuint(len(so.values), out)
                keys, ok = self.state.shape_table.get_keys(so.shape_id)
                if ok:
                    pres = so.presence
                    if not so.has_presence:
                        pres = [True] * len(keys)
                    v_idx = 0
                    for i, key in enumerate(keys):
                        if i < len(pres) and not pres[i]:
                            continue
                        if v_idx >= len(so.values):
                            break
                        self._write_value_with_field(so.values[v_idx], key, out)
                        v_idx += 1
                    while v_idx < len(so.values):
                        self._write_value(so.values[v_idx], out)
                        v_idx += 1
                else:
                    for v in so.values:
                        self._write_value(v, out)
            case MessageKind.SCHEMA_OBJECT:
                out.append(int(MessageKind.SCHEMA_OBJECT))
                so = message.schema_object
                assert so is not None
                schema_id = so.schema_id
                if schema_id is not None:
                    out.append(1)
                    encode_varuint(schema_id, out)
                else:
                    out.append(0)
                self._write_presence(so.presence, so.has_presence, out)
                encode_varuint(len(so.fields), out)
                schema: Schema | None = None
                if schema_id is not None:
                    schema = self.state.schemas.get(schema_id)
                elif self.state.last_schema_id is not None:
                    schema = self.state.schemas.get(self.state.last_schema_id)
                if schema is not None:
                    out.append(1)
                    self._write_schema_fields(schema, so.presence, so.has_presence, so.fields, out)
                    if schema_id is not None:
                        self.state.last_schema_id = schema_id
                else:
                    out.append(0)
                    for v in so.fields:
                        self._write_value(v, out)
            case MessageKind.TYPED_VECTOR:
                out.append(int(MessageKind.TYPED_VECTOR))
                assert message.typed_vector is not None
                self._write_typed_vector(message.typed_vector, out)
            case MessageKind.ROW_BATCH:
                out.append(int(MessageKind.ROW_BATCH))
                rb = message.row_batch
                assert rb is not None
                encode_varuint(len(rb.rows), out)
                for row in rb.rows:
                    encode_varuint(len(row), out)
                    for v in row:
                        self._write_value(v, out)
            case MessageKind.COLUMN_BATCH:
                out.append(int(MessageKind.COLUMN_BATCH))
                cb = message.column_batch
                assert cb is not None
                encode_varuint(cb.count, out)
                encode_varuint(len(cb.columns), out)
                for col in cb.columns:
                    self._write_column(col, out)
            case MessageKind.CONTROL:
                out.append(int(MessageKind.CONTROL))
                assert message.control is not None
                self._write_control(message.control, out)
            case MessageKind.EXT:
                out.append(int(MessageKind.EXT))
                ext = message.ext
                assert ext is not None
                encode_varuint(ext.ext_type, out)
                encode_bytes(ext.payload, out)
            case MessageKind.STATE_PATCH:
                out.append(int(MessageKind.STATE_PATCH))
                sp = message.state_patch
                assert sp is not None
                self._write_base_ref(sp.base_ref, out)
                encode_varuint(len(sp.operations), out)
                for op in sp.operations:
                    encode_varuint(op.field_id, out)
                    out.append(int(op.opcode))
                    if op.value is not None:
                        out.append(1)
                        self._write_value(op.value, out)
                    else:
                        out.append(0)
                encode_varuint(len(sp.literals), out)
                for lit in sp.literals:
                    self._write_value(lit, out)
            case MessageKind.TEMPLATE_BATCH:
                out.append(int(MessageKind.TEMPLATE_BATCH))
                tb = message.template_batch
                assert tb is not None
                encode_varuint(tb.template_id, out)
                encode_varuint(tb.count, out)
                encode_bitmap(tb.changed_column_mask, out)
                encode_varuint(len(tb.columns), out)
                for col in tb.columns:
                    self._write_column(col, out)
            case MessageKind.CONTROL_STREAM:
                out.append(int(MessageKind.CONTROL_STREAM))
                cs = message.control_stream
                assert cs is not None
                out.append(int(cs.codec))
                self._write_control_stream_payload(cs.codec, cs.payload, out)
            case MessageKind.BASE_SNAPSHOT:
                out.append(int(MessageKind.BASE_SNAPSHOT))
                bs = message.base_snapshot
                assert bs is not None
                encode_varuint(bs.base_id, out)
                encode_varuint(bs.schema_or_shape_ref, out)
                self._write_message(bs.payload, out)
                register_base_snapshot(self.state, bs.base_id, bs.payload)
            case _:
                raise invalid_data("unsupported message kind")

    @bounded_decode
    def _read_message(self, reader: Reader) -> Message:
        kind_byte = reader.read_u8()
        kind, ok = message_kind_from_byte(kind_byte)
        if not ok:
            raise invalid_kind(kind_byte)
        match kind:
            case MessageKind.SCALAR:
                v = self._read_value(reader)
                return Message(kind=MessageKind.SCALAR, scalar=v)
            case MessageKind.ARRAY:
                n = reader.read_count()
                values = [self._read_value(reader) for _ in range(n)]
                return Message(kind=MessageKind.ARRAY, array=values)
            case MessageKind.MAP:
                n = reader.read_count()
                entries: list[MessageMapEntry] = []
                for _ in range(n):
                    key_ref = self._read_key_ref(reader)
                    field_identity = key_ref_field_identity(key_ref, self.state)
                    v = self._read_value_with_field(reader, field_identity)
                    entries.append(MessageMapEntry(key=key_ref, value=v))
                keys = [key_ref_string(e.key, self.state) for e in entries]
                self._observe_decode_shape_candidate(keys)
                return Message(kind=MessageKind.MAP, map=entries)
            case MessageKind.SHAPED_OBJECT:
                shape_id = reader.read_count(65_535)
                presence, has_presence = self._read_presence(reader)
                n = reader.read_count()
                values: list[Value] = []
                keys, ok = self.state.shape_table.get_keys(shape_id)
                if ok:
                    pres = presence
                    if not has_presence:
                        pres = [True] * len(keys)
                    read_count = 0
                    for i, key in enumerate(keys):
                        if i < len(pres) and not pres[i]:
                            continue
                        if read_count >= n:
                            break
                        v = self._read_value_with_field(reader, key)
                        values.append(v)
                        read_count += 1
                    while read_count < n:
                        values.append(self._read_value(reader))
                        read_count += 1
                else:
                    for _ in range(n):
                        values.append(self._read_value(reader))
                return Message(
                    kind=MessageKind.SHAPED_OBJECT,
                    shaped_object=ShapedObjectMessage(
                        shape_id=shape_id,
                        presence=presence,
                        has_presence=has_presence,
                        values=values,
                    ),
                )
            case MessageKind.SCHEMA_OBJECT:
                has_schema = reader.read_u8()
                schema_id: int | None = None
                if has_schema == 1:
                    schema_id = reader.read_varuint()
                presence, has_presence = self._read_presence(reader)
                n = reader.read_count()
                mode = reader.read_u8()
                fields: list[Value] = []
                if mode == 1:
                    if schema_id is not None:
                        effective_id = schema_id
                    elif self.state.last_schema_id is not None:
                        effective_id = self.state.last_schema_id
                    else:
                        raise invalid_data("schema object requires schema id in context")
                    schema = self.state.schemas.get(effective_id)
                    if schema is None:
                        raise self._reference_error("schema_id", effective_id)
                    fields = self._read_schema_fields(schema, presence, has_presence, n, reader)
                    self.state.last_schema_id = effective_id
                else:
                    for _ in range(n):
                        fields.append(self._read_value(reader))
                    if schema_id is not None:
                        self.state.last_schema_id = schema_id
                return Message(
                    kind=MessageKind.SCHEMA_OBJECT,
                    schema_object=SchemaObjectMessage(
                        schema_id=schema_id,
                        presence=presence,
                        has_presence=has_presence,
                        fields=fields,
                    ),
                )
            case MessageKind.TYPED_VECTOR:
                tv = self._read_typed_vector(reader, None, None)
                return Message(kind=MessageKind.TYPED_VECTOR, typed_vector=tv)
            case MessageKind.ROW_BATCH:
                row_count = reader.read_count()
                rows: list[list[Value]] = []
                for _ in range(row_count):
                    field_count = reader.read_count()
                    rows.append([self._read_value(reader) for _ in range(field_count)])
                return Message(
                    kind=MessageKind.ROW_BATCH,
                    row_batch=RowBatchMessage(rows=rows),
                )
            case MessageKind.COLUMN_BATCH:
                count = reader.read_count()
                col_count = reader.read_count()
                cols = [self._read_column(reader) for _ in range(col_count)]
                return Message(
                    kind=MessageKind.COLUMN_BATCH,
                    column_batch=ColumnBatchMessage(count=count, columns=cols),
                )
            case MessageKind.CONTROL:
                ctrl = self._read_control(reader)
                return Message(kind=MessageKind.CONTROL, control=ctrl)
            case MessageKind.EXT:
                ext_type = reader.read_varuint()
                payload = reader.read_bytes()
                return Message(
                    kind=MessageKind.EXT,
                    ext=ExtMessage(ext_type=ext_type, payload=payload),
                )
            case MessageKind.STATE_PATCH:
                base_ref = self._read_base_ref(reader)
                n = reader.read_count()
                ops: list[PatchOperation] = []
                for _ in range(n):
                    field_id = reader.read_varuint()
                    op_byte = reader.read_u8()
                    opcode, ok = patch_opcode_from_byte(op_byte)
                    if not ok:
                        raise invalid_data("patch opcode")
                    has_value = reader.read_u8()
                    value: Value | None = None
                    if has_value == 1:
                        value = self._read_value(reader)
                    ops.append(PatchOperation(field_id=field_id, opcode=opcode, value=value))
                lit_n = reader.read_varuint()
                lits = [self._read_value(reader) for _ in range(lit_n)]
                return Message(
                    kind=MessageKind.STATE_PATCH,
                    state_patch=StatePatchMessage(base_ref=base_ref, operations=ops, literals=lits),
                )
            case MessageKind.TEMPLATE_BATCH:
                template_id = reader.read_varuint()
                count = reader.read_count()
                mask = reader.read_bitmap()
                col_n = reader.read_varuint()
                changed_cols = [self._read_column(reader) for _ in range(col_n)]
                full_cols = changed_cols
                prev = self.state.template_columns.get(template_id)
                if prev is not None:
                    full_cols = merge_template_columns(prev, mask, changed_cols)
                else:
                    for bit in mask:
                        if not bit:
                            raise self._reference_error("template_id", template_id)
                self.state.template_columns[template_id] = full_cols
                self.state.templates[template_id] = template_descriptor_from_columns(
                    template_id, full_cols
                )
                if count >= 16:
                    msg = Message(
                        kind=MessageKind.COLUMN_BATCH,
                        column_batch=ColumnBatchMessage(count=count, columns=full_cols),
                    )
                    self.state.previous_message = msg
                return Message(
                    kind=MessageKind.TEMPLATE_BATCH,
                    template_batch=TemplateBatchMessage(
                        template_id=template_id,
                        count=count,
                        changed_column_mask=mask,
                        columns=changed_cols,
                    ),
                )
            case MessageKind.CONTROL_STREAM:
                codec_byte = reader.read_u8()
                codec, ok = control_stream_codec_from_byte(codec_byte)
                if not ok:
                    raise invalid_data("control stream codec")
                payload = self._read_control_stream_payload(codec, reader)
                return Message(
                    kind=MessageKind.CONTROL_STREAM,
                    control_stream=ControlStreamMessage(codec=codec, payload=payload),
                )
            case MessageKind.BASE_SNAPSHOT:
                base_id = reader.read_varuint()
                ref = reader.read_varuint()
                payload = self._read_message(reader)
                register_base_snapshot(self.state, base_id, payload)
                return Message(
                    kind=MessageKind.BASE_SNAPSHOT,
                    base_snapshot=BaseSnapshotMessage(
                        base_id=base_id, schema_or_shape_ref=ref, payload=payload
                    ),
                )
            case _:
                raise invalid_data("unsupported message kind")

    def _write_value(self, value: Value, out: bytearray) -> None:
        self._write_value_with_field(value, None, out)

    def _write_value_with_field(
        self, value: Value, field_identity: str | None, out: bytearray
    ) -> None:
        match value.kind:
            case ValueKind.NULL:
                out.append(TAG_NULL)
            case ValueKind.BOOL:
                out.append(TAG_BOOL_TRUE if value.bool else TAG_BOOL_FALSE)
            case ValueKind.I64:
                out.append(TAG_I64)
                write_smallest_u64(encode_zigzag(value.i64), out)
            case ValueKind.U64:
                out.append(TAG_U64)
                write_smallest_u64(value.u64, out)
            case ValueKind.F64:
                out.append(TAG_F64)
                append_f64_le(out, value.f64)
            case ValueKind.STRING:
                out.append(TAG_STRING)
                if field_identity is not None:
                    enum_vals = self.state.field_enums.get(field_identity)
                    if enum_vals is not None:
                        for i, ev in enumerate(enum_vals):
                            if ev == value.str:
                                out.append(int(StringMode.INLINE_ENUM))
                                encode_varuint(i, out)
                                return
                if value.str == "":
                    out.append(int(StringMode.EMPTY))
                    return
                ref_id, ok = self.state.string_table.get_id(value.str)
                if ok:
                    out.append(int(StringMode.REF))
                    encode_varuint(ref_id, out)
                    return
                base_id, prefix_len, prefix_ok = self._best_prefix_base(value.str)
                if prefix_ok and prefix_len >= 4 and prefix_len < len(value.str):
                    out.append(int(StringMode.PREFIX_DELTA))
                    encode_varuint(base_id, out)
                    encode_varuint(prefix_len, out)
                    encode_string(value.str[prefix_len:], out)
                    self.state.string_table.register(value.str)
                    return
                out.append(int(StringMode.LITERAL))
                encode_string(value.str, out)
                self.state.string_table.register(value.str)
            case ValueKind.BINARY:
                out.append(TAG_BINARY)
                encode_bytes(value.bin, out)
            case ValueKind.ARRAY:
                out.append(TAG_ARRAY)
                encode_varuint(len(value.arr), out)
                for v in value.arr:
                    self._write_value(v, out)
            case ValueKind.MAP:
                out.append(TAG_MAP)
                encode_varuint(len(value.map), out)
                for e in value.map:
                    self._write_key_ref(key_ref_literal(e.key), out)
                    self._write_value_with_field(e.value, e.key, out)

    def _read_value(self, reader: Reader) -> Value:
        return self._read_value_with_field(reader, None)

    @bounded_decode
    def _read_value_with_field(self, reader: Reader, field_identity: str | None) -> Value:
        tag = reader.read_u8()
        if tag == TAG_NULL:
            return new_null()
        if tag == TAG_BOOL_FALSE:
            return new_bool(False)
        if tag == TAG_BOOL_TRUE:
            return new_bool(True)
        if tag == TAG_I64:
            v = read_smallest_u64(reader)
            return new_i64(decode_zigzag(v))
        if tag == TAG_U64:
            return new_u64(read_smallest_u64(reader))
        if tag == TAG_F64:
            return new_f64(read_f64_le(reader))
        if tag == TAG_STRING:
            mode_byte = reader.read_u8()
            mode, ok = string_mode_from_byte(mode_byte)
            if not ok:
                raise invalid_data("string mode")
            match mode:
                case StringMode.EMPTY:
                    return new_string("")
                case StringMode.LITERAL:
                    s = reader.read_string()
                    self.state.string_table.register(s)
                    return new_string(s)
                case StringMode.REF:
                    ref_id = reader.read_varuint()
                    s, ok = self.state.string_table.get_value(ref_id)
                    if not ok:
                        raise self._reference_error("string_id", ref_id)
                    return new_string(s)
                case StringMode.PREFIX_DELTA:
                    base_id = reader.read_varuint()
                    prefix_len = reader.read_count()
                    suffix = reader.read_string()
                    base, ok = self.state.string_table.get_value(base_id)
                    if not ok:
                        raise self._reference_error("string_id", base_id)
                    if prefix_len > len(base):
                        raise invalid_data("prefix delta length")
                    s = base[:prefix_len] + suffix
                    self.state.string_table.register(s)
                    return new_string(s)
                case StringMode.INLINE_ENUM:
                    if field_identity is None:
                        raise invalid_data("inline enum missing field identity")
                    enum_vals = self.state.field_enums.get(field_identity)
                    if enum_vals is None:
                        raise invalid_data("inline enum unknown field")
                    code = reader.read_varuint()
                    if code >= len(enum_vals):
                        raise invalid_data("inline enum code")
                    return new_string(enum_vals[code])
        if tag == TAG_BINARY:
            return new_binary(reader.read_bytes())
        if tag == TAG_ARRAY:
            n = reader.read_count()
            return new_array([self._read_value(reader) for _ in range(n)])
        if tag == TAG_MAP:
            n = reader.read_count()
            entries: list[MapEntry] = []
            for _ in range(n):
                key_ref = self._read_key_ref(reader)
                v = self._read_value_with_field(reader, key_ref.literal)
                entries.append(entry(key_ref.literal, v))
            return new_map(*entries)
        raise invalid_tag(tag)

    def _write_key_ref(self, key_ref: KeyRef, out: bytearray) -> None:
        if key_ref.is_id:
            out.append(1)
            encode_varuint(key_ref.id, out)
            return
        out.append(0)
        encode_string(key_ref.literal, out)
        self.state.key_table.register(key_ref.literal)

    def _read_key_ref(self, reader: Reader) -> KeyRef:
        mode = reader.read_u8()
        if mode == 1:
            ref_id = reader.read_varuint()
            key, ok = self.state.key_table.get_value(ref_id)
            if not ok:
                raise self._reference_error("key_id", ref_id)
            return key_ref_literal(key)
        if mode != 0:
            raise invalid_data("key ref mode")
        s = reader.read_string()
        self.state.key_table.register(s)
        return key_ref_literal(s)

    def _write_presence(self, presence: list[bool], has_presence: bool, out: bytearray) -> None:
        if not has_presence:
            out.append(0)
            return
        out.append(1)
        encode_bitmap(presence, out)

    def _read_presence(self, reader: Reader) -> tuple[list[bool], bool]:
        flag = reader.read_u8()
        if flag == 0:
            return [], False
        if flag != 1:
            raise invalid_data("presence flag")
        return reader.read_bitmap(), True

    def _write_typed_vector(self, vector: TypedVector, out: bytearray) -> None:

        out.append(int(vector.element_type))
        encode_varuint(typed_vector_len(vector.data), out)
        out.append(int(vector.codec))
        match vector.element_type:
            case ElementType.BOOL:
                encode_bitmap(vector.data.bools, out)
            case ElementType.I64:
                encode_i64_vector(vector.data.i64s, vector.codec, out)
            case ElementType.U64:
                encode_u64_vector(vector.data.u64s, vector.codec, out)
            case ElementType.F64:
                encode_f64_vector(vector.data.f64s, vector.codec, out)
            case ElementType.STRING:
                self._write_string_vector(vector.data.strings, vector.codec, out)
            case ElementType.BINARY:
                encode_varuint(len(vector.data.binary), out)
                for b in vector.data.binary:
                    encode_bytes(b, out)
            case ElementType.VALUE:
                encode_varuint(len(vector.data.values), out)
                for v in vector.data.values:
                    self._write_value(v, out)
            case _:
                raise invalid_data("unsupported element type")

    def _read_typed_vector(
        self,
        reader: Reader,
        forced_element: ElementType | None,
        expected_codec: VectorCodec | None,
    ) -> TypedVector:

        if forced_element is None:
            elem_byte = reader.read_u8()
            elem_type, ok = element_type_from_byte(elem_byte)
            if not ok:
                raise invalid_data("vector element type")
        else:
            elem_type = forced_element
        expected_len = reader.read_count()
        codec_byte = reader.read_u8()
        codec, ok = vector_codec_from_byte(codec_byte)
        if not ok:
            raise invalid_data("vector codec")
        if expected_codec is not None and codec != expected_codec:
            raise invalid_data("column codec mismatch")
        data = TypedVectorData(kind=elem_type)
        match elem_type:
            case ElementType.BOOL:
                data.bools = reader.read_bitmap()
            case ElementType.I64:
                data.i64s = decode_i64_vector(reader, codec)
            case ElementType.U64:
                data.u64s = decode_u64_vector(reader, codec)
            case ElementType.F64:
                data.f64s = decode_f64_vector(reader, codec)
            case ElementType.STRING:
                data.strings = self._read_string_vector(reader, codec)
            case ElementType.BINARY:
                n = reader.read_count()
                data.binary = [reader.read_bytes() for _ in range(n)]
            case ElementType.VALUE:
                n = reader.read_count()
                data.values = [self._read_value(reader) for _ in range(n)]
        if typed_vector_len(data) != expected_len:
            raise invalid_data("typed vector length mismatch")
        return TypedVector(element_type=elem_type, codec=codec, data=data)

    def _write_column(self, column: Column, out: bytearray) -> None:
        from .model import VectorCodec

        encode_varuint(column.field_id, out)
        out.append(int(column.null_strategy))
        if column.null_strategy in (
            NullStrategy.PRESENCE_BITMAP,
            NullStrategy.INVERTED_PRESENCE_BITMAP,
        ):
            if not column.has_presence or column.presence is None:
                raise invalid_data("missing column presence bitmap")
            encode_bitmap(column.presence, out)
        out.append(int(column.codec))
        if column.dictionary_id is not None:
            out.append(1)
            encode_varuint(column.dictionary_id, out)
            payload = self.state.dictionaries.get(column.dictionary_id)
            profile = self.state.dictionary_profiles.get(column.dictionary_id)
            if payload is not None and profile is not None:
                out.append(1)
                encode_varuint(profile.version, out)
                encode_varuint(profile.hash, out)
                encode_varuint(profile.expires_at, out)
                out.append(int(profile.fallback))
                encode_bytes(payload, out)
            else:
                out.append(0)
        else:
            out.append(0)
        trained_block: bytes | None = None
        if (
            column.dictionary_id is not None
            and column.values.kind == ElementType.STRING
            and column.codec in (VectorCodec.DICTIONARY, VectorCodec.STRING_REF)
        ):
            payload = self.state.dictionaries.get(column.dictionary_id)
            if payload is not None:
                try:
                    dictionary = decode_trained_dictionary_payload(payload)
                    block, ok, _ = encode_trained_dictionary_block(
                        column.values.strings, dictionary
                    )
                    if ok and block is not None:
                        trained_block = block
                except Exception:
                    pass
        if trained_block is not None:
            out.append(1)
            encode_bytes(trained_block, out)
            return
        out.append(0)
        tv = TypedVector(
            element_type=column.values.kind,
            codec=column.codec,
            data=clone_typed_vector_data(column.values),
        )
        self._write_typed_vector(tv, out)

    def _read_column(self, reader: Reader) -> Column:
        from .model import VectorCodec

        field_id = reader.read_varuint()
        null_byte = reader.read_u8()
        null_strategy, ok = null_strategy_from_byte(null_byte)
        if not ok:
            raise invalid_data("null strategy")
        presence: list[bool] = []
        has_presence = False
        if null_strategy in (
            NullStrategy.PRESENCE_BITMAP,
            NullStrategy.INVERTED_PRESENCE_BITMAP,
        ):
            presence = reader.read_bitmap()
            has_presence = True
        codec_byte = reader.read_u8()
        codec, ok = vector_codec_from_byte(codec_byte)
        if not ok:
            raise invalid_data("column codec")
        has_dict = reader.read_u8()
        dictionary_id: int | None = None
        if has_dict == 1:
            dict_id = reader.read_varuint()
            has_profile = reader.read_u8()
            if has_profile == 0:
                if dict_id not in self.state.dictionaries:
                    raise self._reference_error("dict_id", dict_id)
            elif has_profile == 1:
                version = reader.read_varuint()
                hash_val = reader.read_varuint()
                expires_at = reader.read_varuint()
                fallback_byte = reader.read_u8()
                fallback, ok = dictionary_fallback_from_byte(fallback_byte)
                if not ok:
                    raise invalid_data("dictionary fallback")
                payload = reader.read_bytes()
                if dictionary_payload_hash(payload) != hash_val:
                    raise invalid_data("dictionary profile hash mismatch")
                self.state.dictionaries[dict_id] = payload
                from .session import DictionaryProfile

                self.state.dictionary_profiles[dict_id] = DictionaryProfile(
                    version=version,
                    hash=hash_val,
                    expires_at=expires_at,
                    fallback=fallback,
                )
            else:
                raise invalid_data("dictionary profile flag")
            dictionary_id = dict_id
        elif has_dict != 0:
            raise invalid_data("dictionary flag")
        payload_mode = reader.read_u8()
        if payload_mode == 0:
            tv = self._read_typed_vector(reader, None, codec)
            values = tv.data
        elif payload_mode == 1:
            if dictionary_id is None:
                raise invalid_data("trained dictionary block requires dict_id")
            if codec not in (VectorCodec.DICTIONARY, VectorCodec.STRING_REF):
                raise invalid_data("trained dictionary block requires string dictionary codec")
            dictionary_payload = self.state.dictionaries.get(dictionary_id)
            if dictionary_payload is None:
                raise self._reference_error("dict_id", dictionary_id)
            dictionary = decode_trained_dictionary_payload(dictionary_payload)
            block = reader.read_bytes()
            strings = decode_trained_dictionary_block(block, dictionary)
            values = TypedVectorData(kind=ElementType.STRING, strings=strings)
        else:
            raise invalid_data("column payload mode")
        return Column(
            field_id=field_id,
            null_strategy=null_strategy,
            presence=presence,
            has_presence=has_presence,
            codec=codec,
            dictionary_id=dictionary_id,
            values=values,
        )

    def _write_control(self, control: ControlMessage, out: bytearray) -> None:
        out.append(int(control.opcode))
        match control.opcode:
            case ControlOpcode.REGISTER_KEYS:
                encode_varuint(len(control.register_keys), out)
                for k in control.register_keys:
                    encode_string(k, out)
                    self.state.key_table.register(k)
            case ControlOpcode.REGISTER_SHAPE:
                if control.register_shape is None:
                    raise invalid_data("register shape payload missing")
                rs = control.register_shape
                encode_varuint(rs.shape_id, out)
                encode_varuint(len(rs.keys), out)
                keys: list[str] = []
                for kr in rs.keys:
                    self._write_key_ref(kr, out)
                    keys.append(kr.literal)
                self.state.shape_table.register_with_id(rs.shape_id, keys)
            case ControlOpcode.REGISTER_STRINGS:
                encode_varuint(len(control.register_strings), out)
                for s in control.register_strings:
                    encode_string(s, out)
                    self.state.string_table.register(s)
            case ControlOpcode.PROMOTE_STRING_FIELD_TO_ENUM:
                if control.promote_string_field_to_enum is None:
                    raise invalid_data("promote enum payload missing")
                p = control.promote_string_field_to_enum
                encode_string(p.field_identity, out)
                encode_varuint(len(p.values), out)
                for v in p.values:
                    encode_string(v, out)
                self.state.field_enums[p.field_identity] = list(p.values)
            case ControlOpcode.RESET_TABLES:
                reset_tables(self.state)
            case ControlOpcode.RESET_STATE:
                reset_state(self.state)
            case _:
                raise invalid_data("control opcode")

    def _read_control(self, reader: Reader) -> ControlMessage:
        op_byte = reader.read_u8()
        opcode, ok = control_opcode_from_byte(op_byte)
        if not ok:
            raise invalid_data("control opcode")
        msg = ControlMessage(opcode=opcode)
        match opcode:
            case ControlOpcode.REGISTER_KEYS:
                n = reader.read_count()
                msg.register_keys = []
                for _ in range(n):
                    s = reader.read_string()
                    msg.register_keys.append(s)
                    self.state.key_table.register(s)
            case ControlOpcode.REGISTER_SHAPE:
                shape_id = reader.read_count(65_535)
                n = reader.read_count()
                keys: list[KeyRef] = []
                key_names: list[str] = []
                for _ in range(n):
                    k = self._read_key_ref(reader)
                    keys.append(k)
                    key_names.append(k.literal)
                self.state.shape_table.register_with_id(shape_id, key_names)
                msg.register_shape = RegisterShapeControl(shape_id=shape_id, keys=keys)
            case ControlOpcode.REGISTER_STRINGS:
                n = reader.read_count()
                msg.register_strings = []
                for _ in range(n):
                    s = reader.read_string()
                    msg.register_strings.append(s)
                    self.state.string_table.register(s)
            case ControlOpcode.PROMOTE_STRING_FIELD_TO_ENUM:
                field_identity = reader.read_string()
                n = reader.read_count()
                values = [reader.read_string() for _ in range(n)]
                self.state.field_enums[field_identity] = list(values)
                msg.promote_string_field_to_enum = PromoteEnumControl(
                    field_identity=field_identity, values=values
                )
            case ControlOpcode.RESET_TABLES:
                msg.reset_tables = True
                reset_tables(self.state)
            case ControlOpcode.RESET_STATE:
                msg.reset_state = True
                reset_state(self.state)
        return msg

    def _write_base_ref(self, base_ref: BaseRef, out: bytearray) -> None:
        if base_ref.previous:
            out.append(0)
            return
        out.append(1)
        encode_varuint(base_ref.base_id, out)

    def _read_base_ref(self, reader: Reader) -> BaseRef:
        mode = reader.read_u8()
        if mode == 0:
            return base_ref_previous()
        if mode == 1:
            return base_ref_id(reader.read_varuint())
        raise invalid_data("base ref")

    def _write_control_stream_payload(
        self, codec: ControlStreamCodec, payload: bytes, out: bytearray
    ) -> None:
        match codec:
            case ControlStreamCodec.PLAIN:
                encoded = bytes(payload)
            case ControlStreamCodec.RLE:
                encoded = rle_encode_bytes(payload)
            case ControlStreamCodec.BITPACK:
                encoded = control_bitpack_encode_bytes(payload)
            case ControlStreamCodec.HUFFMAN:
                encoded = control_huffman_encode_bytes(payload)
            case ControlStreamCodec.FSE:
                encoded = control_fse_encode_bytes(payload)
        encode_bytes(encoded, out)

    def _read_control_stream_payload(self, codec: ControlStreamCodec, reader: Reader) -> bytes:
        encoded = reader.read_bytes()
        match codec:
            case ControlStreamCodec.PLAIN:
                return encoded
            case ControlStreamCodec.RLE:
                return rle_decode_bytes(encoded)
            case ControlStreamCodec.BITPACK:
                return control_bitpack_decode_bytes(encoded)
            case ControlStreamCodec.HUFFMAN:
                return control_huffman_decode_bytes(encoded)
            case ControlStreamCodec.FSE:
                return control_fse_decode_bytes(encoded)
            case _:
                raise invalid_data("control stream codec")

    def _best_prefix_base(self, value: str) -> tuple[int, int, bool]:
        best_id = 0
        best_len = 0
        for sid, candidate in enumerate(self.state.string_table.by_id):
            n = common_prefix_len(value.encode(), candidate.encode())
            if n > best_len:
                best_len = n
                best_id = sid
        if best_len == 0:
            return 0, 0, False
        return best_id, best_len, True

    def _write_string_vector(self, values: list[str], codec: VectorCodec, out: bytearray) -> None:
        from .model import VectorCodec

        match codec:
            case VectorCodec.DICTIONARY:
                dct: dict[str, int] = {}
                uniq: list[str] = []
                refs: list[int] = []
                for v in values:
                    if v in dct:
                        refs.append(dct[v])
                    else:
                        rid = len(uniq)
                        dct[v] = rid
                        uniq.append(v)
                        refs.append(rid)
                encode_varuint(len(uniq), out)
                for u in uniq:
                    encode_string(u, out)
                encode_u64_vector(refs, VectorCodec.DIRECT_BITPACK, out)
            case VectorCodec.STRING_REF:
                encode_varuint(len(values), out)
                for v in values:
                    sid, ok = self.state.string_table.get_id(v)
                    if not ok:
                        sid = self.state.string_table.register(v)
                    encode_varuint(sid, out)
            case VectorCodec.PREFIX_DELTA:
                encode_varuint(len(values), out)
                prev = ""
                for v in values:
                    prefix = common_prefix_len(prev.encode(), v.encode())
                    encode_varuint(prefix, out)
                    encode_string(v[prefix:], out)
                    prev = v
            case _:
                encode_varuint(len(values), out)
                for v in values:
                    encode_string(v, out)

    def _read_string_vector(self, reader: Reader, codec: VectorCodec) -> list[str]:
        from .model import VectorCodec

        match codec:
            case VectorCodec.DICTIONARY:
                dict_n = reader.read_varuint()
                dct = [reader.read_string() for _ in range(dict_n)]
                refs = decode_u64_vector(reader, VectorCodec.DIRECT_BITPACK)
                out: list[str] = []
                for r in refs:
                    if r >= len(dct):
                        raise invalid_data("dictionary reference")
                    out.append(dct[r])
                return out
            case VectorCodec.STRING_REF:
                n = reader.read_count()
                out = []
                for _ in range(n):
                    sid = reader.read_varuint()
                    s, ok = self.state.string_table.get_value(sid)
                    if not ok:
                        raise self._reference_error("string_id", sid)
                    out.append(s)
                return out
            case VectorCodec.PREFIX_DELTA:
                n = reader.read_count()
                out = []
                prev = ""
                for _ in range(n):
                    prefix = reader.read_varuint()
                    suffix = reader.read_string()
                    if prefix > len(prev):
                        raise invalid_data("prefix delta in string vector")
                    out.append(prev[:prefix] + suffix)
                    prev = out[-1]
                return out
            case _:
                n = reader.read_count()
                return [reader.read_string() for _ in range(n)]

    def _write_schema_fields(
        self,
        schema: Schema,
        presence: list[bool],
        has_presence: bool,
        fields: list[Value],
        out: bytearray,
    ) -> None:
        indices = schema_present_field_indices(schema, presence, has_presence)
        for i in indices:
            if i >= len(fields):
                raise invalid_data("schema fields length mismatch")
            self._write_schema_field_value(schema.fields[i], fields[i], out)

    def _read_schema_fields(
        self,
        schema: Schema,
        presence: list[bool],
        has_presence: bool,
        n: int,
        reader: Reader,
    ) -> list[Value]:
        indices = schema_present_field_indices(schema, presence, has_presence)
        if len(indices) != n:
            raise invalid_data("schema fields length")
        return [self._read_schema_field_value(schema.fields[i], reader) for i in indices]

    def _write_schema_field_value(self, field: SchemaField, value: Value, out: bytearray) -> None:
        lt = normalized_logical_type(field.logical_type)
        if lt == "bool" and value.kind != ValueKind.BOOL:
            raise invalid_data("schema bool field type mismatch")
        if lt in ("i64", "int64", "int") and value.kind != ValueKind.I64:
            raise invalid_data("schema i64 field type mismatch")
        if lt in ("u64", "uint64", "uint") and value.kind != ValueKind.U64:
            raise invalid_data("schema u64 field type mismatch")
        if lt in ("f64", "float64", "float") and value.kind != ValueKind.F64:
            raise invalid_data("schema f64 field type mismatch")
        if lt == "string":
            if value.kind != ValueKind.STRING:
                raise invalid_data("schema string field type mismatch")
            self._write_value_with_field(value, field.name, out)
            return
        self._write_value(value, out)

    def _read_schema_field_value(self, field: SchemaField, reader: Reader) -> Value:
        if normalized_logical_type(field.logical_type) == "string":
            return self._read_value_with_field(reader, field.name)
        return self._read_value(reader)

    def _apply_state_patch(
        self,
        base_ref: BaseRef,
        operations: list[PatchOperation],
        literals: list[Value],
    ) -> Message:
        _ = literals
        if base_ref.previous:
            if self.state.previous_message is None:
                raise self._reference_error("previous", 0)
            base = self.state.previous_message.clone()
        else:
            snap, ok = get_base_snapshot(self.state, base_ref.base_id)
            if not ok or snap is None:
                raise self._reference_error("base_id", base_ref.base_id)
            base = snap
        fields = message_fields(base)
        for op in operations:
            idx = op.field_id
            match op.opcode:
                case PatchOpcode.KEEP:
                    pass
                case (
                    PatchOpcode.REPLACE_SCALAR
                    | PatchOpcode.REPLACE_VECTOR
                    | PatchOpcode.INSERT_FIELD
                    | PatchOpcode.STRING_REF
                    | PatchOpcode.PREFIX_DELTA
                ):
                    if op.value is None:
                        raise invalid_data("patch operation missing value")
                    if idx < len(fields):
                        fields[idx] = op.value.clone()
                    elif idx == len(fields):
                        fields.append(op.value.clone())
                    else:
                        raise invalid_data("patch field index out of range")
                case PatchOpcode.DELETE_FIELD:
                    if idx < 0 or idx >= len(fields):
                        raise invalid_data("delete field index out of range")
                    del fields[idx]
                case PatchOpcode.APPEND_VECTOR:
                    if op.value is None or idx < 0 or idx >= len(fields):
                        raise invalid_data("append vector patch invalid")
                    if fields[idx].kind != ValueKind.ARRAY or op.value.kind != ValueKind.ARRAY:
                        raise invalid_data("append vector requires arrays")
                    fields[idx].arr.extend(op.value.arr)
                case PatchOpcode.TRUNCATE_VECTOR:
                    if op.value is None or idx < 0 or idx >= len(fields):
                        raise invalid_data("truncate vector patch invalid")
                    if fields[idx].kind != ValueKind.ARRAY or op.value.kind != ValueKind.U64:
                        raise invalid_data("truncate vector requires array and u64")
                    n = op.value.u64
                    if n > len(fields[idx].arr):
                        raise invalid_data("truncate length")
                    fields[idx].arr = fields[idx].arr[:n]
        return rebuild_message_like(base, fields)

    def _observe_decode_shape_candidate(self, keys: list[str]) -> None:
        if self.state.shape_table.get_id(keys)[1]:
            return
        observed = self.state.shape_table.observe(keys)
        if should_register_shape(keys, observed):
            self.state.shape_table.register(keys)

    def _observe_encode_shape_candidate(self, keys: list[str]) -> int:
        sk = shape_key(keys)
        self.state.encode_shape_observations[sk] = (
            self.state.encode_shape_observations.get(sk, 0) + 1
        )
        count = self.state.encode_shape_observations[sk]
        if should_register_shape(keys, count):
            self.state.shape_table.register(keys)
        return count


class SessionEncoder:
    def __init__(self, options: SessionOptions | None = None) -> None:
        opts = options if options is not None else default_session_options()
        self.codec = TwilicCodec(new_session_state_with_options(opts))

    def encode(self, value: Value) -> bytes:
        msg = self.codec._message_for_value(value)
        if (
            self.codec.state.options.enable_state_patch
            and self.codec.state.previous_message is not None
            and supports_state_patch(self.codec.state.previous_message, msg)
        ):
            ops, _ = diff_message(self.codec.state.previous_message, msg)
            patch_msg = Message(
                kind=MessageKind.STATE_PATCH,
                state_patch=StatePatchMessage(base_ref=base_ref_previous(), operations=ops),
            )
            if encoded_size(patch_msg) < encoded_size(msg):
                try:
                    return self.codec.encode_message(patch_msg)
                except Exception:
                    pass
        return self.codec.encode_message(msg)

    def encode_with_schema(self, schema: Schema, value: Value) -> bytes:
        self.codec.state.schemas[schema.schema_id] = schema
        self.codec.state.last_schema_id = schema.schema_id
        for f in schema.fields:
            if f.enum_values:
                self.codec.state.field_enums[f.name] = list(f.enum_values)
        if value.kind != ValueKind.MAP:
            raise invalid_data("encode_with_schema expects map value")
        presence: list[bool] = []
        fields: list[Value] = []
        has_presence = False
        for f in schema.fields:
            v = lookup_map_field(value, f.name)
            if v is not None:
                presence.append(True)
                fields.append(v.clone())
            else:
                presence.append(False)
                has_presence = True
        msg = Message(
            kind=MessageKind.SCHEMA_OBJECT,
            schema_object=SchemaObjectMessage(
                schema_id=schema.schema_id,
                presence=presence,
                has_presence=has_presence,
                fields=fields,
            ),
        )
        return self.codec.encode_message(msg)

    def encode_batch(self, values: list[Value]) -> bytes:
        if not values:
            msg = Message(kind=MessageKind.ROW_BATCH, row_batch=RowBatchMessage(rows=[]))
            return self.codec.encode_message(msg)
        if len(values) >= 16:
            cols = columns_from_map_values(values)
            if cols is None:
                cols = rows_to_columns(rows_from_values(values))
            if self.codec.state.options.enable_trained_dictionary:
                apply_dictionary_references(self.codec.state, cols)
            msg = Message(
                kind=MessageKind.COLUMN_BATCH,
                column_batch=ColumnBatchMessage(count=len(values), columns=cols),
            )
        else:
            msg = Message(
                kind=MessageKind.ROW_BATCH,
                row_batch=RowBatchMessage(rows=rows_from_values(values)),
            )
        data = self.codec.encode_message(msg)
        self.codec.state.previous_message = msg
        self.codec.state.previous_message_size = len(data)
        self._record_full_message_as_base()
        return data

    def encode_patch(self, value: Value) -> bytes:
        msg = self.codec._message_for_value(value)
        if self.codec.state.previous_message is None or not supports_state_patch(
            self.codec.state.previous_message, msg
        ):
            return self.codec.encode_message(msg)
        ops, _ = diff_message(self.codec.state.previous_message, msg)
        patch_msg = Message(
            kind=MessageKind.STATE_PATCH,
            state_patch=StatePatchMessage(base_ref=base_ref_previous(), operations=ops),
        )
        if encoded_size(patch_msg) >= encoded_size(msg):
            return self.codec.encode_message(msg)
        return self.codec.encode_message(patch_msg)

    def encode_micro_batch(self, values: list[Value]) -> bytes:
        if not values:
            return self.encode_batch(values)
        if not self.codec.state.options.enable_template_batch or not has_uniform_micro_batch_shape(
            values
        ):
            return self.encode_batch(values)
        columns = columns_from_map_values(values)
        if columns is None:
            columns = rows_to_columns(rows_from_values(values))
        if self.codec.state.options.enable_trained_dictionary:
            apply_dictionary_references(self.codec.state, columns)
        template_id, ok = find_template_id(self.codec.state.templates, columns)
        if not ok:
            template_id = allocate_template_id(self.codec.state)
            self.codec.state.templates[template_id] = template_descriptor_from_columns(
                template_id, columns
            )
            self.codec.state.template_columns[template_id] = columns
            mask = [True] * len(columns)
            msg = Message(
                kind=MessageKind.TEMPLATE_BATCH,
                template_batch=TemplateBatchMessage(
                    template_id=template_id,
                    count=len(values),
                    changed_column_mask=mask,
                    columns=columns,
                ),
            )
            return self.codec.encode_message(msg)
        mask, changed_cols = diff_template_columns(
            self.codec.state.template_columns[template_id], columns
        )
        self.codec.state.template_columns[template_id] = columns
        msg = Message(
            kind=MessageKind.TEMPLATE_BATCH,
            template_batch=TemplateBatchMessage(
                template_id=template_id,
                count=len(values),
                changed_column_mask=mask,
                columns=changed_cols,
            ),
        )
        return self.codec.encode_message(msg)

    def reset(self) -> None:
        reset_state(self.codec.state)

    def decode_message(self, data: bytes) -> Message:
        return self.codec.decode_message(data)

    def _record_full_message_as_base(self) -> None:
        if self.codec.state.options.max_base_snapshots == 0:
            return
        if self.codec.state.previous_message is None:
            return
        base_id = allocate_base_id(self.codec.state)
        register_base_snapshot(self.codec.state, base_id, self.codec.state.previous_message)


def new_twilic_codec() -> TwilicCodec:
    return TwilicCodec()


def twilic_codec_with_options(options: SessionOptions) -> TwilicCodec:
    return TwilicCodec(new_session_state_with_options(options))


def new_session_encoder(options: SessionOptions | None = None) -> SessionEncoder:
    return SessionEncoder(options)


def reset_encode_shape_observation(codec: TwilicCodec, keys: list[str]) -> None:
    codec.state.encode_shape_observations.pop(shape_key(keys), None)


def typed_vector_len(data: TypedVectorData) -> int:
    match data.kind:
        case ElementType.BOOL:
            return len(data.bools)
        case ElementType.I64:
            return len(data.i64s)
        case ElementType.U64:
            return len(data.u64s)
        case ElementType.F64:
            return len(data.f64s)
        case ElementType.STRING:
            return len(data.strings)
        case ElementType.BINARY:
            return len(data.binary)
        case ElementType.VALUE:
            return len(data.values)
        case _:
            return 0


def lookup_map_field(value: Value, key: str) -> Value | None:
    if value.kind != ValueKind.MAP:
        return None
    for e in value.map:
        if e.key == key:
            return e.value.clone()
    return None


def schema_present_field_indices(
    schema: Schema, presence: list[bool], has_presence: bool
) -> list[int]:
    if not has_presence:
        return list(range(len(schema.fields)))
    if len(presence) != len(schema.fields):
        raise invalid_data("presence bitmap mismatch for schema")
    return [i for i in range(len(schema.fields)) if presence[i]]


def normalized_logical_type(raw: str) -> str:
    return raw.strip().lower()


def rows_from_values(values: list[Value]) -> list[list[Value]]:
    rows: list[list[Value]] = []
    for v in values:
        if v.kind == ValueKind.ARRAY:
            rows.append([x.clone() for x in v.arr])
        else:
            rows.append([v.clone()])
    return rows


def column_null_strategy(
    values: list[Value], present_bits: list[bool]
) -> tuple[NullStrategy, list[bool] | None, bool]:
    null_count = sum(1 for v in values if v.kind == ValueKind.NULL)
    optional_count = len(values)
    if null_count == 0:
        return NullStrategy.ALL_PRESENT_ELIDED, None, False
    if null_count <= optional_count // 4:
        inverted = [not b for b in present_bits]
        return NullStrategy.INVERTED_PRESENCE_BITMAP, inverted, True
    return NullStrategy.PRESENCE_BITMAP, list(present_bits), True


def strip_nulls(values: list[Value]) -> list[Value]:
    return [v for v in values if v.kind != ValueKind.NULL]


def columns_from_map_values(values: list[Value]) -> list[Column] | None:
    if not values:
        return None
    if any(v.kind != ValueKind.MAP for v in values):
        return None
    key_order: list[str] = []
    key_index: dict[str, int] = {}
    column_values: list[list[Value]] = []
    column_presence: list[list[bool]] = []
    for row_idx, row in enumerate(values):
        present = [False] * len(key_order)
        for e in row.map:
            key = e.key
            entry_value = e.value.clone()
            col_idx = key_index.get(key)
            if col_idx is None:
                col_idx = len(key_order)
                key_order.append(key)
                key_index[key] = col_idx
                column_values.append([new_null()] * row_idx)
                column_presence.append([False] * row_idx)
                present.append(False)
            column_values[col_idx].append(entry_value)
            column_presence[col_idx].append(True)
            present[col_idx] = True
        for col_idx in range(len(key_order)):
            if not present[col_idx]:
                column_values[col_idx].append(new_null())
                column_presence[col_idx].append(False)
    columns: list[Column] = []
    for field_id in range(len(key_order)):
        col_values = column_values[field_id]
        present_bits = column_presence[field_id]
        null_strategy, presence, has_presence = column_null_strategy(col_values, present_bits)
        codec, tvd = infer_column_codec_and_values(strip_nulls(col_values))
        columns.append(
            Column(
                field_id=field_id,
                null_strategy=null_strategy,
                presence=presence or [],
                has_presence=has_presence,
                codec=codec,
                values=tvd,
            )
        )
    return columns


def has_uniform_micro_batch_shape(values: list[Value]) -> bool:
    if not values or values[0].kind != ValueKind.MAP:
        return False
    keys = [e.key for e in values[0].map]
    for v in values[1:]:
        if v.kind != ValueKind.MAP or len(v.map) != len(keys):
            return False
        for j, key in enumerate(keys):
            if v.map[j].key != key:
                return False
    return True


def should_register_shape(keys: list[str], observed_count: int) -> bool:
    return len(keys) > 0 and observed_count >= 2


def supports_state_patch(base: Message | None, current: Message) -> bool:
    if base is None:
        return False
    return base.kind == current.kind and base.kind in (
        MessageKind.MAP,
        MessageKind.SCHEMA_OBJECT,
        MessageKind.SHAPED_OBJECT,
        MessageKind.ARRAY,
    )


def encoded_size(message: Message) -> int:
    return estimate_message_size(message)


def typed_vector_to_value(vector: TypedVector) -> Value:
    from .model import new_bool, new_f64, new_i64, new_string, new_u64

    match vector.element_type:
        case ElementType.BOOL:
            return new_array([new_bool(b) for b in vector.data.bools])
        case ElementType.I64:
            return new_array([new_i64(v) for v in vector.data.i64s])
        case ElementType.U64:
            return new_array([new_u64(v) for v in vector.data.u64s])
        case ElementType.F64:
            return new_array([new_f64(v) for v in vector.data.f64s])
        case ElementType.STRING:
            return new_array([new_string(v) for v in vector.data.strings])
        case _:
            return new_array([])


def entries_to_map(entries: list[MessageMapEntry], state: SessionState) -> list[MapEntry]:
    out: list[MapEntry] = []
    for e in entries:
        key = key_ref_string(e.key, state)
        out.append(MapEntry(key=key, value=e.value.clone()))
        if not state.key_table.get_id(key)[1]:
            state.key_table.register(key)
    return out


def key_ref_string(key: KeyRef, state: SessionState) -> str:
    if key.is_id:
        s, ok = state.key_table.get_value(key.id)
        return s if ok else ""
    return key.literal


def key_ref_field_identity(key: KeyRef, state: SessionState) -> str | None:
    s = key_ref_string(key, state)
    return s if s else None


def shape_values_to_map(
    keys: list[str], presence: list[bool], has_presence: bool, values: list[Value]
) -> list[MapEntry]:
    out: list[MapEntry] = []
    idx = 0
    for i, key in enumerate(keys):
        if has_presence and i < len(presence) and not presence[i]:
            continue
        if idx >= len(values):
            break
        out.append(entry(key, values[idx].clone()))
        idx += 1
    return out


def rows_to_columns(rows: list[list[Value]]) -> list[Column]:
    if not rows:
        return []
    width = max(len(r) for r in rows)
    column_values: list[list[Value]] = [[] for _ in range(width)]
    column_presence: list[list[bool]] = [[] for _ in range(width)]
    for row in rows:
        for col in range(width):
            value = row[col].clone() if col < len(row) else new_null()
            column_values[col].append(value)
            column_presence[col].append(value.kind != ValueKind.NULL)
    cols: list[Column] = []
    for col in range(width):
        null_strategy, presence, has_presence = column_null_strategy(
            column_values[col], column_presence[col]
        )
        codec, tvd = infer_column_codec_and_values(strip_nulls(column_values[col]))
        cols.append(
            Column(
                field_id=col,
                null_strategy=null_strategy,
                presence=presence or [],
                has_presence=has_presence,
                codec=codec,
                values=tvd,
            )
        )
    return cols


def infer_column_codec_and_values(values: list[Value]) -> tuple[VectorCodec, TypedVectorData]:
    from .model import VectorCodec

    if not values:
        return VectorCodec.PLAIN, TypedVectorData(kind=ElementType.VALUE, values=[])
    kinds = {v.kind for v in values}
    if kinds == {ValueKind.I64}:
        data = [v.i64 for v in values]
        return select_integer_codec(data), TypedVectorData(kind=ElementType.I64, i64s=data)
    if kinds == {ValueKind.U64}:
        data = [v.u64 for v in values]
        return select_u64_codec(data), TypedVectorData(kind=ElementType.U64, u64s=data)
    if kinds == {ValueKind.F64}:
        data = [v.f64 for v in values]
        return select_float_codec(data), TypedVectorData(kind=ElementType.F64, f64s=data)
    if kinds == {ValueKind.BOOL}:
        data = [v.bool for v in values]
        return VectorCodec.DIRECT_BITPACK, TypedVectorData(kind=ElementType.BOOL, bools=data)
    if kinds == {ValueKind.STRING}:
        data = [v.str for v in values]
        return select_string_codec(data), TypedVectorData(kind=ElementType.STRING, strings=data)
    data = [v.clone() for v in values]
    return VectorCodec.PLAIN, TypedVectorData(kind=ElementType.VALUE, values=data)


def select_integer_codec(values: list[int]) -> VectorCodec:
    from .model import VectorCodec

    if len(values) < 4:
        return VectorCodec.PLAIN
    delta_vals = deltas(values)
    dd = deltas(delta_vals)
    non_zero_dd = sum(1 for i in range(1, len(dd)) if dd[i] != 0)
    non_zero_ratio = non_zero_dd / (len(dd) - 1) if len(dd) > 1 else 0.0
    delta_min, delta_max = min(delta_vals), max(delta_vals)
    delta_range_bits = bit_width_signed(delta_min, delta_max)
    if len(values) >= 8 and (non_zero_ratio <= 0.25 or delta_range_bits <= 2):
        return VectorCodec.DELTA_DELTA_BITPACK
    repeated_ratio, avg_run = run_stats(values)
    if repeated_ratio >= 0.5 and avg_run >= 3.0:
        return VectorCodec.RLE
    plain_bits = 64
    min_v, max_v = min(values), max(values)
    range_bits = bit_width_signed(min_v, max_v)
    if range_bits <= plain_bits - 4:
        return VectorCodec.FOR_BITPACK
    monotonic = all(values[i] >= values[i - 1] for i in range(1, len(values)))
    if len(values) >= 8 and monotonic and delta_range_bits <= range_bits - 3:
        return VectorCodec.DELTA_FOR_BITPACK
    max_abs_delta_bits = max(bit_width_u64(abs64(v)) for v in delta_vals)
    if max_abs_delta_bits <= plain_bits - 3:
        return VectorCodec.DELTA_BITPACK
    max_bit_width = max(bit_width_u64(abs64(v)) for v in values)
    if len(values) >= 8 and max_bit_width <= 16 and not monotonic:
        return VectorCodec.SIMPLE8B
    if max_bit_width < 64:
        return VectorCodec.DIRECT_BITPACK
    return VectorCodec.PLAIN


def select_u64_codec(values: list[int]) -> VectorCodec:
    from .model import VectorCodec

    all_signed = all(v <= 0x7FFFFFFFFFFFFFFF for v in values)
    if all_signed:
        signed = [v for v in values]
        chosen = select_integer_codec(signed)
        if chosen in (
            VectorCodec.RLE,
            VectorCodec.FOR_BITPACK,
            VectorCodec.SIMPLE8B,
            VectorCodec.DIRECT_BITPACK,
            VectorCodec.PLAIN,
        ):
            return chosen
        return VectorCodec.DIRECT_BITPACK
    if len(values) < 4:
        return VectorCodec.DIRECT_BITPACK
    repeated_ratio, avg_run = run_stats_u64(values)
    if repeated_ratio >= 0.5 and avg_run >= 3.0:
        return VectorCodec.RLE
    min_v, max_v = min(values), max(values)
    range_bits = bit_width_u64(max_v - min_v)
    if range_bits <= 60:
        return VectorCodec.FOR_BITPACK
    max_width = max(bit_width_u64(v) for v in values)
    if len(values) >= 8 and max_width <= 16:
        return VectorCodec.SIMPLE8B
    if max_width < 64:
        return VectorCodec.DIRECT_BITPACK
    return VectorCodec.PLAIN


def deltas(values: list[int]) -> list[int]:
    out: list[int] = []
    for i, value in enumerate(values):
        out.append(value if i == 0 else value - values[i - 1])
    return out


def run_stats(values: list[int]) -> tuple[float, float]:
    if not values:
        return 0.0, 0.0
    run_len = 1
    runs: list[int] = []
    for i in range(1, len(values)):
        if values[i] == values[i - 1]:
            run_len += 1
        else:
            runs.append(run_len)
            run_len = 1
    runs.append(run_len)
    repeated_items = sum(r for r in runs if r > 1)
    repeated_ratio = repeated_items / len(values)
    avg_run = sum(runs) / len(runs)
    return repeated_ratio, avg_run


def run_stats_u64(values: list[int]) -> tuple[float, float]:
    return run_stats(values)


def bit_width_signed(min_v: int, max_v: int) -> int:
    range_val = max_v - min_v if min_v <= max_v else min_v - max_v
    return bit_width_u64(range_val)


def bit_width_u64(v: int) -> int:
    if v == 0:
        return 1
    return v.bit_length()


def abs64(v: int) -> int:
    return -v if v < 0 else v


def select_float_codec(values: list[float]) -> VectorCodec:
    from .model import VectorCodec

    if len(values) < 4:
        return VectorCodec.PLAIN
    prev = struct.unpack("<Q", struct.pack("<d", values[0]))[0]
    changes = 0
    for i in range(1, len(values)):
        cur = struct.unpack("<Q", struct.pack("<d", values[i]))[0]
        if cur != prev:
            changes += 1
        prev = cur
    if changes * 2 <= len(values):
        return VectorCodec.XOR_FLOAT
    return VectorCodec.PLAIN


def select_string_codec(values: list[str]) -> VectorCodec:
    from .model import VectorCodec

    if not values:
        return VectorCodec.PLAIN
    uniq = set(values)
    if len(uniq) * 2 <= len(values):
        return VectorCodec.DICTIONARY
    prefix_gain = 0
    prev = ""
    for v in values:
        prefix_gain += common_prefix_len(prev.encode(), v.encode())
        prev = v
    if prefix_gain > len(values) * 2:
        return VectorCodec.PREFIX_DELTA
    return VectorCodec.PLAIN


def write_smallest_u64(value: int, out: bytearray) -> None:
    if value <= 0xFF:
        out.extend([1, value])
    elif value <= 0xFFFF:
        out.extend([2, value & 0xFF, (value >> 8) & 0xFF])
    elif value <= 0xFFFFFFFF:
        out.extend(
            [4, value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF]
        )
    else:
        out.append(8)
        append_u64_le(out, value)


def read_smallest_u64(reader: Reader) -> int:
    size = reader.read_u8()
    match size:
        case 1:
            return reader.read_u8()
        case 2:
            b = reader.read_exact(2)
            return b[0] | (b[1] << 8)
        case 4:
            b = reader.read_exact(4)
            return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
        case 8:
            from .wire import read_u64_le

            return read_u64_le(reader)
        case _:
            raise invalid_data("smallest u64 size")


def rle_encode_bytes(input_data: bytes) -> bytes:
    if not input_data:
        return b""
    out = bytearray()
    i = 0
    while i < len(input_data):
        j = i + 1
        while j < len(input_data) and input_data[j] == input_data[i] and j - i < 255:
            j += 1
        out.extend([j - i, input_data[i]])
        i = j
    return bytes(out)


def rle_decode_bytes(input_data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(input_data):
        if i + 1 >= len(input_data):
            raise invalid_data("rle payload")
        run = input_data[i]
        b = input_data[i + 1]
        out.extend([b] * run)
        i += 2
    return bytes(out)


def control_bitpack_encode_bytes(input_data: bytes) -> bytes:
    return bytes(input_data)


def control_bitpack_decode_bytes(input_data: bytes) -> bytes:
    return bytes(input_data)


def control_huffman_encode_bytes(input_data: bytes) -> bytes:
    return bytes(input_data)


def control_huffman_decode_bytes(input_data: bytes) -> bytes:
    return bytes(input_data)


def control_fse_encode_bytes(input_data: bytes) -> bytes:
    return bytes(input_data)


def control_fse_decode_bytes(input_data: bytes) -> bytes:
    return bytes(input_data)


def common_prefix_len(a: bytes, b: bytes) -> int:
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return n


def template_descriptor_from_columns(template_id: int, columns: list[Column]) -> TemplateDescriptor:
    return TemplateDescriptor(
        template_id=template_id,
        field_ids=[c.field_id for c in columns],
        null_strategies=[c.null_strategy for c in columns],
        codecs=[c.codec for c in columns],
    )


def find_template_id(
    templates: dict[int, TemplateDescriptor], columns: list[Column]
) -> tuple[int, bool]:
    for tid in sorted(templates):
        t = templates[tid]
        if len(t.field_ids) != len(columns):
            continue
        if all(
            t.field_ids[i] == columns[i].field_id
            and t.null_strategies[i] == columns[i].null_strategy
            for i in range(len(columns))
        ):
            return tid, True
    return 0, False


def diff_template_columns(
    previous: list[Column], current: list[Column]
) -> tuple[list[bool], list[Column]]:
    mask: list[bool] = []
    changed: list[Column] = []
    for i, col in enumerate(current):
        if i >= len(previous) or estimate_column_size(previous[i]) != estimate_column_size(col):
            mask.append(True)
            changed.append(col)
        else:
            mask.append(False)
    return mask, changed


def merge_template_columns(
    previous: list[Column], changed_mask: list[bool], changed: list[Column]
) -> list[Column]:
    out: list[Column] = []
    idx = 0
    for i, bit in enumerate(changed_mask):
        if bit:
            if idx >= len(changed):
                raise invalid_data("template changed column count mismatch")
            out.append(changed[idx])
            idx += 1
        else:
            if i >= len(previous):
                raise invalid_data("template reference out of range")
            out.append(previous[i])
    return out


def diff_message(prev: Message, current: Message) -> tuple[list[PatchOperation], int]:
    a = message_fields(prev)
    b = message_fields(current)
    n = max(len(a), len(b))
    ops: list[PatchOperation] = []
    for i in range(n):
        if i < len(a) and i < len(b):
            if equal(a[i], b[i]):
                ops.append(PatchOperation(field_id=i, opcode=PatchOpcode.KEEP))
            else:
                v = b[i].clone()
                ops.append(PatchOperation(field_id=i, opcode=PatchOpcode.REPLACE_SCALAR, value=v))
        elif i < len(b):
            v = b[i].clone()
            ops.append(PatchOperation(field_id=i, opcode=PatchOpcode.INSERT_FIELD, value=v))
        else:
            ops.append(PatchOperation(field_id=i, opcode=PatchOpcode.DELETE_FIELD))
    return ops, 0


def message_fields(message: Message) -> list[Value]:
    match message.kind:
        case MessageKind.ARRAY:
            return [v.clone() for v in message.array]
        case MessageKind.MAP:
            return [e.value.clone() for e in message.map]
        case MessageKind.SHAPED_OBJECT:
            assert message.shaped_object is not None
            return [v.clone() for v in message.shaped_object.values]
        case MessageKind.SCHEMA_OBJECT:
            assert message.schema_object is not None
            return [v.clone() for v in message.schema_object.fields]
        case _:
            return []


def rebuild_message_like(base: Message, fields: list[Value]) -> Message:
    match base.kind:
        case MessageKind.ARRAY:
            return Message(kind=MessageKind.ARRAY, array=fields)
        case MessageKind.MAP:
            entries = []
            for i, v in enumerate(fields):
                if i >= len(base.map):
                    raise invalid_data("patch map shape mismatch")
                entries.append(MessageMapEntry(key=base.map[i].key, value=v))
            return Message(kind=MessageKind.MAP, map=entries)
        case MessageKind.SHAPED_OBJECT:
            assert base.shaped_object is not None
            return Message(
                kind=MessageKind.SHAPED_OBJECT,
                shaped_object=ShapedObjectMessage(
                    shape_id=base.shaped_object.shape_id,
                    presence=list(base.shaped_object.presence),
                    has_presence=base.shaped_object.has_presence,
                    values=fields,
                ),
            )
        case MessageKind.SCHEMA_OBJECT:
            assert base.schema_object is not None
            return Message(
                kind=MessageKind.SCHEMA_OBJECT,
                schema_object=SchemaObjectMessage(
                    schema_id=base.schema_object.schema_id,
                    presence=list(base.schema_object.presence),
                    has_presence=base.schema_object.has_presence,
                    fields=fields,
                ),
            )
        case _:
            raise invalid_data("state patch reconstruction unsupported for this message kind")


def estimate_message_size(message: Message) -> int:
    match message.kind:
        case MessageKind.SCALAR:
            assert message.scalar is not None
            return 1 + estimate_value_size(message.scalar)
        case MessageKind.ARRAY:
            return (
                1
                + varuint_size(len(message.array))
                + sum(estimate_value_size(v) for v in message.array)
            )
        case MessageKind.MAP:
            return (
                1
                + varuint_size(len(message.map))
                + sum(
                    encoded_key_ref_size(e.key) + estimate_value_size(e.value) for e in message.map
                )
            )
        case MessageKind.STATE_PATCH:
            assert message.state_patch is not None
            sp = message.state_patch
            total = 1 + 2 + varuint_size(len(sp.operations))
            for op in sp.operations:
                total += varuint_size(op.field_id) + 2
                if op.value is not None:
                    total += estimate_value_size(op.value)
            return total
        case _:
            return 16


def estimate_column_size(column: Column) -> int:
    size = varuint_size(column.field_id) + 4
    match column.values.kind:
        case ElementType.BOOL:
            size += len(column.values.bools) // 8 + 2
        case ElementType.I64:
            size += len(column.values.i64s) * 4
        case ElementType.U64:
            size += len(column.values.u64s) * 4
        case ElementType.F64:
            size += len(column.values.f64s) * 8
        case ElementType.STRING:
            size += sum(encoded_string_size(s) for s in column.values.strings)
    return size


def estimate_value_size(value: Value) -> int:
    match value.kind:
        case ValueKind.NULL | ValueKind.BOOL:
            return 1
        case ValueKind.I64:
            from .wire import encode_zigzag

            return 2 + smallest_u64_size(encode_zigzag(value.i64))
        case ValueKind.U64:
            return 2 + smallest_u64_size(value.u64)
        case ValueKind.F64:
            return 9
        case ValueKind.STRING:
            return 2 + encoded_string_size(value.str)
        case ValueKind.BINARY:
            return 1 + encoded_bytes_size(len(value.bin))
        case ValueKind.ARRAY:
            return 1 + varuint_size(len(value.arr)) + sum(estimate_value_size(v) for v in value.arr)
        case ValueKind.MAP:
            return (
                1
                + varuint_size(len(value.map))
                + sum(encoded_string_size(e.key) + estimate_value_size(e.value) for e in value.map)
            )
        case _:
            return 1


def encoded_bytes_size(length: int) -> int:
    return varuint_size(length) + length


def encoded_string_size(value: str) -> int:
    return encoded_bytes_size(len(value.encode()))


def encoded_key_ref_size(key: KeyRef) -> int:
    if key.is_id:
        return 1 + varuint_size(key.id)
    return encoded_string_size(key.literal)


def varuint_size(value: int) -> int:
    sz = 1
    while value >= 0x80:
        value >>= 7
        sz += 1
    return sz


def smallest_u64_size(value: int) -> int:
    if value <= 0xFF:
        return 1
    if value <= 0xFFFF:
        return 2
    if value <= 0xFFFFFFFF:
        return 4
    return 8
