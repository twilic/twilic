<?php

declare(strict_types=1);

namespace Twilic;

use function count;
use function max;
use function min;
use function strlen;
use function ord;
use function pack;
use function unpack;
use function array_map;
use function array_filter;
use function array_values;
use function array_unique;
use function array_sum;


function column_null_strategy_local(array $values, array $presentBits): array
{
    $nullCount = count(array_filter($values, static fn (Value $v) => $v->kind === ValueKind::NULL));
    if ($nullCount === 0) {
        return [NullStrategy::ALL_PRESENT_ELIDED, null, false];
    }
    if ($nullCount <= (int) (count($values) / 4)) {
        $inverted = array_map(static fn (bool $bit) => !$bit, $presentBits);
        return [NullStrategy::INVERTED_PRESENCE_BITMAP, $inverted, true];
    }
    return [NullStrategy::PRESENCE_BITMAP, $presentBits, true];
}

function strip_nulls_local(array $values): array
{
    return array_values(array_filter($values, static fn (Value $v) => $v->kind !== ValueKind::NULL));
}

/** @param list<list<Value>> $rows @return list<Column>|null */
function rows_to_columns(array $rows): ?array
{
    if ($rows === []) {
        return null;
    }
    $width = max(array_map('count', $rows));
    $columnValues = array_fill(0, $width, []);
    $columnPresence = array_fill(0, $width, []);
    foreach ($rows as $row) {
        for ($col = 0; $col < $width; $col++) {
            $value = $col < count($row) ? $row[$col]->clone() : new_null();
            $columnValues[$col][] = $value;
            $columnPresence[$col][] = $value->kind !== ValueKind::NULL;
        }
    }
    $columns = [];
    for ($col = 0; $col < $width; $col++) {
        [$nullStrategy, $presence, $hasPresence] = column_null_strategy_local($columnValues[$col], $columnPresence[$col]);
        [$codec, $tvd] = infer_column_codec_and_values(strip_nulls_local($columnValues[$col]));
        $columns[] = new Column(
            fieldId: $col,
            nullStrategy: $nullStrategy,
            presence: $presence ?? [],
            hasPresence: $hasPresence,
            codec: $codec,
            dictionaryId: null,
            values: $tvd,
        );
    }
    return $columns;
}

/** @param list<Value> $values @return array{0: VectorCodec, 1: TypedVectorData} */
function infer_column_codec_and_values(array $values): array
{
    if ($values === []) {
        return [VectorCodec::PLAIN, new TypedVectorData(kind: ElementType::VALUE, values: [])];
    }
    $kinds = array_map(static fn (Value $v) => $v->kind, $values);
    if (count(array_filter($kinds, static fn ($k) => $k === ValueKind::I64)) === count($kinds)) {
        $data = array_map(static fn (Value $v) => $v->i64, $values);
        return [select_integer_codec($data), typed_data_i64($data)];
    }
    if (count(array_filter($kinds, static fn ($k) => $k === ValueKind::U64)) === count($kinds)) {
        $data = array_map(static fn (Value $v) => $v->u64, $values);
        return [select_u64_codec($data), typed_data_u64($data)];
    }
    if (count(array_filter($kinds, static fn ($k) => $k === ValueKind::F64)) === count($kinds)) {
        $data = array_map(static fn (Value $v) => $v->f64, $values);
        return [select_float_codec($data), typed_data_f64($data)];
    }
    if (count(array_filter($kinds, static fn ($k) => $k === ValueKind::BOOL)) === count($kinds)) {
        $data = array_map(static fn (Value $v) => $v->bool, $values);
        return [VectorCodec::DIRECT_BITPACK, typed_data_bool($data)];
    }
    if (count(array_filter($kinds, static fn ($k) => $k === ValueKind::STRING)) === count($kinds)) {
        $data = array_map(static fn (Value $v) => $v->str, $values);
        return [select_string_codec($data), typed_data_string($data)];
    }
    $cloned = array_map(static fn (Value $v) => $v->clone(), $values);
    return [VectorCodec::PLAIN, new TypedVectorData(kind: ElementType::VALUE, values: $cloned)];
}

/** @param list<int> $data */
function typed_data_i64(array $data): TypedVectorData
{
    return new TypedVectorData(kind: ElementType::I64, i64s: $data);
}

/** @param list<int> $data */
function typed_data_u64(array $data): TypedVectorData
{
    return new TypedVectorData(kind: ElementType::U64, u64s: $data);
}

/** @param list<float> $data */
function typed_data_f64(array $data): TypedVectorData
{
    return new TypedVectorData(kind: ElementType::F64, f64s: $data);
}

/** @param list<bool> $data */
function typed_data_bool(array $data): TypedVectorData
{
    return new TypedVectorData(kind: ElementType::BOOL, bools: $data);
}

/** @param list<string> $data */
function typed_data_string(array $data): TypedVectorData
{
    return new TypedVectorData(kind: ElementType::STRING, strings: $data);
}

/** @param list<int> $values */
function select_integer_codec(array $values): VectorCodec
{
    if (count($values) < 4) {
        return VectorCodec::PLAIN;
    }
    $deltaVals = deltas($values);
    $dd = deltas($deltaVals);
    $nonZeroDd = 0;
    for ($i = 1; $i < count($dd); $i++) {
        if ($dd[$i] !== 0) {
            $nonZeroDd++;
        }
    }
    $nonZeroRatio = count($dd) > 1 ? $nonZeroDd / (count($dd) - 1) : 0.0;
    $deltaRangeBits = bit_width_signed(min($deltaVals), max($deltaVals));
    if (count($values) >= 8 && ($nonZeroRatio <= 0.25 || $deltaRangeBits <= 2)) {
        return VectorCodec::DELTA_DELTA_BITPACK;
    }
    [$repeatedRatio, $avgRun] = run_stats($values);
    if ($repeatedRatio >= 0.5 && $avgRun >= 3.0) {
        return VectorCodec::RLE;
    }
    $rangeBits = bit_width_signed(min($values), max($values));
    if ($rangeBits <= 60) {
        return VectorCodec::FOR_BITPACK;
    }
    $monotonic = true;
    for ($i = 1; $i < count($values); $i++) {
        if ($values[$i] < $values[$i - 1]) {
            $monotonic = false;
            break;
        }
    }
    if (count($values) >= 8 && $monotonic && $deltaRangeBits <= $rangeBits - 3) {
        return VectorCodec::DELTA_FOR_BITPACK;
    }
    $maxAbsDeltaBits = 0;
    foreach ($deltaVals as $v) {
        $maxAbsDeltaBits = max($maxAbsDeltaBits, bit_width_u64(abs64($v)));
    }
    if ($maxAbsDeltaBits <= 61) {
        return VectorCodec::DELTA_BITPACK;
    }
    $maxBitWidth = 0;
    foreach ($values as $v) {
        $maxBitWidth = max($maxBitWidth, bit_width_u64(abs64($v)));
    }
    if (count($values) >= 8 && $maxBitWidth <= 16 && !$monotonic) {
        return VectorCodec::SIMPLE8B;
    }
    if ($maxBitWidth < 64) {
        return VectorCodec::DIRECT_BITPACK;
    }
    return VectorCodec::PLAIN;
}

/** @param list<int> $values */
function select_u64_codec(array $values): VectorCodec
{
    $allSigned = true;
    foreach ($values as $v) {
        if ($v > 0x7FFFFFFFFFFFFFFF) {
            $allSigned = false;
            break;
        }
    }
    if ($allSigned) {
        return select_integer_codec(array_map(static fn (int $v) => $v & 0x7FFFFFFFFFFFFFFF, $values));
    }
    if (count($values) < 4) {
        return VectorCodec::DIRECT_BITPACK;
    }
    [$repeatedRatio, $avgRun] = run_stats_u64($values);
    if ($repeatedRatio >= 0.5 && $avgRun >= 3.0) {
        return VectorCodec::RLE;
    }
    if (bit_width_u64(max($values) - min($values)) <= 60) {
        return VectorCodec::FOR_BITPACK;
    }
    $maxWidth = 0;
    foreach ($values as $v) {
        $maxWidth = max($maxWidth, bit_width_u64($v));
    }
    if (count($values) >= 8 && $maxWidth <= 16) {
        return VectorCodec::SIMPLE8B;
    }
    if ($maxWidth < 64) {
        return VectorCodec::DIRECT_BITPACK;
    }
    return VectorCodec::PLAIN;
}

/** @param list<float> $values */
function select_float_codec(array $values): VectorCodec
{
    if (count($values) < 4) {
        return VectorCodec::PLAIN;
    }
    $changes = 0;
    $prev = unpack('Q', pack('E', $values[0]))[1];
    for ($i = 1; $i < count($values); $i++) {
        $bits = unpack('Q', pack('E', $values[$i]))[1];
        if ($bits !== $prev) {
            $changes++;
        }
        $prev = $bits;
    }
    return $changes * 2 <= count($values) ? VectorCodec::XOR_FLOAT : VectorCodec::PLAIN;
}

/** @param list<string> $values */
function select_string_codec(array $values): VectorCodec
{
    if ($values === []) {
        return VectorCodec::PLAIN;
    }
    if (count(array_unique($values)) * 2 <= count($values)) {
        return VectorCodec::DICTIONARY;
    }
    $prefixGain = 0;
    $prev = '';
    foreach ($values as $v) {
        $prefixGain += common_prefix_len($prev, $v);
        $prev = $v;
    }
    if ($prefixGain > count($values) * 2) {
        return VectorCodec::PREFIX_DELTA;
    }
    return VectorCodec::PLAIN;
}

/** @param list<int> $values @return list<int> */
function deltas(array $values): array
{
    $out = [];
    foreach ($values as $i => $value) {
        $out[] = $i === 0 ? $value : $value - $values[$i - 1];
    }
    return $out;
}

/** @param list<int> $values @return array{0: float, 1: float} */
function run_stats(array $values): array
{
    if ($values === []) {
        return [0.0, 0.0];
    }
    $runs = [];
    $runLen = 1;
    for ($i = 1; $i < count($values); $i++) {
        if ($values[$i] === $values[$i - 1]) {
            $runLen++;
        } else {
            $runs[] = $runLen;
            $runLen = 1;
        }
    }
    $runs[] = $runLen;
    $repeatedItems = array_sum(array_filter($runs, static fn (int $r) => $r > 1));
    return [$repeatedItems / count($values), array_sum($runs) / count($runs)];
}

/** @param list<int> $values @return array{0: float, 1: float} */
function run_stats_u64(array $values): array
{
    return run_stats($values);
}

function bit_width_signed(int $min, int $max): int
{
    $rangeVal = $max >= $min ? $max - $min : $min - $max;
    return bit_width_u64($rangeVal);
}

function bit_width_u64(int $v): int
{
    if ($v === 0) {
        return 1;
    }
    $bits = 0;
    while ($v > 0) {
        $bits++;
        $v >>= 1;
    }
    return $bits;
}

function abs64(int $v): int
{
    return $v < 0 ? -$v : $v;
}

function common_prefix_len(string $a, string $b): int
{
    $n = min(strlen($a), strlen($b));
    for ($i = 0; $i < $n; $i++) {
        if (ord($a[$i]) !== ord($b[$i])) {
            return $i;
        }
    }
    return $n;
}

function rle_encode_bytes(string $input): ?string
{
    if ($input === '') {
        return null;
    }
    $out = '';
    $i = 0;
    $len = strlen($input);
    while ($i < $len) {
        $j = $i + 1;
        while ($j < $len && ord($input[$j]) === ord($input[$i]) && $j - $i < 255) {
            $j++;
        }
        $out .= chr($j - $i) . $input[$i];
        $i = $j;
    }
    return $out;
}

function rle_decode_bytes(string $input): string
{
    $out = '';
    $i = 0;
    $len = strlen($input);
    while ($i < $len) {
        if ($i + 1 >= $len) {
            throw invalid_data('rle payload');
        }
        $run = ord($input[$i]);
        $b = $input[$i + 1];
        $out .= str_repeat($b, $run);
        $i += 2;
    }
    return $out;
}

function control_bitpack_encode_bytes(string $input): string
{
    return $input;
}

function control_bitpack_decode_bytes(string $input): string
{
    return $input;
}

function control_huffman_encode_bytes(string $input): string
{
    return $input;
}

function control_huffman_decode_bytes(string $input): string
{
    return $input;
}

function control_fse_encode_bytes(string $input): string
{
    return $input;
}

function control_fse_decode_bytes(string $input): string
{
    return $input;
}

/** @param list<Column> $columns */
function template_descriptor_from_columns(int $templateId, array $columns): TemplateDescriptor
{
    return new TemplateDescriptor(
        templateId: $templateId,
        fieldIds: array_map(static fn (Column $c) => $c->fieldId, $columns),
        nullStrategies: array_map(static fn (Column $c) => $c->nullStrategy, $columns),
        codecs: array_map(static fn (Column $c) => $c->codec, $columns),
    );
}

/** @param array<int, TemplateDescriptor> $templates @param list<Column> $columns @return array{0: int, 1: bool} */
function find_template_id(array $templates, array $columns): array
{
    $ids = array_keys($templates);
    sort($ids);
    foreach ($ids as $id) {
        $t = $templates[$id];
        if (count($t->fieldIds) !== count($columns)) {
            continue;
        }
        $ok = true;
        foreach ($t->fieldIds as $i => $fid) {
            if ($fid !== $columns[$i]->fieldId || $t->nullStrategies[$i] !== $columns[$i]->nullStrategy) {
                $ok = false;
                break;
            }
        }
        if ($ok) {
            return [$id, true];
        }
    }
    return [0, false];
}

/** @param list<Column> $previous @param list<Column> $current @return array{0: list<bool>, 1: list<Column>} */
function diff_template_columns(array $previous, array $current): array
{
    $mask = [];
    $changed = [];
    foreach ($current as $i => $col) {
        if ($i >= count($previous) || estimate_column_size($previous[$i]) !== estimate_column_size($col)) {
            $mask[] = true;
            $changed[] = $col;
        } else {
            $mask[] = false;
        }
    }
    return [$mask, $changed];
}

/** @param list<Column> $previous @param list<bool> $changedMask @param list<Column> $changed @return list<Column> */
function merge_template_columns(array $previous, array $changedMask, array $changed): array
{
    $out = [];
    $idx = 0;
    foreach ($changedMask as $i => $bit) {
        if ($bit) {
            if ($idx >= count($changed)) {
                throw invalid_data('template changed column count mismatch');
            }
            $out[] = $changed[$idx++];
        } else {
            if ($i >= count($previous)) {
                throw invalid_data('template reference out of range');
            }
            $out[] = $previous[$i];
        }
    }
    return $out;
}

/** @return array{0: list<PatchOperation>, 1: int} */
function diff_message(Message $prev, Message $current): array
{
    $a = message_fields($prev);
    $b = message_fields($current);
    $n = max(count($a), count($b));
    $ops = [];
    for ($i = 0; $i < $n; $i++) {
        if ($i < count($a) && $i < count($b)) {
            if (equal($a[$i], $b[$i])) {
                $ops[] = new PatchOperation(fieldId: $i, opcode: PatchOpcode::KEEP);
            } else {
                $ops[] = new PatchOperation(fieldId: $i, opcode: PatchOpcode::REPLACE_SCALAR, value: $b[$i]->clone());
            }
        } elseif ($i < count($b)) {
            $ops[] = new PatchOperation(fieldId: $i, opcode: PatchOpcode::INSERT_FIELD, value: $b[$i]->clone());
        } else {
            $ops[] = new PatchOperation(fieldId: $i, opcode: PatchOpcode::DELETE_FIELD);
        }
    }
    return [$ops, 0];
}

/** @return list<Value> */
function message_fields(Message $message): array
{
    return match ($message->kind) {
        MessageKind::ARRAY => array_map(static fn (Value $v) => $v->clone(), $message->array),
        MessageKind::MAP => array_map(static fn (MessageMapEntry $e) => $e->value->clone(), $message->map),
        MessageKind::SHAPED_OBJECT => array_map(static fn (Value $v) => $v->clone(), $message->shapedObject->values),
        MessageKind::SCHEMA_OBJECT => array_map(static fn (Value $v) => $v->clone(), $message->schemaObject->fields),
        default => [],
    };
}

/** @param list<Value> $fields */
function rebuild_message_like(Message $base, array $fields): Message
{
    return match ($base->kind) {
        MessageKind::ARRAY => new Message(kind: MessageKind::ARRAY, array: $fields),
        MessageKind::MAP => (function () use ($base, $fields): Message {
            $entries = [];
            foreach ($fields as $i => $value) {
                if ($i >= count($base->map)) {
                    throw invalid_data('patch map shape mismatch');
                }
                $entries[] = new MessageMapEntry(key: $base->map[$i]->key, value: $value);
            }
            return new Message(kind: MessageKind::MAP, map: $entries);
        })(),
        MessageKind::SHAPED_OBJECT => new Message(
            kind: MessageKind::SHAPED_OBJECT,
            shapedObject: new ShapedObjectMessage(
                shapeId: $base->shapedObject->shapeId,
                presence: $base->shapedObject->presence,
                hasPresence: $base->shapedObject->hasPresence,
                values: $fields,
            ),
        ),
        MessageKind::SCHEMA_OBJECT => new Message(
            kind: MessageKind::SCHEMA_OBJECT,
            schemaObject: new SchemaObjectMessage(
                schemaId: $base->schemaObject->schemaId,
                presence: $base->schemaObject->presence,
                hasPresence: $base->schemaObject->hasPresence,
                fields: $fields,
            ),
        ),
        default => throw invalid_data('state patch reconstruction unsupported for this message kind'),
    };
}

function estimate_message_size(Message $message): int
{
    return match ($message->kind) {
        MessageKind::SCALAR => 1 + estimate_value_size($message->scalar),
        MessageKind::ARRAY => 1 + varuint_size(count($message->array)) + array_sum(
            array_map(static fn (Value $v) => estimate_value_size($v), $message->array),
        ),
        MessageKind::MAP => 1 + varuint_size(count($message->map)) + array_sum(
            array_map(static fn (MessageMapEntry $e) => encoded_key_ref_size($e->key) + estimate_value_size($e->value), $message->map)
        ),
        MessageKind::STATE_PATCH => (function () use ($message): int {
            $sp = $message->statePatch;
            $total = 1 + 2 + varuint_size(count($sp->operations));
            foreach ($sp->operations as $op) {
                $total += varuint_size($op->fieldId) + 2 + ($op->value !== null ? estimate_value_size($op->value) : 0);
            }
            return $total;
        })(),
        default => 16,
    };
}

function estimate_column_size(Column $column): int
{
    $size = varuint_size($column->fieldId) + 4;
    return match ($column->values->kind) {
        ElementType::BOOL => $size + (int) (count($column->values->bools) / 8) + 2,
        ElementType::I64 => $size + count($column->values->i64s) * 4,
        ElementType::U64 => $size + count($column->values->u64s) * 4,
        ElementType::F64 => $size + count($column->values->f64s) * 8,
        ElementType::STRING => $size + array_sum(
            array_map(static fn (string $s) => encoded_string_size($s), $column->values->strings),
        ),
        default => $size,
    };
}

function estimate_value_size(Value $value): int
{
    return match ($value->kind) {
        ValueKind::NULL, ValueKind::BOOL => 1,
        ValueKind::I64 => 2 + smallest_u64_size(encode_zigzag($value->i64)),
        ValueKind::U64 => 2 + smallest_u64_size($value->u64),
        ValueKind::F64 => 9,
        ValueKind::STRING => 2 + encoded_string_size($value->str),
        ValueKind::BINARY => 1 + encoded_bytes_size(strlen($value->bin)),
        ValueKind::ARRAY => 1 + varuint_size(count($value->arr)) + array_sum(
            array_map(static fn (Value $v) => estimate_value_size($v), $value->arr),
        ),
        ValueKind::MAP => 1 + varuint_size(count($value->map)) + array_sum(
            array_map(static fn (MapEntry $e) => encoded_string_size($e->key) + estimate_value_size($e->value), $value->map)
        ),
        default => 1,
    };
}

function encoded_bytes_size(int $length): int
{
    return varuint_size($length) + $length;
}

function encoded_string_size(string $value): int
{
    return encoded_bytes_size(strlen($value));
}

function encoded_key_ref_size(KeyRef $key): int
{
    if ($key->isId) {
        return 1 + varuint_size($key->id);
    }
    return encoded_string_size($key->literal);
}

function varuint_size(int $value): int
{
    $sz = 1;
    while ($value >= 0x80) {
        $value >>= 7;
        $sz++;
    }
    return $sz;
}

function smallest_u64_size(int $value): int
{
    if ($value <= 0xFF) {
        return 1;
    }
    if ($value <= 0xFFFF) {
        return 2;
    }
    if ($value <= 0xFFFFFFFF) {
        return 4;
    }
    return 8;
}

function key_ref_field_identity(KeyRef $key, SessionState $state): ?string
{
    $s = key_ref_string($key, $state);
    return $s === '' ? null : $s;
}

function key_ref_string(KeyRef $key, SessionState $state): string
{
    if ($key->isId) {
        [$s, $ok] = $state->keyTable->getValue($key->id);
        return $ok ? $s : '';
    }
    return $key->literal;
}

function typed_vector_len(TypedVectorData $data): int
{
    return match ($data->kind) {
        ElementType::BOOL => count($data->bools),
        ElementType::I64 => count($data->i64s),
        ElementType::U64 => count($data->u64s),
        ElementType::F64 => count($data->f64s),
        ElementType::STRING => count($data->strings),
        ElementType::BINARY => count($data->binary),
        ElementType::VALUE => count($data->values),
        default => 0,
    };
}

function lookup_map_field(Value $value, string $key): ?Value
{
    if ($value->kind !== ValueKind::MAP) {
        return null;
    }
    foreach ($value->map as $e) {
        if ($e->key === $key) {
            return $e->value->clone();
        }
    }
    return null;
}

/** @param list<bool> $presence @return list<int> */
function schema_present_field_indices(Schema $schema, array $presence, bool $hasPresence): array
{
    if (!$hasPresence) {
        return range(0, count($schema->fields) - 1);
    }
    if (count($presence) !== count($schema->fields)) {
        throw invalid_data('presence bitmap mismatch for schema');
    }
    $out = [];
    foreach ($presence as $i => $p) {
        if ($p) {
            $out[] = $i;
        }
    }
    return $out;
}

function normalized_logical_type(string $raw): string
{
    return strtolower(trim($raw));
}

/** @param list<Value> $values @return list<list<Value>> */
function rows_from_values(array $values): array
{
    $rows = [];
    foreach ($values as $v) {
        if ($v->kind === ValueKind::ARRAY) {
            $rows[] = array_map(static fn (Value $x) => $x->clone(), $v->arr);
        } else {
            $rows[] = [$v->clone()];
        }
    }
    return $rows;
}

/** @param list<Value> $values @param list<bool> $presentBits @return array{0: NullStrategy, 1: ?list<bool>, 2: bool} */
function column_null_strategy(array $values, array $presentBits): array
{
    $nullCount = count(array_filter($values, static fn (Value $v) => $v->kind === ValueKind::NULL));
    if ($nullCount === 0) {
        return [NullStrategy::ALL_PRESENT_ELIDED, null, false];
    }
    if ($nullCount <= (int) (count($values) / 4)) {
        $inverted = array_map(static fn (bool $b) => !$b, $presentBits);
        return [NullStrategy::INVERTED_PRESENCE_BITMAP, $inverted, true];
    }
    return [NullStrategy::PRESENCE_BITMAP, $presentBits, true];
}

function strip_nulls(array $values): array
{
    return array_values(array_filter($values, static fn (Value $v) => $v->kind !== ValueKind::NULL));
}

/** @param list<Value> $values @return list<Column>|null */
function columns_from_map_values(array $values): ?array
{
    if ($values === []) {
        return null;
    }
    foreach ($values as $v) {
        if ($v->kind !== ValueKind::MAP) {
            return null;
        }
    }
    $keyOrder = [];
    $keyIndex = [];
    $columnValues = [];
    $columnPresence = [];
    foreach ($values as $rowIdx => $row) {
        $present = array_fill(0, count($keyOrder), false);
        foreach ($row->map as $e) {
            $key = $e->key;
            $entryValue = $e->value->clone();
            $colIdx = $keyIndex[$key] ?? null;
            if ($colIdx === null) {
                $colIdx = count($keyOrder);
                $keyOrder[] = $key;
                $keyIndex[$key] = $colIdx;
                $columnValues[] = array_fill(0, $rowIdx, new_null());
                $columnPresence[] = array_fill(0, $rowIdx, false);
                $present[] = false;
            }
            $columnValues[$colIdx][] = $entryValue;
            $columnPresence[$colIdx][] = true;
            $present[$colIdx] = true;
        }
        for ($colIdx = 0; $colIdx < count($keyOrder); $colIdx++) {
            if (!$present[$colIdx]) {
                $columnValues[$colIdx][] = new_null();
                $columnPresence[$colIdx][] = false;
            }
        }
    }
    $columns = [];
    for ($fieldId = 0; $fieldId < count($keyOrder); $fieldId++) {
        $colValues = $columnValues[$fieldId];
        $presentBits = $columnPresence[$fieldId];
        [$nullStrategy, $presence, $hasPresence] = column_null_strategy($colValues, $presentBits);
        [$codec, $tvd] = infer_column_codec_and_values(strip_nulls($colValues));
        $columns[] = new Column(
            fieldId: $fieldId,
            nullStrategy: $nullStrategy,
            presence: $presence ?? [],
            hasPresence: $hasPresence,
            codec: $codec,
            values: $tvd,
        );
    }
    return $columns;
}

/** @param list<Value> $values */
function has_uniform_micro_batch_shape(array $values): bool
{
    if ($values === [] || $values[0]->kind !== ValueKind::MAP) {
        return false;
    }
    $keys = array_map(static fn (MapEntry $e) => $e->key, $values[0]->map);
    for ($i = 1; $i < count($values); $i++) {
        $v = $values[$i];
        if ($v->kind !== ValueKind::MAP || count($v->map) !== count($keys)) {
            return false;
        }
        foreach ($keys as $j => $key) {
            if ($v->map[$j]->key !== $key) {
                return false;
            }
        }
    }
    return true;
}

/** @param list<string> $keys */
function should_register_shape(array $keys, int $observedCount): bool
{
    return $keys !== [] && $observedCount >= 2;
}

function supports_state_patch(?Message $base, Message $current): bool
{
    if ($base === null) {
        return false;
    }
    return $base->kind === $current->kind && in_array($base->kind, [
        MessageKind::MAP,
        MessageKind::SCHEMA_OBJECT,
        MessageKind::SHAPED_OBJECT,
        MessageKind::ARRAY,
    ], true);
}

function encoded_size(Message $message): int
{
    return estimate_message_size($message);
}

function typed_vector_to_value(TypedVector $vector): Value
{
    return match ($vector->elementType) {
        ElementType::BOOL => new_array(array_map(static fn (bool $b) => new_bool($b), $vector->data->bools)),
        ElementType::I64 => new_array(array_map(static fn (int $v) => new_i64($v), $vector->data->i64s)),
        ElementType::U64 => new_array(array_map(static fn (int $v) => new_u64($v), $vector->data->u64s)),
        ElementType::F64 => new_array(array_map(static fn (float $v) => new_f64($v), $vector->data->f64s)),
        ElementType::STRING => new_array(array_map(static fn (string $v) => new_string($v), $vector->data->strings)),
        default => new_array([]),
    };
}

/** @param list<MessageMapEntry> $entries @return list<MapEntry> */
function entries_to_map(array $entries, SessionState $state): array
{
    $out = [];
    foreach ($entries as $e) {
        $key = key_ref_string($e->key, $state);
        $out[] = new MapEntry(key: $key, value: $e->value->clone());
        [, $ok] = $state->keyTable->getId($key);
        if (!$ok) {
            $state->keyTable->register($key);
        }
    }
    return $out;
}

/** @param list<string> $keys @param list<bool> $presence @param list<Value> $values @return list<MapEntry> */
function shape_values_to_map(array $keys, array $presence, bool $hasPresence, array $values): array
{
    $out = [];
    $idx = 0;
    foreach ($keys as $i => $key) {
        if ($hasPresence && $i < count($presence) && !$presence[$i]) {
            continue;
        }
        if ($idx >= count($values)) {
            break;
        }
        $out[] = entry($key, $values[$idx]->clone());
        $idx++;
    }
    return $out;
}

function write_smallest_u64(int $value, ByteBuffer $out): void
{
    if ($value <= 0xFF) {
        $out->append(1);
        $out->append($value);
    } elseif ($value <= 0xFFFF) {
        $out->append(2);
        $out->append($value & 0xFF);
        $out->append(($value >> 8) & 0xFF);
    } elseif ($value <= 0xFFFFFFFF) {
        $out->append(4);
        $out->append($value & 0xFF);
        $out->append(($value >> 8) & 0xFF);
        $out->append(($value >> 16) & 0xFF);
        $out->append(($value >> 24) & 0xFF);
    } else {
        $out->append(8);
        append_u64_le($out, $value);
    }
}

function read_smallest_u64(Reader $reader): int
{
    $size = $reader->readU8();
    return match ($size) {
        1 => $reader->readU8(),
        2 => (function () use ($reader): int {
            $b = $reader->readExact(2);
            return ord($b[0]) | (ord($b[1]) << 8);
        })(),
        4 => (function () use ($reader): int {
            $b = $reader->readExact(4);
            return ord($b[0]) | (ord($b[1]) << 8) | (ord($b[2]) << 16) | (ord($b[3]) << 24);
        })(),
        8 => read_u64_le($reader),
        default => throw invalid_data('smallest u64 size'),
    };
}
