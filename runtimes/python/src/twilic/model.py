"""Twilic data model types."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum

# Conceptual dynamic value type for documentation / future use
type DynamicValue = (
    None | bool | int | float | str | bytes | list["DynamicValue"] | dict[str, "DynamicValue"]
)


class MessageKind(IntEnum):
    SCALAR = 0x00
    ARRAY = 0x01
    MAP = 0x02
    SHAPED_OBJECT = 0x03
    SCHEMA_OBJECT = 0x04
    TYPED_VECTOR = 0x05
    ROW_BATCH = 0x06
    COLUMN_BATCH = 0x07
    CONTROL = 0x08
    EXT = 0x09
    STATE_PATCH = 0x0A
    TEMPLATE_BATCH = 0x0B
    CONTROL_STREAM = 0x0C
    BASE_SNAPSHOT = 0x0D


MessageKindScalar = MessageKind.SCALAR
MessageKindArray = MessageKind.ARRAY
MessageKindMap = MessageKind.MAP
MessageKindShapedObject = MessageKind.SHAPED_OBJECT
MessageKindSchemaObject = MessageKind.SCHEMA_OBJECT
MessageKindTypedVector = MessageKind.TYPED_VECTOR
MessageKindRowBatch = MessageKind.ROW_BATCH
MessageKindColumnBatch = MessageKind.COLUMN_BATCH
MessageKindControl = MessageKind.CONTROL
MessageKindExt = MessageKind.EXT
MessageKindStatePatch = MessageKind.STATE_PATCH
MessageKindTemplateBatch = MessageKind.TEMPLATE_BATCH
MessageKindControlStream = MessageKind.CONTROL_STREAM
MessageKindBaseSnapshot = MessageKind.BASE_SNAPSHOT


def message_kind_from_byte(b: int) -> tuple[MessageKind, bool]:
    try:
        return MessageKind(b), True
    except ValueError:
        return MessageKind(0), False


class ValueKind(IntEnum):
    NULL = 0
    BOOL = 1
    I64 = 2
    U64 = 3
    F64 = 4
    STRING = 5
    BINARY = 6
    ARRAY = 7
    MAP = 8


ValueNull = ValueKind.NULL
ValueBool = ValueKind.BOOL
ValueI64 = ValueKind.I64
ValueU64 = ValueKind.U64
ValueF64 = ValueKind.F64
ValueString = ValueKind.STRING
ValueBinary = ValueKind.BINARY
ValueArray = ValueKind.ARRAY
ValueMap = ValueKind.MAP


@dataclass
class Value:
    kind: ValueKind = ValueKind.NULL
    bool: bool = False
    i64: int = 0
    u64: int = 0
    f64: float = 0.0
    str: str = ""
    bin: bytes = field(default_factory=bytes)
    arr: list[Value] = field(default_factory=list)
    map: list[MapEntry] = field(default_factory=list)

    def is_scalar(self) -> bool:
        return self.kind not in (ValueKind.ARRAY, ValueKind.MAP)

    def clone(self) -> Value:
        match self.kind:
            case (
                ValueKind.NULL
                | ValueKind.BOOL
                | ValueKind.I64
                | ValueKind.U64
                | ValueKind.F64
                | ValueKind.STRING
            ):
                return Value(
                    kind=self.kind,
                    bool=self.bool,
                    i64=self.i64,
                    u64=self.u64,
                    f64=self.f64,
                    str=self.str,
                )
            case ValueKind.BINARY:
                return Value(kind=ValueKind.BINARY, bin=bytes(self.bin))
            case ValueKind.ARRAY:
                return Value(kind=ValueKind.ARRAY, arr=[v.clone() for v in self.arr])
            case ValueKind.MAP:
                return Value(
                    kind=ValueKind.MAP,
                    map=[MapEntry(key=e.key, value=e.value.clone()) for e in self.map],
                )
            case _:
                return Value()


@dataclass
class MapEntry:
    key: str
    value: Value


@dataclass
class MessageMapEntry:
    key: KeyRef
    value: Value


def new_null() -> Value:
    return Value(kind=ValueKind.NULL)


def new_bool(b: bool) -> Value:
    return Value(kind=ValueKind.BOOL, bool=b)


def new_i64(n: int) -> Value:
    return Value(kind=ValueKind.I64, i64=n)


def new_u64(n: int) -> Value:
    return Value(kind=ValueKind.U64, u64=n)


def new_f64(n: float) -> Value:
    return Value(kind=ValueKind.F64, f64=n)


def new_string(s: str) -> Value:
    return Value(kind=ValueKind.STRING, str=s)


def new_binary(b: bytes) -> Value:
    return Value(kind=ValueKind.BINARY, bin=bytes(b))


def new_array(items: list[Value]) -> Value:
    return Value(kind=ValueKind.ARRAY, arr=[item.clone() for item in items])


def entry(key: str, value: Value) -> MapEntry:
    return MapEntry(key=key, value=value)


def new_map(*entries: MapEntry) -> Value:
    return Value(
        kind=ValueKind.MAP,
        map=[MapEntry(key=e.key, value=e.value.clone()) for e in entries],
    )


def equal(a: Value, b: Value) -> bool:
    if a.kind != b.kind:
        return False
    match a.kind:
        case ValueKind.NULL:
            return True
        case ValueKind.BOOL:
            return a.bool == b.bool
        case ValueKind.I64:
            return a.i64 == b.i64
        case ValueKind.U64:
            return a.u64 == b.u64
        case ValueKind.F64:
            return a.f64 == b.f64
        case ValueKind.STRING:
            return a.str == b.str
        case ValueKind.BINARY:
            return a.bin == b.bin
        case ValueKind.ARRAY:
            if len(a.arr) != len(b.arr):
                return False
            return all(equal(a.arr[i], b.arr[i]) for i in range(len(a.arr)))
        case ValueKind.MAP:
            if len(a.map) != len(b.map):
                return False
            return all(
                a.map[i].key == b.map[i].key and equal(a.map[i].value, b.map[i].value)
                for i in range(len(a.map))
            )
        case _:
            return False


@dataclass
class KeyRef:
    literal: str = ""
    id: int = 0
    is_id: bool = False


def key_ref_literal(s: str) -> KeyRef:
    return KeyRef(literal=s)


def key_ref_id(ref_id: int) -> KeyRef:
    return KeyRef(id=ref_id, is_id=True)


class StringMode(IntEnum):
    EMPTY = 0
    LITERAL = 1
    REF = 2
    PREFIX_DELTA = 3
    INLINE_ENUM = 4


StringModeEmpty = StringMode.EMPTY
StringModeLiteral = StringMode.LITERAL
StringModeRef = StringMode.REF
StringModePrefixDelta = StringMode.PREFIX_DELTA
StringModeInlineEnum = StringMode.INLINE_ENUM


def string_mode_from_byte(b: int) -> tuple[StringMode, bool]:
    if 0 <= b <= 4:
        return StringMode(b), True
    return StringMode(0), False


@dataclass
class StringValue:
    mode: StringMode
    value: str = ""
    ref_id: int | None = None
    prefix_len: int | None = None


class ElementType(IntEnum):
    BOOL = 0
    I64 = 1
    U64 = 2
    F64 = 3
    STRING = 4
    BINARY = 5
    VALUE = 6


ElementTypeBool = ElementType.BOOL
ElementTypeI64 = ElementType.I64
ElementTypeU64 = ElementType.U64
ElementTypeF64 = ElementType.F64
ElementTypeString = ElementType.STRING
ElementTypeBinary = ElementType.BINARY
ElementTypeValue = ElementType.VALUE


def element_type_from_byte(b: int) -> tuple[ElementType, bool]:
    if 0 <= b <= 6:
        return ElementType(b), True
    return ElementType(0), False


class VectorCodec(IntEnum):
    PLAIN = 0
    DIRECT_BITPACK = 1
    DELTA_BITPACK = 2
    FOR_BITPACK = 3
    DELTA_FOR_BITPACK = 4
    DELTA_DELTA_BITPACK = 5
    RLE = 6
    PATCHED_FOR = 7
    SIMPLE8B = 8
    XOR_FLOAT = 9
    DICTIONARY = 10
    STRING_REF = 11
    PREFIX_DELTA = 12


VectorCodecPlain = VectorCodec.PLAIN
VectorCodecDirectBitpack = VectorCodec.DIRECT_BITPACK
VectorCodecDeltaBitpack = VectorCodec.DELTA_BITPACK
VectorCodecForBitpack = VectorCodec.FOR_BITPACK
VectorCodecDeltaForBitpack = VectorCodec.DELTA_FOR_BITPACK
VectorCodecDeltaDeltaBitpack = VectorCodec.DELTA_DELTA_BITPACK
VectorCodecRle = VectorCodec.RLE
VectorCodecPatchedFor = VectorCodec.PATCHED_FOR
VectorCodecSimple8b = VectorCodec.SIMPLE8B
VectorCodecXorFloat = VectorCodec.XOR_FLOAT
VectorCodecDictionary = VectorCodec.DICTIONARY
VectorCodecStringRef = VectorCodec.STRING_REF
VectorCodecPrefixDelta = VectorCodec.PREFIX_DELTA


def vector_codec_from_byte(b: int) -> tuple[VectorCodec, bool]:
    if b <= 12:
        return VectorCodec(b), True
    return VectorCodec(0), False


@dataclass
class TypedVectorData:
    kind: ElementType = ElementType.BOOL
    bools: list[bool] = field(default_factory=list)
    i64s: list[int] = field(default_factory=list)
    u64s: list[int] = field(default_factory=list)
    f64s: list[float] = field(default_factory=list)
    strings: list[str] = field(default_factory=list)
    binary: list[bytes] = field(default_factory=list)
    values: list[Value] = field(default_factory=list)


@dataclass
class TypedVector:
    element_type: ElementType
    codec: VectorCodec
    data: TypedVectorData


@dataclass
class SchemaField:
    number: int
    name: str
    logical_type: str = ""
    required: bool = False
    default_value: Value | None = None
    min: int | None = None
    max: int | None = None
    enum_values: list[str] = field(default_factory=list)


@dataclass
class Schema:
    schema_id: int
    name: str
    fields: list[SchemaField]


class NullStrategy(IntEnum):
    NONE = 0
    PRESENCE_BITMAP = 1
    INVERTED_PRESENCE_BITMAP = 2
    ALL_PRESENT_ELIDED = 3


NullStrategyNone = NullStrategy.NONE
NullStrategyPresenceBitmap = NullStrategy.PRESENCE_BITMAP
NullStrategyInvertedPresenceBitmap = NullStrategy.INVERTED_PRESENCE_BITMAP
NullStrategyAllPresentElided = NullStrategy.ALL_PRESENT_ELIDED


def null_strategy_from_byte(b: int) -> tuple[NullStrategy, bool]:
    if 0 <= b <= 3:
        return NullStrategy(b), True
    return NullStrategy(0), False


@dataclass
class Column:
    field_id: int
    null_strategy: NullStrategy
    presence: list[bool] = field(default_factory=list)
    has_presence: bool = False
    codec: VectorCodec = VectorCodec.PLAIN
    dictionary_id: int | None = None
    values: TypedVectorData = field(default_factory=TypedVectorData)


class ControlOpcode(IntEnum):
    REGISTER_KEYS = 0
    REGISTER_SHAPE = 1
    REGISTER_STRINGS = 2
    PROMOTE_STRING_FIELD_TO_ENUM = 3
    RESET_TABLES = 4
    RESET_STATE = 5


ControlOpcodeRegisterKeys = ControlOpcode.REGISTER_KEYS
ControlOpcodeRegisterShape = ControlOpcode.REGISTER_SHAPE
ControlOpcodeRegisterStrings = ControlOpcode.REGISTER_STRINGS
ControlOpcodePromoteStringFieldToEnum = ControlOpcode.PROMOTE_STRING_FIELD_TO_ENUM
ControlOpcodeResetTables = ControlOpcode.RESET_TABLES
ControlOpcodeResetState = ControlOpcode.RESET_STATE


def control_opcode_from_byte(b: int) -> tuple[ControlOpcode, bool]:
    if 0 <= b <= 5:
        return ControlOpcode(b), True
    return ControlOpcode(0), False


@dataclass
class RegisterShapeControl:
    shape_id: int
    keys: list[KeyRef]


@dataclass
class PromoteEnumControl:
    field_identity: str
    values: list[str]


@dataclass
class ControlMessage:
    opcode: ControlOpcode
    register_keys: list[str] = field(default_factory=list)
    register_shape: RegisterShapeControl | None = None
    register_strings: list[str] = field(default_factory=list)
    promote_string_field_to_enum: PromoteEnumControl | None = None
    reset_tables: bool = False
    reset_state: bool = False


class PatchOpcode(IntEnum):
    KEEP = 0
    REPLACE_SCALAR = 1
    REPLACE_VECTOR = 2
    APPEND_VECTOR = 3
    TRUNCATE_VECTOR = 4
    DELETE_FIELD = 5
    INSERT_FIELD = 6
    STRING_REF = 7
    PREFIX_DELTA = 8


PatchOpcodeKeep = PatchOpcode.KEEP
PatchOpcodeReplaceScalar = PatchOpcode.REPLACE_SCALAR
PatchOpcodeReplaceVector = PatchOpcode.REPLACE_VECTOR
PatchOpcodeAppendVector = PatchOpcode.APPEND_VECTOR
PatchOpcodeTruncateVector = PatchOpcode.TRUNCATE_VECTOR
PatchOpcodeDeleteField = PatchOpcode.DELETE_FIELD
PatchOpcodeInsertField = PatchOpcode.INSERT_FIELD
PatchOpcodeStringRef = PatchOpcode.STRING_REF
PatchOpcodePrefixDelta = PatchOpcode.PREFIX_DELTA


def patch_opcode_from_byte(b: int) -> tuple[PatchOpcode, bool]:
    if b <= 8:
        return PatchOpcode(b), True
    return PatchOpcode(0), False


@dataclass
class BaseRef:
    previous: bool = False
    base_id: int = 0


def base_ref_previous() -> BaseRef:
    return BaseRef(previous=True)


def base_ref_id(ref_id: int) -> BaseRef:
    return BaseRef(base_id=ref_id)


@dataclass
class PatchOperation:
    field_id: int
    opcode: PatchOpcode
    value: Value | None = None


class ControlStreamCodec(IntEnum):
    PLAIN = 0
    RLE = 1
    BITPACK = 2
    HUFFMAN = 3
    FSE = 4


ControlStreamCodecPlain = ControlStreamCodec.PLAIN
ControlStreamCodecRle = ControlStreamCodec.RLE
ControlStreamCodecBitpack = ControlStreamCodec.BITPACK
ControlStreamCodecHuffman = ControlStreamCodec.HUFFMAN
ControlStreamCodecFse = ControlStreamCodec.FSE


def control_stream_codec_from_byte(b: int) -> tuple[ControlStreamCodec, bool]:
    if b <= 4:
        return ControlStreamCodec(b), True
    return ControlStreamCodec(0), False


@dataclass
class ShapedObjectMessage:
    shape_id: int
    values: list[Value]
    presence: list[bool] = field(default_factory=list)
    has_presence: bool = False


@dataclass
class SchemaObjectMessage:
    fields: list[Value]
    schema_id: int | None = None
    presence: list[bool] = field(default_factory=list)
    has_presence: bool = False


@dataclass
class RowBatchMessage:
    rows: list[list[Value]]


@dataclass
class ColumnBatchMessage:
    count: int
    columns: list[Column]


@dataclass
class ExtMessage:
    ext_type: int
    payload: bytes


@dataclass
class StatePatchMessage:
    base_ref: BaseRef
    operations: list[PatchOperation]
    literals: list[Value] = field(default_factory=list)


@dataclass
class TemplateBatchMessage:
    template_id: int
    count: int
    changed_column_mask: list[bool]
    columns: list[Column]


@dataclass
class ControlStreamMessage:
    codec: ControlStreamCodec
    payload: bytes


@dataclass
class BaseSnapshotMessage:
    base_id: int
    schema_or_shape_ref: int
    payload: Message


@dataclass
class TemplateDescriptor:
    template_id: int
    field_ids: list[int] = field(default_factory=list)
    null_strategies: list[NullStrategy] = field(default_factory=list)
    codecs: list[VectorCodec] = field(default_factory=list)


@dataclass
class Message:
    kind: MessageKind
    scalar: Value | None = None
    array: list[Value] = field(default_factory=list)
    map: list[MessageMapEntry] = field(default_factory=list)
    shaped_object: ShapedObjectMessage | None = None
    schema_object: SchemaObjectMessage | None = None
    typed_vector: TypedVector | None = None
    row_batch: RowBatchMessage | None = None
    column_batch: ColumnBatchMessage | None = None
    control: ControlMessage | None = None
    ext: ExtMessage | None = None
    state_patch: StatePatchMessage | None = None
    template_batch: TemplateBatchMessage | None = None
    control_stream: ControlStreamMessage | None = None
    base_snapshot: BaseSnapshotMessage | None = None

    def clone(self) -> Message:
        match self.kind:
            case MessageKind.SCALAR:
                v = self.scalar.clone() if self.scalar else new_null()
                return Message(kind=MessageKind.SCALAR, scalar=v)
            case MessageKind.ARRAY:
                return Message(
                    kind=MessageKind.ARRAY,
                    array=[v.clone() for v in self.array],
                )
            case MessageKind.MAP:
                return Message(
                    kind=MessageKind.MAP,
                    map=[MessageMapEntry(key=e.key, value=e.value.clone()) for e in self.map],
                )
            case MessageKind.SHAPED_OBJECT:
                s = self.shaped_object
                assert s is not None
                return Message(
                    kind=MessageKind.SHAPED_OBJECT,
                    shaped_object=ShapedObjectMessage(
                        shape_id=s.shape_id,
                        presence=list(s.presence) if s.has_presence else [],
                        has_presence=s.has_presence,
                        values=[v.clone() for v in s.values],
                    ),
                )
            case MessageKind.SCHEMA_OBJECT:
                s = self.schema_object
                assert s is not None
                return Message(
                    kind=MessageKind.SCHEMA_OBJECT,
                    schema_object=SchemaObjectMessage(
                        schema_id=s.schema_id,
                        presence=list(s.presence) if s.has_presence else [],
                        has_presence=s.has_presence,
                        fields=[v.clone() for v in s.fields],
                    ),
                )
            case MessageKind.TYPED_VECTOR:
                return Message(
                    kind=MessageKind.TYPED_VECTOR,
                    typed_vector=clone_typed_vector(self.typed_vector),
                )
            case MessageKind.ROW_BATCH:
                rb = self.row_batch
                assert rb is not None
                return Message(
                    kind=MessageKind.ROW_BATCH,
                    row_batch=RowBatchMessage(rows=[[v.clone() for v in row] for row in rb.rows]),
                )
            case MessageKind.COLUMN_BATCH:
                cb = self.column_batch
                assert cb is not None
                return Message(
                    kind=MessageKind.COLUMN_BATCH,
                    column_batch=ColumnBatchMessage(
                        count=cb.count,
                        columns=[clone_column(c) for c in cb.columns],
                    ),
                )
            case MessageKind.CONTROL:
                return Message(
                    kind=MessageKind.CONTROL,
                    control=clone_control(self.control),
                )
            case MessageKind.EXT:
                e = self.ext
                assert e is not None
                return Message(
                    kind=MessageKind.EXT,
                    ext=ExtMessage(ext_type=e.ext_type, payload=bytes(e.payload)),
                )
            case MessageKind.STATE_PATCH:
                sp = self.state_patch
                assert sp is not None
                ops: list[PatchOperation] = []
                for op in sp.operations:
                    cloned = PatchOperation(
                        field_id=op.field_id,
                        opcode=op.opcode,
                        value=op.value.clone() if op.value else None,
                    )
                    ops.append(cloned)
                return Message(
                    kind=MessageKind.STATE_PATCH,
                    state_patch=StatePatchMessage(
                        base_ref=sp.base_ref,
                        operations=ops,
                        literals=[v.clone() for v in sp.literals],
                    ),
                )
            case MessageKind.TEMPLATE_BATCH:
                tb = self.template_batch
                assert tb is not None
                return Message(
                    kind=MessageKind.TEMPLATE_BATCH,
                    template_batch=TemplateBatchMessage(
                        template_id=tb.template_id,
                        count=tb.count,
                        changed_column_mask=list(tb.changed_column_mask),
                        columns=[clone_column(c) for c in tb.columns],
                    ),
                )
            case MessageKind.CONTROL_STREAM:
                cs = self.control_stream
                assert cs is not None
                return Message(
                    kind=MessageKind.CONTROL_STREAM,
                    control_stream=ControlStreamMessage(codec=cs.codec, payload=bytes(cs.payload)),
                )
            case MessageKind.BASE_SNAPSHOT:
                bs = self.base_snapshot
                assert bs is not None
                return Message(
                    kind=MessageKind.BASE_SNAPSHOT,
                    base_snapshot=BaseSnapshotMessage(
                        base_id=bs.base_id,
                        schema_or_shape_ref=bs.schema_or_shape_ref,
                        payload=bs.payload.clone(),
                    ),
                )
            case _:
                return Message(kind=MessageKind.SCALAR)


def clone_typed_vector(tv: TypedVector | None) -> TypedVector | None:
    if tv is None:
        return None
    out_data = TypedVectorData(kind=tv.element_type)
    match tv.element_type:
        case ElementType.BOOL:
            out_data.bools = list(tv.data.bools)
        case ElementType.I64:
            out_data.i64s = list(tv.data.i64s)
        case ElementType.U64:
            out_data.u64s = list(tv.data.u64s)
        case ElementType.F64:
            out_data.f64s = list(tv.data.f64s)
        case ElementType.STRING:
            out_data.strings = list(tv.data.strings)
        case ElementType.BINARY:
            out_data.binary = [bytes(b) for b in tv.data.binary]
        case ElementType.VALUE:
            out_data.values = [v.clone() for v in tv.data.values]
    return TypedVector(element_type=tv.element_type, codec=tv.codec, data=out_data)


def clone_column(c: Column) -> Column:
    out = Column(
        field_id=c.field_id,
        null_strategy=c.null_strategy,
        has_presence=c.has_presence,
        codec=c.codec,
        dictionary_id=c.dictionary_id,
        values=clone_typed_vector_data(c.values),
    )
    if c.has_presence:
        out.presence = list(c.presence)
    if c.dictionary_id is not None:
        out.dictionary_id = c.dictionary_id
    return out


def clone_typed_vector_data(d: TypedVectorData) -> TypedVectorData:
    return TypedVectorData(
        kind=d.kind,
        bools=list(d.bools),
        i64s=list(d.i64s),
        u64s=list(d.u64s),
        f64s=list(d.f64s),
        strings=list(d.strings),
        binary=[bytes(b) for b in d.binary],
        values=[v.clone() for v in d.values],
    )


def clone_control(c: ControlMessage | None) -> ControlMessage | None:
    if c is None:
        return None
    out = ControlMessage(
        opcode=c.opcode,
        register_keys=list(c.register_keys),
        register_strings=list(c.register_strings),
        reset_tables=c.reset_tables,
        reset_state=c.reset_state,
    )
    if c.register_shape is not None:
        rs = c.register_shape
        out.register_shape = RegisterShapeControl(shape_id=rs.shape_id, keys=list(rs.keys))
    if c.promote_string_field_to_enum is not None:
        p = c.promote_string_field_to_enum
        out.promote_string_field_to_enum = PromoteEnumControl(
            field_identity=p.field_identity, values=list(p.values)
        )
    return out
