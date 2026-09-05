<?php

declare(strict_types=1);

namespace Twilic;

const V2_NULL_TAG = 0xC0;
const V2_FALSE_TAG = 0xC1;
const V2_TRUE_TAG = 0xC2;
const V2_F64_TAG = 0xC3;
const V2_U8_TAG = 0xC4;
const V2_U16_TAG = 0xC5;
const V2_U32_TAG = 0xC6;
const V2_U64_TAG = 0xC7;
const V2_I8_TAG = 0xC8;
const V2_I16_TAG = 0xC9;
const V2_I32_TAG = 0xCA;
const V2_I64_TAG = 0xCB;
const V2_BIN8_TAG = 0xCC;
const V2_BIN16_TAG = 0xCD;
const V2_BIN32_TAG = 0xCE;
const V2_STR8_TAG = 0xCF;
const V2_STR16_TAG = 0xD0;
const V2_STR32_TAG = 0xD1;
const V2_ARRAY16_TAG = 0xD2;
const V2_ARRAY32_TAG = 0xD3;
const V2_MAP16_TAG = 0xD4;
const V2_MAP32_TAG = 0xD5;
const V2_SHAPE_DEF_TAG = 0xD6;
const V2_KEY_REF_TAG = 0xD8;
const V2_STR_REF_TAG = 0xD9;

final class V2EncodeState
{
    /** @var array<string, int> */
    public array $keyIds = [];
    /** @var array<string, int> */
    public array $strIds = [];
    /** @var array<string, int> */
    public array $shapeIds = [];
    public int $nextKeyId = 0;
    public int $nextStrId = 0;
    public int $nextShapeId = 0;
}

final class V2DecodeState
{
    /** @var list<string> */
    public array $keys = [];
    /** @var list<string> */
    public array $strings = [];
    /** @var list<list<string>|null> */
    public array $shapes = [];
}

function encode_v2(Value $value): string
{
    $out = new ByteBuffer();
    $state = new V2EncodeState();
    encode_v2_value($value, $out, $state);
    return $out->bytes();
}

function decode_v2(string $data): Value
{
    $reader = new_reader($data);
    $state = new V2DecodeState();
    $value = decode_v2_value($reader, $state);
    if (!$reader->isEof()) {
        throw invalid_data('trailing bytes in v2 decode');
    }
    return $value;
}

function encode_v2_value(Value $value, ByteBuffer $out, V2EncodeState $state): void
{
    match ($value->kind) {
        ValueKind::NULL => $out->append(V2_NULL_TAG),
        ValueKind::BOOL => $out->append($value->bool ? V2_TRUE_TAG : V2_FALSE_TAG),
        ValueKind::I64 => encode_v2_i64($value->i64, $out),
        ValueKind::U64 => encode_v2_u64($value->u64, $out),
        ValueKind::F64 => (static function () use ($value, $out): void {
            $out->append(V2_F64_TAG);
            append_f64_le($out, $value->f64);
        })(),
        ValueKind::STRING => (static function () use ($value, $out, $state): void {
            if (isset($state->strIds[$value->str])) {
                $out->append(V2_STR_REF_TAG);
                encode_varuint($state->strIds[$value->str], $out);
                return;
            }
            encode_v2_string_literal($value->str, $out);
            $state->strIds[$value->str] = $state->nextStrId++;
        })(),
        ValueKind::BINARY => encode_v2_binary($value->bin, $out),
        ValueKind::ARRAY => encode_v2_array($value->arr, $out, $state),
        ValueKind::MAP => encode_v2_map($value->map, $out, $state),
        default => throw invalid_data('unsupported value kind'),
    };
}

/** @param list<Value> $values */
function encode_v2_array(array $values, ByteBuffer $out, V2EncodeState $state): void
{
    $shapeKeys = detect_shape_keys($values);
    if ($shapeKeys !== null) {
        $sk = shape_key($shapeKeys);
        if (!isset($state->shapeIds[$sk])) {
            $state->shapeIds[$sk] = $state->nextShapeId++;
        }
        $shapeId = $state->shapeIds[$sk];
        write_v2_array_header(count($values), $out);
        $out->append(V2_SHAPE_DEF_TAG);
        encode_varuint($shapeId, $out);
        encode_varuint(count($shapeKeys), $out);
        foreach ($shapeKeys as $key) {
            encode_v2_key($key, $out, $state);
        }
        foreach ($values as $value) {
            if ($value->kind !== ValueKind::MAP) {
                throw invalid_data('shape array row must be map');
            }
            foreach ($value->map as $field) {
                encode_v2_value($field->value, $out, $state);
            }
        }
        return;
    }
    write_v2_array_header(count($values), $out);
    foreach ($values as $value) {
        encode_v2_value($value, $out, $state);
    }
}

/** @param list<MapEntry> $entries */
function encode_v2_map(array $entries, ByteBuffer $out, V2EncodeState $state): void
{
    write_v2_map_header(count($entries), $out);
    foreach ($entries as $entry) {
        encode_v2_key($entry->key, $out, $state);
        encode_v2_value($entry->value, $out, $state);
    }
}

function encode_v2_key(string $key, ByteBuffer $out, V2EncodeState $state): void
{
    if (isset($state->keyIds[$key])) {
        $out->append(V2_KEY_REF_TAG);
        encode_varuint($state->keyIds[$key], $out);
        return;
    }
    encode_v2_string_literal($key, $out);
    $state->keyIds[$key] = $state->nextKeyId++;
}

function encode_v2_string_literal(string $value, ByteBuffer $out): void
{
    $raw = $value;
    $length = strlen($raw);
    if ($length <= 31) {
        $out->append(0x80 | $length);
    } elseif ($length <= 0xFF) {
        $out->append(V2_STR8_TAG);
        $out->append($length);
    } elseif ($length <= 0xFFFF) {
        $out->append(V2_STR16_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
    } else {
        $out->append(V2_STR32_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
        $out->append(($length >> 16) & 0xFF);
        $out->append(($length >> 24) & 0xFF);
    }
    $out->appendBytes($raw);
}

function encode_v2_binary(string $value, ByteBuffer $out): void
{
    $length = strlen($value);
    if ($length <= 0xFF) {
        $out->append(V2_BIN8_TAG);
        $out->append($length);
    } elseif ($length <= 0xFFFF) {
        $out->append(V2_BIN16_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
    } else {
        $out->append(V2_BIN32_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
        $out->append(($length >> 16) & 0xFF);
        $out->append(($length >> 24) & 0xFF);
    }
    $out->appendBytes($value);
}

function encode_v2_u64(int $value, ByteBuffer $out): void
{
    if ($value <= 127) {
        $out->append($value);
    } elseif ($value <= 0xFF) {
        $out->append(V2_U8_TAG);
        $out->append($value);
    } elseif ($value <= 0xFFFF) {
        $out->append(V2_U16_TAG);
        $out->append($value & 0xFF);
        $out->append(($value >> 8) & 0xFF);
    } elseif ($value <= 0xFFFFFFFF) {
        $out->append(V2_U32_TAG);
        $out->append($value & 0xFF);
        $out->append(($value >> 8) & 0xFF);
        $out->append(($value >> 16) & 0xFF);
        $out->append(($value >> 24) & 0xFF);
    } else {
        $out->append(V2_U64_TAG);
        append_u64_le($out, $value);
    }
}

function encode_v2_i64(int $value, ByteBuffer $out): void
{
    if ($value >= -32 && $value <= -1) {
        $out->append($value & 0xFF);
    } elseif ($value >= 0 && $value <= 127) {
        $out->append($value);
    } elseif ($value >= -128 && $value <= 127) {
        $out->append(V2_I8_TAG);
        $out->append($value & 0xFF);
    } elseif ($value >= -32768 && $value <= 32767) {
        $out->append(V2_I16_TAG);
        $out->append($value & 0xFF);
        $out->append(($value >> 8) & 0xFF);
    } elseif ($value >= -2147483648 && $value <= 2147483647) {
        $out->append(V2_I32_TAG);
        $out->append($value & 0xFF);
        $out->append(($value >> 8) & 0xFF);
        $out->append(($value >> 16) & 0xFF);
        $out->append(($value >> 24) & 0xFF);
    } else {
        $out->append(V2_I64_TAG);
        append_u64_le($out, $value & 0xFFFFFFFFFFFFFFFF);
    }
}

function write_v2_array_header(int $length, ByteBuffer $out): void
{
    if ($length <= 15) {
        $out->append(0xA0 | $length);
    } elseif ($length <= 0xFFFF) {
        $out->append(V2_ARRAY16_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
    } else {
        $out->append(V2_ARRAY32_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
        $out->append(($length >> 16) & 0xFF);
        $out->append(($length >> 24) & 0xFF);
    }
}

function write_v2_map_header(int $length, ByteBuffer $out): void
{
    if ($length <= 15) {
        $out->append(0xB0 | $length);
    } elseif ($length <= 0xFFFF) {
        $out->append(V2_MAP16_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
    } else {
        $out->append(V2_MAP32_TAG);
        $out->append($length & 0xFF);
        $out->append(($length >> 8) & 0xFF);
        $out->append(($length >> 16) & 0xFF);
        $out->append(($length >> 24) & 0xFF);
    }
}

/** @param list<Value> $values */
function detect_shape_keys(array $values): ?array
{
    if (count($values) < 2) {
        return null;
    }
    if ($values[0]->kind !== ValueKind::MAP || $values[0]->map === []) {
        return null;
    }
    $keys = array_map(static fn (MapEntry $e) => $e->key, $values[0]->map);
    foreach (array_slice($values, 1) as $value) {
        if ($value->kind !== ValueKind::MAP || count($value->map) !== count($keys)) {
            return null;
        }
        foreach ($value->map as $i => $e) {
            if ($e->key !== $keys[$i]) {
                return null;
            }
        }
    }
    return $keys;
}

function decode_v2_value(Reader $reader, V2DecodeState $state): Value
{
    return decode_v2_value_from_tag($reader, $state, $reader->readU8());
}

function decode_v2_value_from_tag(Reader $reader, V2DecodeState $state, int $tag): Value
{
    if ($tag <= 0x7F) {
        return new_u64($tag);
    }
    if ($tag >= 0x80 && $tag <= 0x9F) {
        $length = $tag & 0x1F;
        $s = $reader->readExact($length);
        $state->strings[] = $s;
        return new_string($s);
    }
    if ($tag >= 0xA0 && $tag <= 0xAF) {
        return decode_v2_array_body($reader, $state, $tag & 0x0F);
    }
    if ($tag >= 0xB0 && $tag <= 0xBF) {
        return decode_v2_map_body($reader, $state, $tag & 0x0F);
    }
    if ($tag >= 0xE0) {
        return new_i64($tag < 128 ? $tag : $tag - 256);
    }
    return match ($tag) {
        V2_NULL_TAG => new_null(),
        V2_FALSE_TAG => new_bool(false),
        V2_TRUE_TAG => new_bool(true),
        V2_F64_TAG => new_f64(read_f64_le($reader)),
        V2_U8_TAG => new_u64($reader->readU8()),
        V2_U16_TAG => (static function () use ($reader) {
            $b = $reader->readExact(2);
            return new_u64(ord($b[0]) | (ord($b[1]) << 8));
        })(),
        V2_U32_TAG => (static function () use ($reader) {
            $b = $reader->readExact(4);
            return new_u64(ord($b[0]) | (ord($b[1]) << 8) | (ord($b[2]) << 16) | (ord($b[3]) << 24));
        })(),
        V2_U64_TAG => new_u64(read_u64_le($reader)),
        V2_I8_TAG => (static function () use ($reader) {
            $b = $reader->readU8();
            return new_i64($b < 128 ? $b : $b - 256);
        })(),
        V2_I16_TAG => new_i64(unpack('s', $reader->readExact(2))[1]),
        V2_I32_TAG => new_i64(unpack('l', $reader->readExact(4))[1]),
        V2_I64_TAG => new_i64(unpack('q', $reader->readExact(8))[1]),
        V2_BIN8_TAG => new_binary($reader->readExact($reader->readU8())),
        V2_BIN16_TAG => (static function () use ($reader) {
            $b = $reader->readExact(2);
            return new_binary($reader->readExact(ord($b[0]) | (ord($b[1]) << 8)));
        })(),
        V2_BIN32_TAG => (static function () use ($reader) {
            $b = $reader->readExact(4);
            $n = ord($b[0]) | (ord($b[1]) << 8) | (ord($b[2]) << 16) | (ord($b[3]) << 24);
            return new_binary($reader->readExact($n));
        })(),
        V2_STR8_TAG, V2_STR16_TAG, V2_STR32_TAG => decode_v2_string_tag($reader, $state, $tag),
        V2_ARRAY16_TAG => (static function () use ($reader, $state) {
            $b = $reader->readExact(2);
            return decode_v2_array_body($reader, $state, ord($b[0]) | (ord($b[1]) << 8));
        })(),
        V2_ARRAY32_TAG => (static function () use ($reader, $state) {
            $b = $reader->readExact(4);
            $n = ord($b[0]) | (ord($b[1]) << 8) | (ord($b[2]) << 16) | (ord($b[3]) << 24);
            return decode_v2_array_body($reader, $state, $n);
        })(),
        V2_MAP16_TAG => (static function () use ($reader, $state) {
            $b = $reader->readExact(2);
            return decode_v2_map_body($reader, $state, ord($b[0]) | (ord($b[1]) << 8));
        })(),
        V2_MAP32_TAG => (static function () use ($reader, $state) {
            $b = $reader->readExact(4);
            $n = ord($b[0]) | (ord($b[1]) << 8) | (ord($b[2]) << 16) | (ord($b[3]) << 24);
            return decode_v2_map_body($reader, $state, $n);
        })(),
        V2_STR_REF_TAG => (static function () use ($reader, $state) {
            $refId = $reader->readVaruint();
            if ($refId >= count($state->strings)) {
                throw invalid_data('unknown str_ref id');
            }
            return new_string($state->strings[$refId]);
        })(),
        default => throw invalid_tag($tag),
    };
}

function decode_v2_string_tag(Reader $reader, V2DecodeState $state, int $tag): Value
{
    $length = match ($tag) {
        V2_STR8_TAG => $reader->readU8(),
        V2_STR16_TAG => (static function () use ($reader) {
            $b = $reader->readExact(2);
            return ord($b[0]) | (ord($b[1]) << 8);
        })(),
        V2_STR32_TAG => (static function () use ($reader) {
            $b = $reader->readExact(4);
            return ord($b[0]) | (ord($b[1]) << 8) | (ord($b[2]) << 16) | (ord($b[3]) << 24);
        })(),
        default => throw invalid_data('invalid string tag'),
    };
    $s = $reader->readExact($length);
    $state->strings[] = $s;
    return new_string($s);
}

function decode_v2_array_body(Reader $reader, V2DecodeState $state, int $length): Value
{
    $reader->claimOutput($length);
    return $reader->withDepth(fn() => decode_v2_array_bodyInner($reader, $state, $length));
}

function decode_v2_array_bodyInner(Reader $reader, V2DecodeState $state, int $length): Value
{
    if ($length === 0) {
        return new_array([]);
    }
    $firstTag = $reader->readU8();
    if ($firstTag === V2_SHAPE_DEF_TAG) {
        $shapeId = $reader->readCount(65535);
        $keyCount = $reader->readCount(256);
        $keys = [];
        for ($i = 0; $i < $keyCount; $i++) {
            $keys[] = decode_v2_key($reader, $state);
        }
        while (count($state->shapes) <= $shapeId) {
            $state->shapes[] = null;
        }
        $state->shapes[$shapeId] = $keys;
        $values = [];
        for ($i = 0; $i < $length; $i++) {
            $reader->claimOutput(count($keys));
            $row = [];
            foreach ($keys as $key) {
                $row[] = entry($key, decode_v2_value($reader, $state));
            }
            $values[] = new_map(...$row);
        }
        return new_array($values);
    }
    $values = [decode_v2_value_from_tag($reader, $state, $firstTag)];
    for ($i = 1; $i < $length; $i++) {
        $values[] = decode_v2_value($reader, $state);
    }
    return new_array($values);
}

function decode_v2_map_body(Reader $reader, V2DecodeState $state, int $length): Value
{
    $reader->claimOutput($length);
    return $reader->withDepth(fn() => decode_v2_map_bodyInner($reader, $state, $length));
}

function decode_v2_map_bodyInner(Reader $reader, V2DecodeState $state, int $length): Value
{
    $entries = [];
    for ($i = 0; $i < $length; $i++) {
        $entries[] = entry(decode_v2_key($reader, $state), decode_v2_value($reader, $state));
    }
    return new_map(...$entries);
}

function decode_v2_key(Reader $reader, V2DecodeState $state): string
{
    $tag = $reader->readU8();
    if ($tag === V2_KEY_REF_TAG) {
        $refId = $reader->readVaruint();
        if ($refId >= count($state->keys)) {
            throw invalid_data('unknown key_ref id');
        }
        return $state->keys[$refId];
    }
    if ($tag >= 0x80 && $tag <= 0x9F) {
        $length = $tag & 0x1F;
        $key = $reader->readExact($length);
        $state->keys[] = $key;
        return $key;
    }
    if (in_array($tag, [V2_STR8_TAG, V2_STR16_TAG, V2_STR32_TAG], true)) {
        $v = decode_v2_value_from_tag($reader, $state, $tag);
        if ($v->kind !== ValueKind::STRING) {
            throw invalid_data('expected string key');
        }
        $state->keys[] = $v->str;
        return $v->str;
    }
    throw invalid_data('map key must be key_ref or string');
}
