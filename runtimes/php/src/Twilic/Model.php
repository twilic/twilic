<?php

declare(strict_types=1);

namespace Twilic;

enum MessageKind: int
{
    case SCALAR = 0x00;
    case ARRAY = 0x01;
    case MAP = 0x02;
    case SHAPED_OBJECT = 0x03;
    case SCHEMA_OBJECT = 0x04;
    case TYPED_VECTOR = 0x05;
    case ROW_BATCH = 0x06;
    case COLUMN_BATCH = 0x07;
    case CONTROL = 0x08;
    case EXT = 0x09;
    case STATE_PATCH = 0x0A;
    case TEMPLATE_BATCH = 0x0B;
    case CONTROL_STREAM = 0x0C;
    case BASE_SNAPSHOT = 0x0D;
}

const MessageKindScalar = MessageKind::SCALAR;
const MessageKindArray = MessageKind::ARRAY;
const MessageKindMap = MessageKind::MAP;
const MessageKindShapedObject = MessageKind::SHAPED_OBJECT;
const MessageKindSchemaObject = MessageKind::SCHEMA_OBJECT;
const MessageKindTypedVector = MessageKind::TYPED_VECTOR;
const MessageKindRowBatch = MessageKind::ROW_BATCH;
const MessageKindColumnBatch = MessageKind::COLUMN_BATCH;
const MessageKindControl = MessageKind::CONTROL;
const MessageKindExt = MessageKind::EXT;
const MessageKindStatePatch = MessageKind::STATE_PATCH;
const MessageKindTemplateBatch = MessageKind::TEMPLATE_BATCH;
const MessageKindControlStream = MessageKind::CONTROL_STREAM;
const MessageKindBaseSnapshot = MessageKind::BASE_SNAPSHOT;

/** @return array{0: MessageKind, 1: bool} */
function message_kind_from_byte(int $b): array
{
    $kind = MessageKind::tryFrom($b);
    return $kind !== null ? [$kind, true] : [MessageKind::SCALAR, false];
}

enum ValueKind: int
{
    case NULL = 0;
    case BOOL = 1;
    case I64 = 2;
    case U64 = 3;
    case F64 = 4;
    case STRING = 5;
    case BINARY = 6;
    case ARRAY = 7;
    case MAP = 8;
}

const ValueNull = ValueKind::NULL;
const ValueBool = ValueKind::BOOL;
const ValueI64 = ValueKind::I64;
const ValueU64 = ValueKind::U64;
const ValueF64 = ValueKind::F64;
const ValueString = ValueKind::STRING;
const ValueBinary = ValueKind::BINARY;
const ValueArray = ValueKind::ARRAY;
const ValueMap = ValueKind::MAP;

final class Value
{
    public function __construct(
        public ValueKind $kind = ValueKind::NULL,
        public bool $bool = false,
        public int $i64 = 0,
        public int $u64 = 0,
        public float $f64 = 0.0,
        public string $str = '',
        public string $bin = '',
        /** @var list<Value> */
        public array $arr = [],
        /** @var list<MapEntry> */
        public array $map = [],
    ) {
    }

    public function isScalar(): bool
    {
        return $this->kind !== ValueKind::ARRAY && $this->kind !== ValueKind::MAP;
    }

    public function clone(): Value
    {
        return match ($this->kind) {
            ValueKind::NULL, ValueKind::BOOL, ValueKind::I64, ValueKind::U64, ValueKind::F64, ValueKind::STRING => new Value(
                kind: $this->kind,
                bool: $this->bool,
                i64: $this->i64,
                u64: $this->u64,
                f64: $this->f64,
                str: $this->str,
            ),
            ValueKind::BINARY => new Value(kind: ValueKind::BINARY, bin: $this->bin),
            ValueKind::ARRAY => new Value(
                kind: ValueKind::ARRAY,
                arr: array_map(static fn (Value $v) => $v->clone(), $this->arr),
            ),
            ValueKind::MAP => new Value(
                kind: ValueKind::MAP,
                map: array_map(
                    static fn (MapEntry $e) => new MapEntry($e->key, $e->value->clone()),
                    $this->map,
                ),
            ),
        };
    }
}

final class MapEntry
{
    public function __construct(
        public string $key,
        public Value $value,
    ) {
    }
}

final class MessageMapEntry
{
    public function __construct(
        public KeyRef $key,
        public Value $value,
    ) {
    }
}

function new_null(): Value
{
    return new Value(kind: ValueKind::NULL);
}

function new_bool(bool $b): Value
{
    return new Value(kind: ValueKind::BOOL, bool: $b);
}

function new_i64(int $n): Value
{
    return new Value(kind: ValueKind::I64, i64: $n);
}

function new_u64(int $n): Value
{
    return new Value(kind: ValueKind::U64, u64: $n);
}

function new_f64(float $n): Value
{
    return new Value(kind: ValueKind::F64, f64: $n);
}

function new_string(string $s): Value
{
    return new Value(kind: ValueKind::STRING, str: $s);
}

function new_binary(string $b): Value
{
    return new Value(kind: ValueKind::BINARY, bin: $b);
}

/** @param list<Value> $items */
function new_array(array $items): Value
{
    return new Value(
        kind: ValueKind::ARRAY,
        arr: array_map(static fn (Value $item) => $item->clone(), $items),
    );
}

function entry(string $key, Value $value): MapEntry
{
    return new MapEntry($key, $value);
}

function new_map(MapEntry ...$entries): Value
{
    return new Value(
        kind: ValueKind::MAP,
        map: array_map(
            static fn (MapEntry $e) => new MapEntry($e->key, $e->value->clone()),
            $entries,
        ),
    );
}

function equal(Value $a, Value $b): bool
{
    if ($a->kind !== $b->kind) {
        return false;
    }
    return match ($a->kind) {
        ValueKind::NULL => true,
        ValueKind::BOOL => $a->bool === $b->bool,
        ValueKind::I64 => $a->i64 === $b->i64,
        ValueKind::U64 => $a->u64 === $b->u64,
        ValueKind::F64 => $a->f64 === $b->f64,
        ValueKind::STRING => $a->str === $b->str,
        ValueKind::BINARY => $a->bin === $b->bin,
        ValueKind::ARRAY => count($a->arr) === count($b->arr)
            && array_all($a->arr, static fn (Value $v, int $i) => equal($v, $b->arr[$i])),
        ValueKind::MAP => count($a->map) === count($b->map)
            && array_all($a->map, static fn (MapEntry $e, int $i) => $e->key === $b->map[$i]->key && equal($e->value, $b->map[$i]->value)),
    };
}

/** @param array<int, mixed> $arr */
function array_all(array $arr, callable $fn): bool
{
    foreach ($arr as $i => $v) {
        if (!$fn($v, $i)) {
            return false;
        }
    }
    return true;
}

final class KeyRef
{
    public function __construct(
        public string $literal = '',
        public int $id = 0,
        public bool $isId = false,
    ) {
    }
}

function key_ref_literal(string $s): KeyRef
{
    return new KeyRef(literal: $s);
}

function key_ref_id(int $refId): KeyRef
{
    return new KeyRef(id: $refId, isId: true);
}

enum StringMode: int
{
    case EMPTY = 0;
    case LITERAL = 1;
    case REF = 2;
    case PREFIX_DELTA = 3;
    case INLINE_ENUM = 4;
}

const StringModeEmpty = StringMode::EMPTY;
const StringModeLiteral = StringMode::LITERAL;
const StringModeRef = StringMode::REF;
const StringModePrefixDelta = StringMode::PREFIX_DELTA;
const StringModeInlineEnum = StringMode::INLINE_ENUM;

/** @return array{0: StringMode, 1: bool} */
function string_mode_from_byte(int $b): array
{
    if ($b >= 0 && $b <= 4) {
        return [StringMode::from($b), true];
    }
    return [StringMode::EMPTY, false];
}

final class StringValue
{
    public function __construct(
        public StringMode $mode,
        public string $value = '',
        public ?int $refId = null,
        public ?int $prefixLen = null,
    ) {
    }
}

enum ElementType: int
{
    case BOOL = 0;
    case I64 = 1;
    case U64 = 2;
    case F64 = 3;
    case STRING = 4;
    case BINARY = 5;
    case VALUE = 6;
}

const ElementTypeBool = ElementType::BOOL;
const ElementTypeI64 = ElementType::I64;
const ElementTypeU64 = ElementType::U64;
const ElementTypeF64 = ElementType::F64;
const ElementTypeString = ElementType::STRING;
const ElementTypeBinary = ElementType::BINARY;
const ElementTypeValue = ElementType::VALUE;

/** @return array{0: ElementType, 1: bool} */
function element_type_from_byte(int $b): array
{
    if ($b >= 0 && $b <= 6) {
        return [ElementType::from($b), true];
    }
    return [ElementType::BOOL, false];
}

enum VectorCodec: int
{
    case PLAIN = 0;
    case DIRECT_BITPACK = 1;
    case DELTA_BITPACK = 2;
    case FOR_BITPACK = 3;
    case DELTA_FOR_BITPACK = 4;
    case DELTA_DELTA_BITPACK = 5;
    case RLE = 6;
    case PATCHED_FOR = 7;
    case SIMPLE8B = 8;
    case XOR_FLOAT = 9;
    case DICTIONARY = 10;
    case STRING_REF = 11;
    case PREFIX_DELTA = 12;
}

const VectorCodecPlain = VectorCodec::PLAIN;
const VectorCodecDirectBitpack = VectorCodec::DIRECT_BITPACK;
const VectorCodecDeltaBitpack = VectorCodec::DELTA_BITPACK;
const VectorCodecForBitpack = VectorCodec::FOR_BITPACK;
const VectorCodecDeltaForBitpack = VectorCodec::DELTA_FOR_BITPACK;
const VectorCodecDeltaDeltaBitpack = VectorCodec::DELTA_DELTA_BITPACK;
const VectorCodecRle = VectorCodec::RLE;
const VectorCodecPatchedFor = VectorCodec::PATCHED_FOR;
const VectorCodecSimple8b = VectorCodec::SIMPLE8B;
const VectorCodecXorFloat = VectorCodec::XOR_FLOAT;
const VectorCodecDictionary = VectorCodec::DICTIONARY;
const VectorCodecStringRef = VectorCodec::STRING_REF;
const VectorCodecPrefixDelta = VectorCodec::PREFIX_DELTA;

/** @return array{0: VectorCodec, 1: bool} */
function vector_codec_from_byte(int $b): array
{
    if ($b <= 12) {
        return [VectorCodec::from($b), true];
    }
    return [VectorCodec::PLAIN, false];
}

final class TypedVectorData
{
    public function __construct(
        public ElementType $kind = ElementType::BOOL,
        /** @var list<bool> */
        public array $bools = [],
        /** @var list<int> */
        public array $i64s = [],
        /** @var list<int> */
        public array $u64s = [],
        /** @var list<float> */
        public array $f64s = [],
        /** @var list<string> */
        public array $strings = [],
        /** @var list<string> */
        public array $binary = [],
        /** @var list<Value> */
        public array $values = [],
    ) {
    }
}

final class TypedVector
{
    public function __construct(
        public ElementType $elementType,
        public VectorCodec $codec,
        public TypedVectorData $data,
    ) {
    }
}

final class SchemaField
{
    public function __construct(
        public int $number,
        public string $name,
        public string $logicalType = '',
        public bool $required = false,
        public ?Value $defaultValue = null,
        public ?int $min = null,
        public ?int $max = null,
        /** @var list<string> */
        public array $enumValues = [],
    ) {
    }
}

final class Schema
{
    public function __construct(
        public int $schemaId,
        public string $name,
        /** @var list<SchemaField> */
        public array $fields,
    ) {
    }
}

enum NullStrategy: int
{
    case NONE = 0;
    case PRESENCE_BITMAP = 1;
    case INVERTED_PRESENCE_BITMAP = 2;
    case ALL_PRESENT_ELIDED = 3;
}

const NullStrategyNone = NullStrategy::NONE;
const NullStrategyPresenceBitmap = NullStrategy::PRESENCE_BITMAP;
const NullStrategyInvertedPresenceBitmap = NullStrategy::INVERTED_PRESENCE_BITMAP;
const NullStrategyAllPresentElided = NullStrategy::ALL_PRESENT_ELIDED;

/** @return array{0: NullStrategy, 1: bool} */
function null_strategy_from_byte(int $b): array
{
    if ($b >= 0 && $b <= 3) {
        return [NullStrategy::from($b), true];
    }
    return [NullStrategy::NONE, false];
}

final class Column
{
    public function __construct(
        public int $fieldId,
        public NullStrategy $nullStrategy,
        /** @var list<bool> */
        public array $presence = [],
        public bool $hasPresence = false,
        public VectorCodec $codec = VectorCodec::PLAIN,
        public ?int $dictionaryId = null,
        public TypedVectorData $values = new TypedVectorData(),
    ) {
    }
}

enum ControlOpcode: int
{
    case REGISTER_KEYS = 0;
    case REGISTER_SHAPE = 1;
    case REGISTER_STRINGS = 2;
    case PROMOTE_STRING_FIELD_TO_ENUM = 3;
    case RESET_TABLES = 4;
    case RESET_STATE = 5;
}

const ControlOpcodeRegisterKeys = ControlOpcode::REGISTER_KEYS;
const ControlOpcodeRegisterShape = ControlOpcode::REGISTER_SHAPE;
const ControlOpcodeRegisterStrings = ControlOpcode::REGISTER_STRINGS;
const ControlOpcodePromoteStringFieldToEnum = ControlOpcode::PROMOTE_STRING_FIELD_TO_ENUM;
const ControlOpcodeResetTables = ControlOpcode::RESET_TABLES;
const ControlOpcodeResetState = ControlOpcode::RESET_STATE;

/** @return array{0: ControlOpcode, 1: bool} */
function control_opcode_from_byte(int $b): array
{
    if ($b >= 0 && $b <= 5) {
        return [ControlOpcode::from($b), true];
    }
    return [ControlOpcode::REGISTER_KEYS, false];
}

final class RegisterShapeControl
{
    /** @param list<KeyRef> $keys */
    public function __construct(
        public int $shapeId,
        public array $keys,
    ) {
    }
}

final class PromoteEnumControl
{
    /** @param list<string> $values */
    public function __construct(
        public string $fieldIdentity,
        public array $values,
    ) {
    }
}

final class ControlMessage
{
    public function __construct(
        public ControlOpcode $opcode,
        /** @var list<string> */
        public array $registerKeys = [],
        public ?RegisterShapeControl $registerShape = null,
        /** @var list<string> */
        public array $registerStrings = [],
        public ?PromoteEnumControl $promoteStringFieldToEnum = null,
        public bool $resetTables = false,
        public bool $resetState = false,
    ) {
    }
}

enum PatchOpcode: int
{
    case KEEP = 0;
    case REPLACE_SCALAR = 1;
    case REPLACE_VECTOR = 2;
    case APPEND_VECTOR = 3;
    case TRUNCATE_VECTOR = 4;
    case DELETE_FIELD = 5;
    case INSERT_FIELD = 6;
    case STRING_REF = 7;
    case PREFIX_DELTA = 8;
}

const PatchOpcodeKeep = PatchOpcode::KEEP;
const PatchOpcodeReplaceScalar = PatchOpcode::REPLACE_SCALAR;
const PatchOpcodeReplaceVector = PatchOpcode::REPLACE_VECTOR;
const PatchOpcodeAppendVector = PatchOpcode::APPEND_VECTOR;
const PatchOpcodeTruncateVector = PatchOpcode::TRUNCATE_VECTOR;
const PatchOpcodeDeleteField = PatchOpcode::DELETE_FIELD;
const PatchOpcodeInsertField = PatchOpcode::INSERT_FIELD;
const PatchOpcodeStringRef = PatchOpcode::STRING_REF;
const PatchOpcodePrefixDelta = PatchOpcode::PREFIX_DELTA;

/** @return array{0: PatchOpcode, 1: bool} */
function patch_opcode_from_byte(int $b): array
{
    if ($b <= 8) {
        return [PatchOpcode::from($b), true];
    }
    return [PatchOpcode::KEEP, false];
}

final class BaseRef
{
    public function __construct(
        public bool $previous = false,
        public int $baseId = 0,
    ) {
    }
}

function base_ref_previous(): BaseRef
{
    return new BaseRef(previous: true);
}

function base_ref_id(int $refId): BaseRef
{
    return new BaseRef(baseId: $refId);
}

final class PatchOperation
{
    public function __construct(
        public int $fieldId,
        public PatchOpcode $opcode,
        public ?Value $value = null,
    ) {
    }
}

enum ControlStreamCodec: int
{
    case PLAIN = 0;
    case RLE = 1;
    case BITPACK = 2;
    case HUFFMAN = 3;
    case FSE = 4;
}

const ControlStreamCodecPlain = ControlStreamCodec::PLAIN;
const ControlStreamCodecRle = ControlStreamCodec::RLE;
const ControlStreamCodecBitpack = ControlStreamCodec::BITPACK;
const ControlStreamCodecHuffman = ControlStreamCodec::HUFFMAN;
const ControlStreamCodecFse = ControlStreamCodec::FSE;

/** @return array{0: ControlStreamCodec, 1: bool} */
function control_stream_codec_from_byte(int $b): array
{
    if ($b <= 4) {
        return [ControlStreamCodec::from($b), true];
    }
    return [ControlStreamCodec::PLAIN, false];
}

final class ShapedObjectMessage
{
    /** @param list<Value> $values */
    public function __construct(
        public int $shapeId,
        public array $values,
        /** @var list<bool> */
        public array $presence = [],
        public bool $hasPresence = false,
    ) {
    }
}

final class SchemaObjectMessage
{
    /** @param list<Value> $fields */
    public function __construct(
        public array $fields,
        public ?int $schemaId = null,
        /** @var list<bool> */
        public array $presence = [],
        public bool $hasPresence = false,
    ) {
    }
}

final class RowBatchMessage
{
    /** @param list<list<Value>> $rows */
    public function __construct(
        public array $rows,
    ) {
    }
}

final class ColumnBatchMessage
{
    /** @param list<Column> $columns */
    public function __construct(
        public int $count,
        public array $columns,
    ) {
    }
}

final class ExtMessage
{
    public function __construct(
        public int $extType,
        public string $payload,
    ) {
    }
}

final class StatePatchMessage
{
    /** @param list<PatchOperation> $operations */
    public function __construct(
        public BaseRef $baseRef,
        public array $operations,
        /** @var list<Value> */
        public array $literals = [],
    ) {
    }
}

final class TemplateBatchMessage
{
    /** @param list<bool> $changedColumnMask */
    /** @param list<Column> $columns */
    public function __construct(
        public int $templateId,
        public int $count,
        public array $changedColumnMask,
        public array $columns,
    ) {
    }
}

final class ControlStreamMessage
{
    public function __construct(
        public ControlStreamCodec $codec,
        public string $payload,
    ) {
    }
}

final class BaseSnapshotMessage
{
    public function __construct(
        public int $baseId,
        public int $schemaOrShapeRef,
        public Message $payload,
    ) {
    }
}

final class TemplateDescriptor
{
    /** @param list<int> $fieldIds */
    /** @param list<NullStrategy> $nullStrategies */
    /** @param list<VectorCodec> $codecs */
    public function __construct(
        public int $templateId,
        public array $fieldIds = [],
        public array $nullStrategies = [],
        public array $codecs = [],
    ) {
    }
}

final class Message
{
    public function __construct(
        public MessageKind $kind,
        public ?Value $scalar = null,
        /** @var list<Value> */
        public array $array = [],
        /** @var list<MessageMapEntry> */
        public array $map = [],
        public ?ShapedObjectMessage $shapedObject = null,
        public ?SchemaObjectMessage $schemaObject = null,
        public ?TypedVector $typedVector = null,
        public ?RowBatchMessage $rowBatch = null,
        public ?ColumnBatchMessage $columnBatch = null,
        public ?ControlMessage $control = null,
        public ?ExtMessage $ext = null,
        public ?StatePatchMessage $statePatch = null,
        public ?TemplateBatchMessage $templateBatch = null,
        public ?ControlStreamMessage $controlStream = null,
        public ?BaseSnapshotMessage $baseSnapshot = null,
    ) {
    }

    public function clone(): Message
    {
        return match ($this->kind) {
            MessageKind::SCALAR => new Message(
                kind: MessageKind::SCALAR,
                scalar: ($this->scalar ?? new_null())->clone(),
            ),
            MessageKind::ARRAY => new Message(
                kind: MessageKind::ARRAY,
                array: array_map(static fn (Value $v) => $v->clone(), $this->array),
            ),
            MessageKind::MAP => new Message(
                kind: MessageKind::MAP,
                map: array_map(
                    static fn (MessageMapEntry $e) => new MessageMapEntry($e->key, $e->value->clone()),
                    $this->map,
                ),
            ),
            MessageKind::SHAPED_OBJECT => (function () {
                $s = $this->shapedObject;
                assert($s !== null);
                return new Message(
                    kind: MessageKind::SHAPED_OBJECT,
                    shapedObject: new ShapedObjectMessage(
                        shapeId: $s->shapeId,
                        presence: $s->hasPresence ? $s->presence : [],
                        hasPresence: $s->hasPresence,
                        values: array_map(static fn (Value $v) => $v->clone(), $s->values),
                    ),
                );
            })(),
            MessageKind::SCHEMA_OBJECT => (function () {
                $s = $this->schemaObject;
                assert($s !== null);
                return new Message(
                    kind: MessageKind::SCHEMA_OBJECT,
                    schemaObject: new SchemaObjectMessage(
                        schemaId: $s->schemaId,
                        presence: $s->hasPresence ? $s->presence : [],
                        hasPresence: $s->hasPresence,
                        fields: array_map(static fn (Value $v) => $v->clone(), $s->fields),
                    ),
                );
            })(),
            MessageKind::TYPED_VECTOR => new Message(
                kind: MessageKind::TYPED_VECTOR,
                typedVector: clone_typed_vector($this->typedVector),
            ),
            MessageKind::ROW_BATCH => (function () {
                $rb = $this->rowBatch;
                assert($rb !== null);
                return new Message(
                    kind: MessageKind::ROW_BATCH,
                    rowBatch: new RowBatchMessage(
                        rows: array_map(
                            static fn (array $row) => array_map(static fn (Value $v) => $v->clone(), $row),
                            $rb->rows,
                        ),
                    ),
                );
            })(),
            MessageKind::COLUMN_BATCH => (function () {
                $cb = $this->columnBatch;
                assert($cb !== null);
                return new Message(
                    kind: MessageKind::COLUMN_BATCH,
                    columnBatch: new ColumnBatchMessage(
                        count: $cb->count,
                        columns: array_map(static fn (Column $c) => clone_column($c), $cb->columns),
                    ),
                );
            })(),
            MessageKind::CONTROL => new Message(
                kind: MessageKind::CONTROL,
                control: clone_control($this->control),
            ),
            MessageKind::EXT => (function () {
                $e = $this->ext;
                assert($e !== null);
                return new Message(
                    kind: MessageKind::EXT,
                    ext: new ExtMessage(extType: $e->extType, payload: $e->payload),
                );
            })(),
            MessageKind::STATE_PATCH => (function () {
                $sp = $this->statePatch;
                assert($sp !== null);
                $ops = [];
                foreach ($sp->operations as $op) {
                    $ops[] = new PatchOperation(
                        fieldId: $op->fieldId,
                        opcode: $op->opcode,
                        value: $op->value?->clone(),
                    );
                }
                return new Message(
                    kind: MessageKind::STATE_PATCH,
                    statePatch: new StatePatchMessage(
                        baseRef: $sp->baseRef,
                        operations: $ops,
                        literals: array_map(static fn (Value $v) => $v->clone(), $sp->literals),
                    ),
                );
            })(),
            MessageKind::TEMPLATE_BATCH => (function () {
                $tb = $this->templateBatch;
                assert($tb !== null);
                return new Message(
                    kind: MessageKind::TEMPLATE_BATCH,
                    templateBatch: new TemplateBatchMessage(
                        templateId: $tb->templateId,
                        count: $tb->count,
                        changedColumnMask: $tb->changedColumnMask,
                        columns: array_map(static fn (Column $c) => clone_column($c), $tb->columns),
                    ),
                );
            })(),
            MessageKind::CONTROL_STREAM => (function () {
                $cs = $this->controlStream;
                assert($cs !== null);
                return new Message(
                    kind: MessageKind::CONTROL_STREAM,
                    controlStream: new ControlStreamMessage(codec: $cs->codec, payload: $cs->payload),
                );
            })(),
            MessageKind::BASE_SNAPSHOT => (function () {
                $bs = $this->baseSnapshot;
                assert($bs !== null);
                return new Message(
                    kind: MessageKind::BASE_SNAPSHOT,
                    baseSnapshot: new BaseSnapshotMessage(
                        baseId: $bs->baseId,
                        schemaOrShapeRef: $bs->schemaOrShapeRef,
                        payload: $bs->payload->clone(),
                    ),
                );
            })(),
            default => new Message(kind: MessageKind::SCALAR),
        };
    }
}

function clone_typed_vector(?TypedVector $tv): ?TypedVector
{
    if ($tv === null) {
        return null;
    }
    $outData = new TypedVectorData(kind: $tv->elementType);
    match ($tv->elementType) {
        ElementType::BOOL => $outData->bools = $tv->data->bools,
        ElementType::I64 => $outData->i64s = $tv->data->i64s,
        ElementType::U64 => $outData->u64s = $tv->data->u64s,
        ElementType::F64 => $outData->f64s = $tv->data->f64s,
        ElementType::STRING => $outData->strings = $tv->data->strings,
        ElementType::BINARY => $outData->binary = $tv->data->binary,
        ElementType::VALUE => $outData->values = array_map(static fn (Value $v) => $v->clone(), $tv->data->values),
        default => null,
    };
    return new TypedVector(elementType: $tv->elementType, codec: $tv->codec, data: $outData);
}

function clone_column(Column $c): Column
{
    $out = new Column(
        fieldId: $c->fieldId,
        nullStrategy: $c->nullStrategy,
        hasPresence: $c->hasPresence,
        codec: $c->codec,
        dictionaryId: $c->dictionaryId,
        values: clone_typed_vector_data($c->values),
    );
    if ($c->hasPresence) {
        $out->presence = $c->presence;
    }
    return $out;
}

function clone_typed_vector_data(TypedVectorData $d): TypedVectorData
{
    return new TypedVectorData(
        kind: $d->kind,
        bools: $d->bools,
        i64s: $d->i64s,
        u64s: $d->u64s,
        f64s: $d->f64s,
        strings: $d->strings,
        binary: $d->binary,
        values: array_map(static fn (Value $v) => $v->clone(), $d->values),
    );
}

function clone_control(?ControlMessage $c): ?ControlMessage
{
    if ($c === null) {
        return null;
    }
    $out = new ControlMessage(
        opcode: $c->opcode,
        registerKeys: $c->registerKeys,
        registerStrings: $c->registerStrings,
        resetTables: $c->resetTables,
        resetState: $c->resetState,
    );
    if ($c->registerShape !== null) {
        $rs = $c->registerShape;
        $out->registerShape = new RegisterShapeControl(shapeId: $rs->shapeId, keys: $rs->keys);
    }
    if ($c->promoteStringFieldToEnum !== null) {
        $p = $c->promoteStringFieldToEnum;
        $out->promoteStringFieldToEnum = new PromoteEnumControl(
            fieldIdentity: $p->fieldIdentity,
            values: $p->values,
        );
    }
    return $out;
}
