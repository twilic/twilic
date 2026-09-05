<?php

declare(strict_types=1);

namespace Twilic;

const TAG_NULL = 0;
const TAG_BOOL_FALSE = 1;
const TAG_BOOL_TRUE = 2;
const TAG_I64 = 3;
const TAG_U64 = 4;
const TAG_F64 = 5;
const TAG_STRING = 6;
const TAG_BINARY = 7;
const TAG_ARRAY = 8;
const TAG_MAP = 9;

final class TwilicCodec
{
    public SessionState $state;

    public function __construct(?SessionState $state)
    {
        $this->state = $state ?? new_session_state();
    }

    public function encodeMessage(Message $message): string
    {
        $out = new ByteBuffer();
        $this->writeMessage($message, $out);
        return $out->bytes();
    }

    public function decodeMessage(string $data): Message
    {
        $reader = new_reader($data);
        $msg = $this->readMessage($reader);
        if (!$reader->isEof()) {
            throw invalid_data('trailing bytes in message');
        }
        switch ($msg->kind) {
            case MessageKind::CONTROL:
                break;
            case MessageKind::STATE_PATCH:
                $sp = $msg->statePatch;
                assert($sp !== null);
                try {
                    $reconstructed = $this->applyStatePatch($sp->baseRef, $sp->operations, $sp->literals);
                    $this->state->previousMessage = $reconstructed;
                    $this->state->previousMessageSize = strlen($data);
                } catch (\Throwable $err) {
                    if (is_unknown_reference($err) || is_stateless_retry($err)) {
                        throw $err;
                    }
                }
                break;
            case MessageKind::TEMPLATE_BATCH:
                if ($this->state->previousMessage === null) {
                    $this->state->previousMessage = $msg->clone();
                    $this->state->previousMessageSize = strlen($data);
                }
                break;
            default:
                $this->state->previousMessage = $msg->clone();
                $this->state->previousMessageSize = strlen($data);
                break;
        }
        return $msg;
    }

    public function encodeValue(Value $value): string
    {
        $msg = $this->messageForValue($value);
        $out = $this->encodeMessage($msg);
        $this->state->previousMessage = $msg->clone();
        $this->state->previousMessageSize = strlen($out);
        return $out;
    }

    public function decodeValue(string $data): Value
    {
        $msg = $this->decodeMessage($data);
        $this->state->previousMessage = $msg->clone();
        return match ($msg->kind) {
            MessageKind::SCALAR => ($msg->scalar ?? throw invalid_data('scalar'))->clone(),
            MessageKind::ARRAY => new_array(array_map(static fn (Value $v) => $v->clone(), $msg->array)),
            MessageKind::MAP => new_map(...entries_to_map($msg->map, $this->state)),
            MessageKind::SHAPED_OBJECT => (function () use ($msg): Value {
                $so = $msg->shapedObject;
                assert($so !== null);
                [$keys, $ok] = $this->state->shapeTable->getKeys($so->shapeId);
                if (!$ok) {
                    throw $this->referenceError('shape_id', $so->shapeId);
                }
                return new_map(...shape_values_to_map($keys, $so->presence, $so->hasPresence, $so->values));
            })(),
            MessageKind::TYPED_VECTOR => typed_vector_to_value($msg->typedVector ?? throw invalid_data('typed_vector')),
            default => throw invalid_data('decode_value expects scalar/array/map/vector message'),
        };
    }

    private function referenceError(string $kind, int $refId): \Throwable
    {
        if ($this->state->options->unknownReferencePolicy === UnknownReferencePolicy::STATELESS_RETRY) {
            return stateless_retry_required($kind, $refId);
        }
        return unknown_reference($kind, $refId);
    }

    public function messageForValue(Value $value): Message
    {
        return match ($value->kind) {
            ValueKind::ARRAY => (function () use ($value): Message {
                [$vec, $ok] = $this->tryMakeTypedVector($value->arr);
                if ($ok) {
                    return new Message(kind: MessageKind::TYPED_VECTOR, typedVector: $vec);
                }
                return new Message(
                    kind: MessageKind::ARRAY,
                    array: array_map(static fn (Value $v) => $v->clone(), $value->arr),
                );
            })(),
            ValueKind::MAP => (function () use ($value): Message {
                $keys = array_map(static fn (MapEntry $e) => $e->key, $value->map);
                $sk = shape_key($keys);
                $hadObservation = array_key_exists($sk, $this->state->encodeShapeObservations);
                $obs = $this->observeEncodeShapeCandidate($keys);
                [$shapeId, $ok] = $this->state->shapeTable->getId($keys);
                if ($ok && (!$hadObservation || $obs >= 2)) {
                    return $this->shapedMessage($shapeId, $value->map);
                }
                return $this->mapMessage($value->map);
            })(),
            default => new Message(kind: MessageKind::SCALAR, scalar: $value->clone()),
        };
    }

    /** @param list<MapEntry> $entries */
    private function mapMessage(array $entries): Message
    {
        $out = [];
        foreach ($entries as $e) {
            $key = $e->key;
            [$refId, $ok] = $this->state->keyTable->getId($key);
            if ($ok) {
                $keyRef = key_ref_id($refId);
            } else {
                $this->state->keyTable->register($key);
                $keyRef = key_ref_literal($key);
            }
            $out[] = new MessageMapEntry(key: $keyRef, value: $e->value->clone());
        }
        return new Message(kind: MessageKind::MAP, map: $out);
    }

    /** @param list<MapEntry> $entries */
    private function shapedMessage(int $shapeId, array $entries): Message
    {
        [$keys, $_] = $this->state->shapeTable->getKeys($shapeId);
        $index = [];
        foreach ($entries as $e) {
            $index[$e->key] = $e->value;
        }
        $values = [];
        $presence = [];
        $allPresent = true;
        foreach ($keys as $key) {
            $v = $index[$key] ?? null;
            if ($v !== null) {
                $presence[] = true;
                $values[] = $v->clone();
            } else {
                $presence[] = false;
                $allPresent = false;
            }
        }
        $msg = new ShapedObjectMessage(shapeId: $shapeId, values: $values);
        if (!$allPresent) {
            $msg->hasPresence = true;
            $msg->presence = $presence;
        }
        return new Message(kind: MessageKind::SHAPED_OBJECT, shapedObject: $msg);
    }

    /** @param list<Value> $values @return array{0: TypedVector, 1: bool} */
    private function tryMakeTypedVector(array $values): array
    {
        if (count($values) < 4) {
            return [new TypedVector(ElementType::BOOL, VectorCodec::PLAIN, new TypedVectorData()), false];
        }
        $allBool = $allI64 = $allU64 = $allF64 = $allStr = true;
        foreach ($values as $v) {
            $allBool = $allBool && $v->kind === ValueKind::BOOL;
            $allI64 = $allI64 && $v->kind === ValueKind::I64;
            $allU64 = $allU64 && $v->kind === ValueKind::U64;
            $allF64 = $allF64 && $v->kind === ValueKind::F64;
            $allStr = $allStr && $v->kind === ValueKind::STRING;
        }
        if (!($allBool || $allI64 || $allU64 || $allF64 || $allStr)) {
            return [new TypedVector(ElementType::BOOL, VectorCodec::PLAIN, new TypedVectorData()), false];
        }
        if ($allBool) {
            return [new TypedVector(
                ElementType::BOOL,
                VectorCodec::DIRECT_BITPACK,
                typed_data_bool(array_map(static fn (Value $v) => $v->bool, $values)),
            ), true];
        }
        if ($allI64) {
            $vals = array_map(static fn (Value $v) => $v->i64, $values);
            return [new TypedVector(
                ElementType::I64,
                select_integer_codec($vals),
                typed_data_i64($vals),
            ), true];
        }
        if ($allU64) {
            $vals = array_map(static fn (Value $v) => $v->u64, $values);
            return [new TypedVector(
                ElementType::U64,
                select_u64_codec($vals),
                typed_data_u64($vals),
            ), true];
        }
        if ($allF64) {
            $vals = array_map(static fn (Value $v) => $v->f64, $values);
            return [new TypedVector(
                ElementType::F64,
                select_float_codec($vals),
                typed_data_f64($vals),
            ), true];
        }
        $vals = array_map(static fn (Value $v) => $v->str, $values);
        return [new TypedVector(
            ElementType::STRING,
            select_string_codec($vals),
            typed_data_string($vals),
        ), true];
    }


    private function writeMessage(Message $message, ByteBuffer $out): void
    {
        switch ($message->kind) {
            case MessageKind::SCALAR:
                $out->append((int) MessageKind::SCALAR->value);
                assert($message->scalar !== null);
                $this->writeValue($message->scalar, $out);
                break;
            case MessageKind::ARRAY:
                $out->append((int) MessageKind::ARRAY->value);
                encode_varuint(count($message->array), $out);
                foreach ($message->array as $v) {
                    $this->writeValue($v, $out);
                }
                break;
            case MessageKind::MAP:
                $out->append((int) MessageKind::MAP->value);
                encode_varuint(count($message->map), $out);
                foreach ($message->map as $e) {
                    $this->writeKeyRef($e->key, $out);
                    $fieldId = key_ref_field_identity($e->key, $this->state);
                    $this->writeValueWithField($e->value, $fieldId, $out);
                }
                break;
            case MessageKind::SHAPED_OBJECT:
                $out->append((int) MessageKind::SHAPED_OBJECT->value);
                $so = $message->shapedObject;
                assert($so !== null);
                encode_varuint($so->shapeId, $out);
                $this->writePresence($so->presence, $so->hasPresence, $out);
                encode_varuint(count($so->values), $out);
                [$keys, $ok] = $this->state->shapeTable->getKeys($so->shapeId);
                if ($ok) {
                    $pres = $so->presence;
                    if (!$so->hasPresence) {
                        $pres = array_fill(0, count($keys), true);
                    }
                    $vIdx = 0;
                    foreach ($keys as $i => $key) {
                        if ($i < count($pres) && !$pres[$i]) {
                            continue;
                        }
                        if ($vIdx >= count($so->values)) {
                            break;
                        }
                        $this->writeValueWithField($so->values[$vIdx], $key, $out);
                        $vIdx++;
                    }
                    while ($vIdx < count($so->values)) {
                        $this->writeValue($so->values[$vIdx], $out);
                        $vIdx++;
                    }
                } else {
                    foreach ($so->values as $v) {
                        $this->writeValue($v, $out);
                    }
                }
                break;
            case MessageKind::SCHEMA_OBJECT:
                $out->append((int) MessageKind::SCHEMA_OBJECT->value);
                $so = $message->schemaObject;
                assert($so !== null);
                if ($so->schemaId !== null) {
                    $out->append(1);
                    encode_varuint($so->schemaId, $out);
                } else {
                    $out->append(0);
                }
                $this->writePresence($so->presence, $so->hasPresence, $out);
                encode_varuint(count($so->fields), $out);
                $schema = null;
                if ($so->schemaId !== null) {
                    $schema = $this->state->schemas[$so->schemaId] ?? null;
                } elseif ($this->state->lastSchemaId !== null) {
                    $schema = $this->state->schemas[$this->state->lastSchemaId] ?? null;
                }
                if ($schema !== null) {
                    $out->append(1);
                    $this->writeSchemaFields($schema, $so->presence, $so->hasPresence, $so->fields, $out);
                    if ($so->schemaId !== null) {
                        $this->state->lastSchemaId = $so->schemaId;
                    }
                } else {
                    $out->append(0);
                    foreach ($so->fields as $v) {
                        $this->writeValue($v, $out);
                    }
                }
                break;
            case MessageKind::TYPED_VECTOR:
                $out->append((int) MessageKind::TYPED_VECTOR->value);
                assert($message->typedVector !== null);
                $this->writeTypedVector($message->typedVector, $out);
                break;
            case MessageKind::ROW_BATCH:
                $out->append((int) MessageKind::ROW_BATCH->value);
                $rb = $message->rowBatch;
                assert($rb !== null);
                encode_varuint(count($rb->rows), $out);
                foreach ($rb->rows as $row) {
                    encode_varuint(count($row), $out);
                    foreach ($row as $v) {
                        $this->writeValue($v, $out);
                    }
                }
                break;
            case MessageKind::COLUMN_BATCH:
                $out->append((int) MessageKind::COLUMN_BATCH->value);
                $cb = $message->columnBatch;
                assert($cb !== null);
                encode_varuint($cb->count, $out);
                encode_varuint(count($cb->columns), $out);
                foreach ($cb->columns as $col) {
                    $this->writeColumn($col, $out);
                }
                break;
            case MessageKind::CONTROL:
                $out->append((int) MessageKind::CONTROL->value);
                assert($message->control !== null);
                $this->writeControl($message->control, $out);
                break;
            case MessageKind::EXT:
                $out->append((int) MessageKind::EXT->value);
                $ext = $message->ext;
                assert($ext !== null);
                encode_varuint($ext->extType, $out);
                encode_bytes($ext->payload, $out);
                break;
            case MessageKind::STATE_PATCH:
                $out->append((int) MessageKind::STATE_PATCH->value);
                $sp = $message->statePatch;
                assert($sp !== null);
                $this->writeBaseRef($sp->baseRef, $out);
                encode_varuint(count($sp->operations), $out);
                foreach ($sp->operations as $op) {
                    encode_varuint($op->fieldId, $out);
                    $out->append((int) $op->opcode->value);
                    if ($op->value !== null) {
                        $out->append(1);
                        $this->writeValue($op->value, $out);
                    } else {
                        $out->append(0);
                    }
                }
                encode_varuint(count($sp->literals), $out);
                foreach ($sp->literals as $lit) {
                    $this->writeValue($lit, $out);
                }
                break;
            case MessageKind::TEMPLATE_BATCH:
                $out->append((int) MessageKind::TEMPLATE_BATCH->value);
                $tb = $message->templateBatch;
                assert($tb !== null);
                encode_varuint($tb->templateId, $out);
                encode_varuint($tb->count, $out);
                encode_bitmap($tb->changedColumnMask, $out);
                encode_varuint(count($tb->columns), $out);
                foreach ($tb->columns as $col) {
                    $this->writeColumn($col, $out);
                }
                break;
            case MessageKind::CONTROL_STREAM:
                $out->append((int) MessageKind::CONTROL_STREAM->value);
                $cs = $message->controlStream;
                assert($cs !== null);
                $out->append((int) $cs->codec->value);
                $this->writeControlStreamPayload($cs->codec, $cs->payload, $out);
                break;
            case MessageKind::BASE_SNAPSHOT:
                $out->append((int) MessageKind::BASE_SNAPSHOT->value);
                $bs = $message->baseSnapshot;
                assert($bs !== null);
                encode_varuint($bs->baseId, $out);
                encode_varuint($bs->schemaOrShapeRef, $out);
                $this->writeMessage($bs->payload, $out);
                register_base_snapshot($this->state, $bs->baseId, $bs->payload);
                break;
            default:
                throw invalid_data('unsupported message kind');
        }
    }




    private function readMessage(Reader $reader): Message
    {
        return $reader->withDepth(fn() => $this->readMessageInner($reader));
    }

    private function readMessageInner(Reader $reader): Message
    {
        $kindByte = $reader->readU8();
        [$kind, $ok] = message_kind_from_byte($kindByte);
        if (!$ok) {
            throw invalid_kind($kindByte);
        }
        switch ($kind) {
            case MessageKind::SCALAR:
                $v = $this->readValue($reader);
                return new Message(kind: MessageKind::SCALAR, scalar: $v);
            case MessageKind::ARRAY:
                $n = $reader->readCount();
                $values = [];
                for ($__i = 0; $__i < $n; $__i++) {
                    $values[] = $this->readValue($reader);
                }
                return new Message(kind: MessageKind::ARRAY, array: $values);
            case MessageKind::MAP:
                $n = $reader->readCount();
                $entries = [];
                for ($__i = 0; $__i < $n; $__i++) {
                    $keyRef = $this->readKeyRef($reader);
                    $fieldIdentity = key_ref_field_identity($keyRef, $this->state);
                    $v = $this->readValueWithField($reader, $fieldIdentity);
                    $entries[] = new MessageMapEntry(key: $keyRef, value: $v);
                }
                $keys = array_map(
                    fn (MessageMapEntry $e) => key_ref_string($e->key, $this->state),
                    $entries,
                );
                $this->observeDecodeShapeCandidate($keys);
                return new Message(kind: MessageKind::MAP, map: $entries);
            case MessageKind::SHAPED_OBJECT:
                $shapeId = $reader->readCount(65535);
                [$presence, $hasPresence] = $this->readPresence($reader);
                $n = $reader->readCount();
                $values = [];
                [$keys, $ok] = $this->state->shapeTable->getKeys($shapeId);
                if ($ok) {
                    $pres = $presence;
                    if (!$hasPresence) {
                        $pres = array_fill(0, count($keys), true);
                    }
                    $readCount = 0;
                    foreach ($keys as $i => $key) {
                        if ($i < count($pres) && !$pres[$i]) {
                            continue;
                        }
                        if ($readCount >= $n) {
                            break;
                        }
                        $values[] = $this->readValueWithField($reader, $key);
                        $readCount++;
                    }
                    while ($readCount < $n) {
                        $values[] = $this->readValue($reader);
                        $readCount++;
                    }
                } else {
                    for ($__i = 0; $__i < $n; $__i++) {
                        $values[] = $this->readValue($reader);
                    }
                }
                return new Message(
                    kind: MessageKind::SHAPED_OBJECT,
                    shapedObject: new ShapedObjectMessage(
                        shapeId: $shapeId,
                        presence: $presence,
                        hasPresence: $hasPresence,
                        values: $values,
                    ),
                );
            case MessageKind::SCHEMA_OBJECT:
                $hasSchema = $reader->readU8();
                $schemaId = null;
                if ($hasSchema === 1) {
                    $schemaId = $reader->readVaruint();
                }
                [$presence, $hasPresence] = $this->readPresence($reader);
                $n = $reader->readCount();
                $mode = $reader->readU8();
                $fields = [];
                if ($mode === 1) {
                    if ($schemaId !== null) {
                        $effectiveId = $schemaId;
                    } elseif ($this->state->lastSchemaId !== null) {
                        $effectiveId = $this->state->lastSchemaId;
                    } else {
                        throw invalid_data('schema object requires schema id in context');
                    }
                    $schema = $this->state->schemas[$effectiveId] ?? null;
                    if ($schema === null) {
                        throw $this->referenceError('schema_id', $effectiveId);
                    }
                    $fields = $this->readSchemaFields($schema, $presence, $hasPresence, $n, $reader);
                    $this->state->lastSchemaId = $effectiveId;
                } else {
                    for ($__i = 0; $__i < $n; $__i++) {
                        $fields[] = $this->readValue($reader);
                    }
                    if ($schemaId !== null) {
                        $this->state->lastSchemaId = $schemaId;
                    }
                }
                return new Message(
                    kind: MessageKind::SCHEMA_OBJECT,
                    schemaObject: new SchemaObjectMessage(
                        schemaId: $schemaId,
                        presence: $presence,
                        hasPresence: $hasPresence,
                        fields: $fields,
                    ),
                );
            case MessageKind::TYPED_VECTOR:
                $tv = $this->readTypedVector($reader, null, null);
                return new Message(kind: MessageKind::TYPED_VECTOR, typedVector: $tv);
            case MessageKind::ROW_BATCH:
                $rowCount = $reader->readCount();
                $rows = [];
                for ($__i = 0; $__i < $rowCount; $__i++) {
                    $fieldCount = $reader->readCount();
                    $row = [];
                    for ($__j = 0; $__j < $fieldCount; $__j++) {
                        $row[] = $this->readValue($reader);
                    }
                    $rows[] = $row;
                }
                return new Message(
                    kind: MessageKind::ROW_BATCH,
                    rowBatch: new RowBatchMessage(rows: $rows),
                );
            case MessageKind::COLUMN_BATCH:
                $count = $reader->readCount();
                $colCount = $reader->readCount();
                $cols = [];
                for ($__i = 0; $__i < $colCount; $__i++) {
                    $cols[] = $this->readColumn($reader);
                }
                return new Message(
                    kind: MessageKind::COLUMN_BATCH,
                    columnBatch: new ColumnBatchMessage(count: $count, columns: $cols),
                );
            case MessageKind::CONTROL:
                $ctrl = $this->readControl($reader);
                return new Message(kind: MessageKind::CONTROL, control: $ctrl);
            case MessageKind::EXT:
                $extType = $reader->readVaruint();
                $payload = $reader->readBytes();
                return new Message(
                    kind: MessageKind::EXT,
                    ext: new ExtMessage(extType: $extType, payload: $payload),
                );
            case MessageKind::STATE_PATCH:
                $baseRef = $this->readBaseRef($reader);
                $n = $reader->readCount();
                $ops = [];
                for ($__i = 0; $__i < $n; $__i++) {
                    $fieldId = $reader->readVaruint();
                    $opByte = $reader->readU8();
                    [$opcode, $opOk] = patch_opcode_from_byte($opByte);
                    if (!$opOk) {
                        throw invalid_data('patch opcode');
                    }
                    $hasValue = $reader->readU8();
                    $value = null;
                    if ($hasValue === 1) {
                        $value = $this->readValue($reader);
                    }
                    $ops[] = new PatchOperation(fieldId: $fieldId, opcode: $opcode, value: $value);
                }
                $litN = $reader->readCount();
                $lits = [];
                for ($__i = 0; $__i < $litN; $__i++) {
                    $lits[] = $this->readValue($reader);
                }
                return new Message(
                    kind: MessageKind::STATE_PATCH,
                    statePatch: new StatePatchMessage(baseRef: $baseRef, operations: $ops, literals: $lits),
                );
            case MessageKind::TEMPLATE_BATCH:
                $templateId = $reader->readVaruint();
                $count = $reader->readCount();
                $mask = $reader->readBitmap();
                $colN = $reader->readCount();
                $changedCols = [];
                for ($__i = 0; $__i < $colN; $__i++) {
                    $changedCols[] = $this->readColumn($reader);
                }
                $fullCols = $changedCols;
                $prev = $this->state->templateColumns[$templateId] ?? null;
                if ($prev !== null) {
                    $fullCols = merge_template_columns($prev, $mask, $changedCols);
                } else {
                    foreach ($mask as $bit) {
                        if (!$bit) {
                            throw $this->referenceError('template_id', $templateId);
                        }
                    }
                }
                $this->state->templateColumns[$templateId] = $fullCols;
                $this->state->templates[$templateId] = template_descriptor_from_columns($templateId, $fullCols);
                if ($count >= 16) {
                    $prevMsg = new Message(
                        kind: MessageKind::COLUMN_BATCH,
                        columnBatch: new ColumnBatchMessage(count: $count, columns: $fullCols),
                    );
                    $this->state->previousMessage = $prevMsg;
                }
                return new Message(
                    kind: MessageKind::TEMPLATE_BATCH,
                    templateBatch: new TemplateBatchMessage(
                        templateId: $templateId,
                        count: $count,
                        changedColumnMask: $mask,
                        columns: $changedCols,
                    ),
                );
            case MessageKind::CONTROL_STREAM:
                $codecByte = $reader->readU8();
                [$codec, $codecOk] = control_stream_codec_from_byte($codecByte);
                if (!$codecOk) {
                    throw invalid_data('control stream codec');
                }
                $payload = $this->readControlStreamPayload($codec, $reader);
                return new Message(
                    kind: MessageKind::CONTROL_STREAM,
                    controlStream: new ControlStreamMessage(codec: $codec, payload: $payload),
                );
            case MessageKind::BASE_SNAPSHOT:
                $baseId = $reader->readVaruint();
                $ref = $reader->readVaruint();
                $payload = $this->readMessage($reader);
                register_base_snapshot($this->state, $baseId, $payload);
                return new Message(
                    kind: MessageKind::BASE_SNAPSHOT,
                    baseSnapshot: new BaseSnapshotMessage(
                        baseId: $baseId,
                        schemaOrShapeRef: $ref,
                        payload: $payload,
                    ),
                );
            default:
                throw invalid_data('unsupported message kind');
        }
    }



    private function writeValue(Value $value, ByteBuffer $out): void
    {
        $this->writeValueWithField($value, null, $out);
    }

    private function writeValueWithField(Value $value, ?string $fieldIdentity, ByteBuffer $out): void
    {
        switch ($value->kind) {
            case ValueKind::NULL:
                $out->append(TAG_NULL);
                break;
            case ValueKind::BOOL:
                $out->append($value->bool ? TAG_BOOL_TRUE : TAG_BOOL_FALSE);
                break;
            case ValueKind::I64:
                $out->append(TAG_I64);
                write_smallest_u64(encode_zigzag($value->i64), $out);
                break;
            case ValueKind::U64:
                $out->append(TAG_U64);
                write_smallest_u64($value->u64, $out);
                break;
            case ValueKind::F64:
                $out->append(TAG_F64);
                append_f64_le($out, $value->f64);
                break;
            case ValueKind::STRING:
                $out->append(TAG_STRING);
                if ($fieldIdentity !== null) {
                    $enumVals = $this->state->fieldEnums[$fieldIdentity] ?? null;
                    if ($enumVals !== null) {
                        foreach ($enumVals as $i => $ev) {
                            if ($ev === $value->str) {
                                $out->append((int) StringMode::INLINE_ENUM->value);
                                encode_varuint($i, $out);
                                return;
                            }
                        }
                    }
                }
                if ($value->str === '') {
                    $out->append((int) StringMode::EMPTY->value);
                    return;
                }
                [$refId, $refOk] = $this->state->stringTable->getId($value->str);
                if ($refOk) {
                    $out->append((int) StringMode::REF->value);
                    encode_varuint($refId, $out);
                    return;
                }
                [$baseId, $prefixLen, $prefixOk] = $this->bestPrefixBase($value->str);
                if ($prefixOk && $prefixLen >= 4 && $prefixLen < strlen($value->str)) {
                    $out->append((int) StringMode::PREFIX_DELTA->value);
                    encode_varuint($baseId, $out);
                    encode_varuint($prefixLen, $out);
                    encode_string(substr($value->str, $prefixLen), $out);
                    $this->state->stringTable->register($value->str);
                    return;
                }
                $out->append((int) StringMode::LITERAL->value);
                encode_string($value->str, $out);
                $this->state->stringTable->register($value->str);
                break;
            case ValueKind::BINARY:
                $out->append(TAG_BINARY);
                encode_bytes($value->bin, $out);
                break;
            case ValueKind::ARRAY:
                $out->append(TAG_ARRAY);
                encode_varuint(count($value->arr), $out);
                foreach ($value->arr as $v) {
                    $this->writeValue($v, $out);
                }
                break;
            case ValueKind::MAP:
                $out->append(TAG_MAP);
                encode_varuint(count($value->map), $out);
                foreach ($value->map as $e) {
                    $this->writeKeyRef(key_ref_literal($e->key), $out);
                    $this->writeValueWithField($e->value, $e->key, $out);
                }
                break;
        }
    }

    private function readValue(Reader $reader): Value
    {
        return $this->readValueWithField($reader, null);
    }

    private function readValueWithField(Reader $reader, ?string $fieldIdentity): Value
    {
        return $reader->withDepth(fn() => $this->readValueWithFieldInner($reader, $fieldIdentity));
    }

    private function readValueWithFieldInner(Reader $reader, ?string $fieldIdentity): Value
    {
        $tag = $reader->readU8();
        if ($tag === TAG_NULL) {
            return new_null();
        }
        if ($tag === TAG_BOOL_FALSE) {
            return new_bool(false);
        }
        if ($tag === TAG_BOOL_TRUE) {
            return new_bool(true);
        }
        if ($tag === TAG_I64) {
            return new_i64(decode_zigzag(read_smallest_u64($reader)));
        }
        if ($tag === TAG_U64) {
            return new_u64(read_smallest_u64($reader));
        }
        if ($tag === TAG_F64) {
            return new_f64(read_f64_le($reader));
        }
        if ($tag === TAG_STRING) {
            return $this->readStringValue($reader, $fieldIdentity);
        }
        if ($tag === TAG_BINARY) {
            return new_binary($reader->readBytes());
        }
        if ($tag === TAG_ARRAY) {
            $n = $reader->readCount();
            $vals = [];
            for ($__i = 0; $__i < $n; $__i++) {
                $vals[] = $this->readValue($reader);
            }
            return new_array($vals);
        }
        if ($tag === TAG_MAP) {
            $n = $reader->readCount();
            $entries = [];
            for ($__i = 0; $__i < $n; $__i++) {
                $keyRef = $this->readKeyRef($reader);
                $v = $this->readValueWithField($reader, $keyRef->literal);
                $entries[] = new MapEntry(key: $keyRef->literal, value: $v);
            }
            return new_map(...$entries);
        }
        throw invalid_tag($tag);
    }

    private function readStringValue(Reader $reader, ?string $fieldIdentity): Value
    {
        $modeByte = $reader->readU8();
        [$mode, $modeOk] = string_mode_from_byte($modeByte);
        if (!$modeOk) {
            throw invalid_data('string mode');
        }
        switch ($mode) {
            case StringMode::EMPTY:
                return new_string('');
            case StringMode::LITERAL:
                $s = $reader->readString();
                $this->state->stringTable->register($s);
                return new_string($s);
            case StringMode::REF:
                $refId = $reader->readVaruint();
                [$s, $ok] = $this->state->stringTable->getValue($refId);
                if (!$ok) {
                    throw $this->referenceError('string_id', $refId);
                }
                return new_string($s);
            case StringMode::PREFIX_DELTA:
                $baseId = $reader->readVaruint();
                $prefixLen = $reader->readCount();
                $suffix = $reader->readString();
                [$base, $ok] = $this->state->stringTable->getValue($baseId);
                if (!$ok) {
                    throw $this->referenceError('string_id', $baseId);
                }
                if ($prefixLen > strlen($base)) {
                    throw invalid_data('prefix delta length');
                }
                $s = substr($base, 0, $prefixLen) . $suffix;
                $this->state->stringTable->register($s);
                return new_string($s);
            case StringMode::INLINE_ENUM:
                if ($fieldIdentity === null) {
                    throw invalid_data('inline enum missing field identity');
                }
                $enumVals = $this->state->fieldEnums[$fieldIdentity] ?? null;
                if ($enumVals === null) {
                    throw invalid_data('inline enum unknown field');
                }
                $code = $reader->readVaruint();
                if ($code >= count($enumVals)) {
                    throw invalid_data('inline enum code');
                }
                return new_string($enumVals[$code]);
            default:
                throw invalid_data('string mode');
        }
    }


    private function writeKeyRef(KeyRef $keyRef, ByteBuffer $out): void
    {
        if ($keyRef->isId) {
            $out->append(1);
            encode_varuint($keyRef->id, $out);
            return;
        }
        $out->append(0);
        encode_string($keyRef->literal, $out);
        $this->state->keyTable->register($keyRef->literal);
    }

    private function readKeyRef(Reader $reader): KeyRef
    {
        $mode = $reader->readU8();
        if ($mode === 1) {
            $refId = $reader->readVaruint();
            [$key, $ok] = $this->state->keyTable->getValue($refId);
            if (!$ok) {
                throw $this->referenceError('key_id', $refId);
            }
            return key_ref_literal($key);
        }
        if ($mode !== 0) {
            throw invalid_data('key ref mode');
        }
        $s = $reader->readString();
        $this->state->keyTable->register($s);
        return key_ref_literal($s);
    }

    private function writePresence(array $presence, bool $hasPresence, ByteBuffer $out): void
    {
        if (!$hasPresence) {
            $out->append(0);
            return;
        }
        $out->append(1);
        encode_bitmap($presence, $out);
    }

    /** @return array{0: list<bool>, 1: bool} */
    private function readPresence(Reader $reader): array
    {
        $flag = $reader->readU8();
        if ($flag === 0) {
            return [[], false];
        }
        if ($flag !== 1) {
            throw invalid_data('presence flag');
        }
        return [$reader->readBitmap(), true];
    }

    private function writeTypedVector(TypedVector $vector, ByteBuffer $out): void
    {
        $out->append((int) $vector->elementType->value);
        encode_varuint(typed_vector_len($vector->data), $out);
        $out->append((int) $vector->codec->value);
        switch ($vector->elementType) {
            case ElementType::BOOL:
                encode_bitmap($vector->data->bools, $out);
                break;
            case ElementType::I64:
                encode_i64_vector($vector->data->i64s, $vector->codec, $out);
                break;
            case ElementType::U64:
                encode_u64_vector($vector->data->u64s, $vector->codec, $out);
                break;
            case ElementType::F64:
                encode_f64_vector($vector->data->f64s, $vector->codec, $out);
                break;
            case ElementType::STRING:
                $this->writeStringVector($vector->data->strings, $vector->codec, $out);
                break;
            case ElementType::BINARY:
                encode_varuint(count($vector->data->binary), $out);
                foreach ($vector->data->binary as $b) {
                    encode_bytes($b, $out);
                }
                break;
            case ElementType::VALUE:
                encode_varuint(count($vector->data->values), $out);
                foreach ($vector->data->values as $v) {
                    $this->writeValue($v, $out);
                }
                break;
            default:
                throw invalid_data('unsupported element type');
        }
    }
/** @param list<string> $values */
    private function writeStringVector(array $values, VectorCodec $codec, ByteBuffer $out): void
    {
        switch ($codec) {
            case VectorCodec::DICTIONARY:
                $dictionary = [];
                $unique = [];
                $refs = [];
                foreach ($values as $value) {
                    if (array_key_exists($value, $dictionary)) {
                        $refs[] = $dictionary[$value];
                        continue;
                    }
                    $newRef = count($unique);
                    $dictionary[$value] = $newRef;
                    $unique[] = $value;
                    $refs[] = $newRef;
                }
                encode_varuint(count($unique), $out);
                foreach ($unique as $value) {
                    encode_string($value, $out);
                }
                encode_u64_vector($refs, VectorCodec::DIRECT_BITPACK, $out);
                break;
            case VectorCodec::STRING_REF:
                encode_varuint(count($values), $out);
                foreach ($values as $value) {
                    [$stringId, $ok] = $this->state->stringTable->getId($value);
                    if (!$ok) {
                        $stringId = $this->state->stringTable->register($value);
                    }
                    encode_varuint($stringId, $out);
                }
                break;
            case VectorCodec::PREFIX_DELTA:
                encode_varuint(count($values), $out);
                $prev = '';
                foreach ($values as $value) {
                    $prefix = common_prefix_len($prev, $value);
                    encode_varuint($prefix, $out);
                    encode_string(substr($value, $prefix), $out);
                    $prev = $value;
                }
                break;
            default:
                encode_varuint(count($values), $out);
                foreach ($values as $value) {
                    encode_string($value, $out);
                }
                break;
        }
    }

    /** @return list<string> */
    private function readStringVector(Reader $reader, VectorCodec $codec): array
    {
        switch ($codec) {
            case VectorCodec::DICTIONARY:
                $dictSize = $reader->readCount();
                $dictionary = [];
                for ($i = 0; $i < $dictSize; $i++) {
                    $dictionary[] = $reader->readString();
                }
                $refs = decode_u64_vector($reader, VectorCodec::DIRECT_BITPACK);
                $out = [];
                foreach ($refs as $ref) {
                    if ($ref < 0 || $ref >= count($dictionary)) {
                        throw invalid_data('dictionary reference');
                    }
                    $out[] = $dictionary[(int) $ref];
                }
                return $out;
            case VectorCodec::STRING_REF:
                $length = $reader->readCount();
                $out = [];
                for ($i = 0; $i < $length; $i++) {
                    $stringId = $reader->readVaruint();
                    [$value, $ok] = $this->state->stringTable->getValue($stringId);
                    if (!$ok) {
                        throw $this->referenceError('string_id', $stringId);
                    }
                    $out[] = $value;
                }
                return $out;
            case VectorCodec::PREFIX_DELTA:
                $length = $reader->readCount();
                $out = [];
                $prev = '';
                for ($i = 0; $i < $length; $i++) {
                    $prefixLen = $reader->readCount();
                    $suffix = $reader->readString();
                    if ($prefixLen > strlen($prev)) {
                        throw invalid_data('prefix delta in string vector');
                    }
                    $value = substr($prev, 0, $prefixLen) . $suffix;
                    $out[] = $value;
                    $prev = $value;
                }
                return $out;
            default:
                $length = $reader->readCount();
                $out = [];
                for ($i = 0; $i < $length; $i++) {
                    $out[] = $reader->readString();
                }
                return $out;
        }
    }

    private function readTypedVector(Reader $reader, ?ElementType $forcedElement, ?VectorCodec $expectedCodec): TypedVector
    {
        if ($forcedElement !== null) {
            $elementType = $forcedElement;
        } else {
            [$elementType, $etOk] = element_type_from_byte($reader->readU8());
            if (!$etOk) {
                throw invalid_data('vector element type');
            }
        }
        $expectedLen = $reader->readCount();
        [$codec, $codecOk] = vector_codec_from_byte($reader->readU8());
        if (!$codecOk) {
            throw invalid_data('vector codec');
        }
        if ($expectedCodec !== null && $codec !== $expectedCodec) {
            throw invalid_data('column codec mismatch');
        }
        $data = new TypedVectorData(kind: $elementType);
        switch ($elementType) {
            case ElementType::BOOL:
                $data->bools = $reader->readBitmap();
                break;
            case ElementType::I64:
                $data->i64s = decode_i64_vector($reader, $codec);
                break;
            case ElementType::U64:
                $data->u64s = decode_u64_vector($reader, $codec);
                break;
            case ElementType::F64:
                $data->f64s = decode_f64_vector($reader, $codec);
                break;
            case ElementType::STRING:
                $data->strings = $this->readStringVector($reader, $codec);
                break;
            case ElementType::BINARY:
                $n = $reader->readCount();
                for ($i = 0; $i < $n; $i++) {
                    $data->binary[] = $reader->readBytes();
                }
                break;
            case ElementType::VALUE:
                $n = $reader->readCount();
                for ($i = 0; $i < $n; $i++) {
                    $data->values[] = $this->readValue($reader);
                }
                break;
            default:
                throw invalid_data('unsupported element type');
        }
        if (typed_vector_len($data) !== $expectedLen) {
            throw invalid_data('typed vector length mismatch');
        }
        return new TypedVector(elementType: $elementType, codec: $codec, data: $data);
    }

    /** @param list<bool> $presence @param list<Value> $fields */
    private function writeSchemaFields(Schema $schema, array $presence, bool $hasPresence, array $fields, ByteBuffer $out): void
    {
        $indices = schema_present_field_indices($schema, $presence, $hasPresence);
        foreach ($indices as $i) {
            if ($i >= count($fields)) {
                throw invalid_data('schema fields length mismatch');
            }
            $this->writeSchemaFieldValue($schema->fields[$i], $fields[$i], $out);
        }
    }

    /** @param list<bool> $presence @return list<Value> */
    private function readSchemaFields(Schema $schema, array $presence, bool $hasPresence, int $n, Reader $reader): array
    {
        $indices = schema_present_field_indices($schema, $presence, $hasPresence);
        if (count($indices) !== $n) {
            throw invalid_data('schema fields length');
        }
        $out = [];
        foreach ($indices as $i) {
            $out[] = $this->readSchemaFieldValue($schema->fields[$i], $reader);
        }
        return $out;
    }

    private function writeSchemaFieldValue(SchemaField $field, Value $value, ByteBuffer $out): void
    {
        $logicalType = normalized_logical_type($field->logicalType);
        if ($logicalType === 'bool' && $value->kind !== ValueKind::BOOL) {
            throw invalid_data('schema bool field type mismatch');
        }
        if (in_array($logicalType, ['i64', 'int64', 'int'], true) && $value->kind !== ValueKind::I64) {
            throw invalid_data('schema i64 field type mismatch');
        }
        if (in_array($logicalType, ['u64', 'uint64', 'uint'], true) && $value->kind !== ValueKind::U64) {
            throw invalid_data('schema u64 field type mismatch');
        }
        if (in_array($logicalType, ['f64', 'float64', 'float'], true) && $value->kind !== ValueKind::F64) {
            throw invalid_data('schema f64 field type mismatch');
        }
        if ($logicalType === 'string') {
            if ($value->kind !== ValueKind::STRING) {
                throw invalid_data('schema string field type mismatch');
            }
            $this->writeValueWithField($value, $field->name, $out);
            return;
        }
        $this->writeValue($value, $out);
    }

    private function readSchemaFieldValue(SchemaField $field, Reader $reader): Value
    {
        if (normalized_logical_type($field->logicalType) === 'string') {
            return $this->readValueWithField($reader, $field->name);
        }
        return $this->readValue($reader);
    }

    private function writeColumn(Column $column, ByteBuffer $out): void
    {
        encode_varuint($column->fieldId, $out);
        $out->append((int) $column->nullStrategy->value);
        if ($column->nullStrategy === NullStrategy::PRESENCE_BITMAP
            || $column->nullStrategy === NullStrategy::INVERTED_PRESENCE_BITMAP) {
            if (!$column->hasPresence) {
                throw invalid_data('missing column presence bitmap');
            }
            encode_bitmap($column->presence, $out);
        }
        $out->append((int) $column->codec->value);
        if ($column->dictionaryId !== null) {
            $out->append(1);
            encode_varuint($column->dictionaryId, $out);
            $payload = $this->state->dictionaries[$column->dictionaryId] ?? null;
            $profile = $this->state->dictionaryProfiles[$column->dictionaryId] ?? null;
            if ($payload !== null && $profile !== null) {
                $out->append(1);
                encode_varuint($profile->version, $out);
                encode_varuint($profile->hash, $out);
                encode_varuint($profile->expiresAt, $out);
                $out->append((int) $profile->fallback->value);
                encode_bytes($payload, $out);
            } else {
                $out->append(0);
            }
        } else {
            $out->append(0);
        }

        $trainedBlock = null;
        if ($column->dictionaryId !== null
            && $column->values->kind === ElementType::STRING
            && ($column->codec === VectorCodec::DICTIONARY || $column->codec === VectorCodec::STRING_REF)) {
            $payload = $this->state->dictionaries[$column->dictionaryId] ?? null;
            if ($payload !== null) {
                try {
                    $dictionary = decode_trained_dictionary_payload($payload);
                    [$block, $ok] = encode_trained_dictionary_block($column->values->strings, $dictionary);
                    if ($ok) {
                        $trainedBlock = $block;
                    }
                } catch (\Throwable) {
                }
            }
        }
        if ($trainedBlock !== null) {
            $out->append(1);
            encode_bytes($trainedBlock, $out);
            return;
        }
        $out->append(0);
        $vector = new TypedVector(
            elementType: $column->values->kind,
            codec: $column->codec,
            data: clone_typed_vector_data($column->values),
        );
        $this->writeTypedVector($vector, $out);
    }

    private function readColumn(Reader $reader): Column
    {
        $fieldId = $reader->readVaruint();
        [$nullStrategy, $nsOk] = null_strategy_from_byte($reader->readU8());
        if (!$nsOk) {
            throw invalid_data('null strategy');
        }
        $presence = [];
        $hasPresence = false;
        if ($nullStrategy === NullStrategy::PRESENCE_BITMAP
            || $nullStrategy === NullStrategy::INVERTED_PRESENCE_BITMAP) {
            $presence = $reader->readBitmap();
            $hasPresence = true;
        }
        [$codec, $codecOk] = vector_codec_from_byte($reader->readU8());
        if (!$codecOk) {
            throw invalid_data('column codec');
        }
        $hasDict = $reader->readU8();
        $dictionaryId = null;
        if ($hasDict === 1) {
            $dictId = $reader->readVaruint();
            $hasProfile = $reader->readU8();
            if ($hasProfile === 0) {
                if (!array_key_exists($dictId, $this->state->dictionaries)) {
                    throw $this->referenceError('dict_id', $dictId);
                }
            } elseif ($hasProfile === 1) {
                $version = $reader->readVaruint();
                $hash = $reader->readVaruint();
                $expiresAt = $reader->readVaruint();
                [$fallback, $fbOk] = dictionary_fallback_from_byte($reader->readU8());
                if (!$fbOk) {
                    throw invalid_data('dictionary fallback');
                }
                $payload = $reader->readBytes();
                if (dictionary_payload_hash($payload) !== $hash) {
                    throw invalid_data('dictionary profile hash mismatch');
                }
                $this->state->dictionaries[$dictId] = $payload;
                $this->state->dictionaryProfiles[$dictId] = new DictionaryProfile(
                    version: $version,
                    hash: $hash,
                    expiresAt: $expiresAt,
                    fallback: $fallback,
                );
            } else {
                throw invalid_data('dictionary profile flag');
            }
            $dictionaryId = $dictId;
        } elseif ($hasDict !== 0) {
            throw invalid_data('dictionary flag');
        }
        $payloadMode = $reader->readU8();
        if ($payloadMode === 0) {
            $values = $this->readTypedVector($reader, null, $codec)->data;
        } elseif ($payloadMode === 1) {
            if ($dictionaryId === null) {
                throw invalid_data('trained dictionary block requires dict_id');
            }
            if ($codec !== VectorCodec::DICTIONARY && $codec !== VectorCodec::STRING_REF) {
                throw invalid_data('trained dictionary block requires string dictionary codec');
            }
            $dictionaryPayload = $this->state->dictionaries[$dictionaryId] ?? null;
            if ($dictionaryPayload === null) {
                throw $this->referenceError('dict_id', $dictionaryId);
            }
            $dictionary = decode_trained_dictionary_payload($dictionaryPayload);
            $strings = decode_trained_dictionary_block($reader->readBytes(), $dictionary);
            $values = new TypedVectorData(kind: ElementType::STRING, strings: $strings);
        } else {
            throw invalid_data('column payload mode');
        }
        return new Column(
            fieldId: $fieldId,
            nullStrategy: $nullStrategy,
            presence: $presence,
            hasPresence: $hasPresence,
            codec: $codec,
            dictionaryId: $dictionaryId,
            values: $values,
        );
    }

    private function writeControl(ControlMessage $control, ByteBuffer $out): void
    {
        $out->append((int) $control->opcode->value);
        switch ($control->opcode) {
            case ControlOpcode::REGISTER_KEYS:
                encode_varuint(count($control->registerKeys), $out);
                foreach ($control->registerKeys as $key) {
                    encode_string($key, $out);
                    $this->state->keyTable->register($key);
                }
                break;
            case ControlOpcode::REGISTER_SHAPE:
                if ($control->registerShape === null) {
                    throw invalid_data('register shape payload missing');
                }
                encode_varuint($control->registerShape->shapeId, $out);
                encode_varuint(count($control->registerShape->keys), $out);
                $keys = [];
                foreach ($control->registerShape->keys as $keyRef) {
                    $this->writeKeyRef($keyRef, $out);
                    $keys[] = $keyRef->literal;
                }
                $this->state->shapeTable->registerWithId($control->registerShape->shapeId, $keys);
                break;
            case ControlOpcode::REGISTER_STRINGS:
                encode_varuint(count($control->registerStrings), $out);
                foreach ($control->registerStrings as $value) {
                    encode_string($value, $out);
                    $this->state->stringTable->register($value);
                }
                break;
            case ControlOpcode::PROMOTE_STRING_FIELD_TO_ENUM:
                if ($control->promoteStringFieldToEnum === null) {
                    throw invalid_data('promote enum payload missing');
                }
                encode_string($control->promoteStringFieldToEnum->fieldIdentity, $out);
                encode_varuint(count($control->promoteStringFieldToEnum->values), $out);
                foreach ($control->promoteStringFieldToEnum->values as $value) {
                    encode_string($value, $out);
                }
                $this->state->fieldEnums[$control->promoteStringFieldToEnum->fieldIdentity] =
                    $control->promoteStringFieldToEnum->values;
                break;
            case ControlOpcode::RESET_TABLES:
                reset_tables($this->state);
                break;
            case ControlOpcode::RESET_STATE:
                reset_state($this->state);
                break;
        }
    }

    private function readControl(Reader $reader): ControlMessage
    {
        [$opcode, $opOk] = control_opcode_from_byte($reader->readU8());
        if (!$opOk) {
            throw invalid_data('control opcode');
        }
        $control = new ControlMessage(opcode: $opcode);
        switch ($opcode) {
            case ControlOpcode::REGISTER_KEYS:
                $n = $reader->readCount();
                $keys = [];
                for ($i = 0; $i < $n; $i++) {
                    $key = $reader->readString();
                    $keys[] = $key;
                    $this->state->keyTable->register($key);
                }
                $control->registerKeys = $keys;
                break;
            case ControlOpcode::REGISTER_SHAPE:
                $registerShape = new RegisterShapeControl(shapeId: $reader->readVaruint(), keys: []);
                $n = $reader->readCount();
                $keyNames = [];
                for ($i = 0; $i < $n; $i++) {
                    $key = $this->readKeyRef($reader);
                    $registerShape->keys[] = $key;
                    $keyNames[] = $key->literal;
                }
                $this->state->shapeTable->registerWithId($registerShape->shapeId, $keyNames);
                $control->registerShape = $registerShape;
                break;
            case ControlOpcode::REGISTER_STRINGS:
                $n = $reader->readCount();
                $strings = [];
                for ($i = 0; $i < $n; $i++) {
                    $value = $reader->readString();
                    $strings[] = $value;
                    $this->state->stringTable->register($value);
                }
                $control->registerStrings = $strings;
                break;
            case ControlOpcode::PROMOTE_STRING_FIELD_TO_ENUM:
                $promote = new PromoteEnumControl(fieldIdentity: $reader->readString(), values: []);
                $n = $reader->readCount();
                for ($i = 0; $i < $n; $i++) {
                    $promote->values[] = $reader->readString();
                }
                $this->state->fieldEnums[$promote->fieldIdentity] = $promote->values;
                $control->promoteStringFieldToEnum = $promote;
                break;
            case ControlOpcode::RESET_TABLES:
                $control->resetTables = true;
                reset_tables($this->state);
                break;
            case ControlOpcode::RESET_STATE:
                $control->resetState = true;
                reset_state($this->state);
                break;
        }
        return $control;
    }

    private function writeBaseRef(BaseRef $baseRef, ByteBuffer $out): void
    {
        if ($baseRef->previous) {
            $out->append(0);
            return;
        }
        $out->append(1);
        encode_varuint($baseRef->baseId, $out);
    }

    private function readBaseRef(Reader $reader): BaseRef
    {
        $mode = $reader->readU8();
        if ($mode === 0) {
            return base_ref_previous();
        }
        if ($mode === 1) {
            return base_ref_id($reader->readVaruint());
        }
        throw invalid_data('base ref');
    }

    private function writeControlStreamPayload(ControlStreamCodec $codec, string $payload, ByteBuffer $out): void
    {
        $encoded = match ($codec) {
            ControlStreamCodec::PLAIN => $payload,
            ControlStreamCodec::RLE => rle_encode_bytes($payload) ?? $payload,
            ControlStreamCodec::BITPACK => control_bitpack_encode_bytes($payload),
            ControlStreamCodec::HUFFMAN => control_huffman_encode_bytes($payload),
            ControlStreamCodec::FSE => control_fse_encode_bytes($payload),
        };
        encode_bytes($encoded, $out);
    }

    private function readControlStreamPayload(ControlStreamCodec $codec, Reader $reader): string
    {
        $encoded = $reader->readBytes();
        return match ($codec) {
            ControlStreamCodec::PLAIN => $encoded,
            ControlStreamCodec::RLE => rle_decode_bytes($encoded),
            ControlStreamCodec::BITPACK => control_bitpack_decode_bytes($encoded),
            ControlStreamCodec::HUFFMAN => control_huffman_decode_bytes($encoded),
            ControlStreamCodec::FSE => control_fse_decode_bytes($encoded),
        };
    }

    /** @return array{0: int, 1: int, 2: bool} */
    private function bestPrefixBase(string $value): array
    {
        $bestId = 0;
        $bestLen = 0;
        foreach ($this->state->stringTable->byId as $id => $candidate) {
            $n = common_prefix_len($value, $candidate);
            if ($n > $bestLen) {
                $bestLen = $n;
                $bestId = $id;
            }
        }
        if ($bestLen === 0) {
            return [0, 0, false];
        }
        return [$bestId, $bestLen, true];
    }

    /** @param list<PatchOperation> $operations @param list<Value> $literals */
    private function applyStatePatch(BaseRef $baseRef, array $operations, array $literals): Message
    {
        if ($baseRef->previous) {
            if ($this->state->previousMessage === null) {
                throw $this->referenceError('previous', 0);
            }
            $base = $this->state->previousMessage->clone();
        } else {
            [$base, $ok] = get_base_snapshot($this->state, $baseRef->baseId);
            if (!$ok) {
                throw $this->referenceError('base_id', $baseRef->baseId);
            }
        }
        $fields = message_fields($base);
        foreach ($operations as $operation) {
            $idx = $operation->fieldId;
            switch ($operation->opcode) {
                case PatchOpcode::KEEP:
                    break;
                case PatchOpcode::REPLACE_SCALAR:
                case PatchOpcode::REPLACE_VECTOR:
                case PatchOpcode::INSERT_FIELD:
                case PatchOpcode::STRING_REF:
                case PatchOpcode::PREFIX_DELTA:
                    if ($operation->value === null) {
                        throw invalid_data('patch operation missing value');
                    }
                    if ($idx < count($fields)) {
                        $fields[$idx] = $operation->value->clone();
                    } elseif ($idx === count($fields)) {
                        $fields[] = $operation->value->clone();
                    } else {
                        throw invalid_data('patch field index out of range');
                    }
                    break;
                case PatchOpcode::DELETE_FIELD:
                    if ($idx < 0 || $idx >= count($fields)) {
                        throw invalid_data('delete field index out of range');
                    }
                    array_splice($fields, $idx, 1);
                    break;
                case PatchOpcode::APPEND_VECTOR:
                    if ($operation->value === null || $idx < 0 || $idx >= count($fields)) {
                        throw invalid_data('append vector patch invalid');
                    }
                    if ($fields[$idx]->kind !== ValueKind::ARRAY || $operation->value->kind !== ValueKind::ARRAY) {
                        throw invalid_data('append vector requires arrays');
                    }
                    foreach ($operation->value->arr as $v) {
                        $fields[$idx]->arr[] = $v->clone();
                    }
                    break;
                case PatchOpcode::TRUNCATE_VECTOR:
                    if ($operation->value === null || $idx < 0 || $idx >= count($fields)) {
                        throw invalid_data('truncate vector patch invalid');
                    }
                    if ($fields[$idx]->kind !== ValueKind::ARRAY || $operation->value->kind !== ValueKind::U64) {
                        throw invalid_data('truncate vector requires array and u64');
                    }
                    $n = $operation->value->u64;
                    if ($n > count($fields[$idx]->arr)) {
                        throw invalid_data('truncate length');
                    }
                    $fields[$idx]->arr = array_slice($fields[$idx]->arr, 0, $n);
                    break;
            }
        }
        return rebuild_message_like($base, $fields);
    }

    /** @param list<string> $keys */
    private function observeDecodeShapeCandidate(array $keys): void
    {
        [, $ok] = $this->state->shapeTable->getId($keys);
        if ($ok) {
            return;
        }
        $observed = $this->state->shapeTable->observe($keys);
        if (should_register_shape($keys, $observed)) {
            $this->state->shapeTable->register($keys);
        }
    }

    /** @param list<string> $keys */
    private function observeEncodeShapeCandidate(array $keys): int
    {
        $sk = shape_key($keys);
        $this->state->encodeShapeObservations[$sk] = ($this->state->encodeShapeObservations[$sk] ?? 0) + 1;
        $count = $this->state->encodeShapeObservations[$sk];
        if (should_register_shape($keys, $count)) {
            $this->state->shapeTable->register($keys);
        }
        return $count;
    }

}
final class SessionEncoder
{
    public TwilicCodec $codec;

    public function __construct(?SessionOptions $options = null)
    {
        $opts = $options ?? default_session_options();
        $this->codec = new TwilicCodec(new_session_state_with_options($opts));
    }

    public function encode(Value $value): string
    {
        $msg = $this->codec->messageForValue($value);
        if ($this->codec->state->options->enableStatePatch
            && $this->codec->state->previousMessage !== null
            && supports_state_patch($this->codec->state->previousMessage, $msg)) {
            [$ops, $_] = diff_message($this->codec->state->previousMessage, $msg);
            $patchMsg = new Message(
                kind: MessageKind::STATE_PATCH,
                statePatch: new StatePatchMessage(baseRef: base_ref_previous(), operations: $ops),
            );
            if (encoded_size($patchMsg) < encoded_size($msg)) {
                try {
                    return $this->codec->encodeMessage($patchMsg);
                } catch (\Throwable) {
                }
            }
        }
        return $this->codec->encodeMessage($msg);
    }

    public function encodeWithSchema(Schema $schema, Value $value): string
    {
        $this->codec->state->schemas[$schema->schemaId] = $schema;
        $this->codec->state->lastSchemaId = $schema->schemaId;
        foreach ($schema->fields as $f) {
            if ($f->enumValues !== []) {
                $this->codec->state->fieldEnums[$f->name] = $f->enumValues;
            }
        }
        if ($value->kind !== ValueKind::MAP) {
            throw invalid_data('encode_with_schema expects map value');
        }
        $presence = [];
        $fields = [];
        $hasPresence = false;
        foreach ($schema->fields as $f) {
            $v = lookup_map_field($value, $f->name);
            if ($v !== null) {
                $presence[] = true;
                $fields[] = $v->clone();
            } else {
                $presence[] = false;
                $hasPresence = true;
            }
        }
        $msg = new Message(
            kind: MessageKind::SCHEMA_OBJECT,
            schemaObject: new SchemaObjectMessage(
                schemaId: $schema->schemaId,
                presence: $presence,
                hasPresence: $hasPresence,
                fields: $fields,
            ),
        );
        return $this->codec->encodeMessage($msg);
    }

    public function encodeBatch(array $values): string
    {
        if ($values === []) {
            $msg = new Message(kind: MessageKind::ROW_BATCH, rowBatch: new RowBatchMessage(rows: []));
            return $this->codec->encodeMessage($msg);
        }
        if (count($values) >= 16) {
            $cols = columns_from_map_values($values);
            if ($cols === null) {
                $cols = rows_to_columns(rows_from_values($values));
            }
            if ($this->codec->state->options->enableTrainedDictionary) {
                apply_dictionary_references($this->codec->state, $cols);
            }
            $msg = new Message(
                kind: MessageKind::COLUMN_BATCH,
                columnBatch: new ColumnBatchMessage(count: count($values), columns: $cols),
            );
        } else {
            $msg = new Message(
                kind: MessageKind::ROW_BATCH,
                rowBatch: new RowBatchMessage(rows: rows_from_values($values)),
            );
        }
        $data = $this->codec->encodeMessage($msg);
        $this->codec->state->previousMessage = $msg->clone();
        $this->codec->state->previousMessageSize = strlen($data);
        $this->recordFullMessageAsBase();
        return $data;
    }

    public function encodePatch(Value $value): string
    {
        $msg = $this->codec->messageForValue($value);
        if ($this->codec->state->previousMessage === null
            || !supports_state_patch($this->codec->state->previousMessage, $msg)) {
            return $this->codec->encodeMessage($msg);
        }
        [$ops, $_] = diff_message($this->codec->state->previousMessage, $msg);
        $patchMsg = new Message(
            kind: MessageKind::STATE_PATCH,
            statePatch: new StatePatchMessage(baseRef: base_ref_previous(), operations: $ops),
        );
        if (encoded_size($patchMsg) >= encoded_size($msg)) {
            return $this->codec->encodeMessage($msg);
        }
        return $this->codec->encodeMessage($patchMsg);
    }

    public function encodeMicroBatch(array $values): string
    {
        if ($values === []) {
            return $this->encodeBatch($values);
        }
        if (!$this->codec->state->options->enableTemplateBatch
            || !has_uniform_micro_batch_shape($values)) {
            return $this->encodeBatch($values);
        }
        $columns = columns_from_map_values($values);
        if ($columns === null) {
            $columns = rows_to_columns(rows_from_values($values));
        }
        if ($this->codec->state->options->enableTrainedDictionary) {
            apply_dictionary_references($this->codec->state, $columns);
        }
        [$templateId, $ok] = find_template_id($this->codec->state->templates, $columns);
        if (!$ok) {
            $templateId = allocate_template_id($this->codec->state);
            $this->codec->state->templates[$templateId] = template_descriptor_from_columns($templateId, $columns);
            $this->codec->state->templateColumns[$templateId] = $columns;
            $mask = array_fill(0, count($columns), true);
            $msg = new Message(
                kind: MessageKind::TEMPLATE_BATCH,
                templateBatch: new TemplateBatchMessage(
                    templateId: $templateId,
                    count: count($values),
                    changedColumnMask: $mask,
                    columns: $columns,
                ),
            );
            return $this->codec->encodeMessage($msg);
        }
        [$mask, $changedCols] = diff_template_columns($this->codec->state->templateColumns[$templateId], $columns);
        $this->codec->state->templateColumns[$templateId] = $columns;
        $msg = new Message(
            kind: MessageKind::TEMPLATE_BATCH,
            templateBatch: new TemplateBatchMessage(
                templateId: $templateId,
                count: count($values),
                changedColumnMask: $mask,
                columns: $changedCols,
            ),
        );
        return $this->codec->encodeMessage($msg);
    }

    public function reset(): void
    {
        reset_state($this->codec->state);
    }

    public function decodeMessage(string $data): Message
    {
        return $this->codec->decodeMessage($data);
    }

    private function recordFullMessageAsBase(): void
    {
        if ($this->codec->state->options->maxBaseSnapshots === 0) {
            return;
        }
        if ($this->codec->state->previousMessage === null) {
            return;
        }
        $baseId = allocate_base_id($this->codec->state);
        register_base_snapshot($this->codec->state, $baseId, $this->codec->state->previousMessage);
    }

}


function new_twilic_codec(): TwilicCodec
{
    return new TwilicCodec(null);
}

function twilic_codec_with_options(SessionOptions $options): TwilicCodec
{
    return new TwilicCodec(new_session_state_with_options($options));
}

function new_session_encoder(?SessionOptions $options = null): SessionEncoder
{
    return new SessionEncoder($options);
}

function reset_encode_shape_observation(TwilicCodec $codec, array $keys): void
{
    unset($codec->state->encodeShapeObservations[shape_key($keys)]);
}
