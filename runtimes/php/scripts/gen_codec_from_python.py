#!/usr/bin/env python3
"""Generate src/Twilic/Codec.php from twilic-python codec.py (behavior reference)."""

from __future__ import annotations

import pathlib
import textwrap

OUT = pathlib.Path(__file__).resolve().parents[1] / "src" / "Twilic" / "Codec.php"

HEADER = textwrap.dedent(
    """\
    <?php

    declare(strict_types=1);

    namespace Twilic;

    use function count;
    use function max;
    use function min;
    use function ord;
    use function pack;
    use function strlen;
    use function unpack;

    /** @var list<array{count: int, width: int}> */
    const SIMPLE8B_SLOTS = [
        ['count' => 60, 'width' => 1],
        ['count' => 30, 'width' => 2],
        ['count' => 20, 'width' => 3],
        ['count' => 15, 'width' => 4],
        ['count' => 12, 'width' => 5],
        ['count' => 10, 'width' => 6],
        ['count' => 8, 'width' => 7],
        ['count' => 7, 'width' => 8],
        ['count' => 6, 'width' => 10],
        ['count' => 5, 'width' => 12],
        ['count' => 4, 'width' => 15],
        ['count' => 3, 'width' => 20],
        ['count' => 2, 'width' => 30],
        ['count' => 1, 'width' => 60],
    ];

    const U64_MAX = 0xFFFFFFFFFFFFFFFF;

    """
)

# Ported from twilic-python/src/twilic/codec.py — keep in sync with Python behavior.
BODY = r'''
function encode_i64_vector(array $values, VectorCodec $codec, ByteBuffer $out): void
{
    match ($codec) {
        VectorCodec::RLE => encode_i64_rle($values, $out),
        VectorCodec::DIRECT_BITPACK => encode_i64_direct_bitpack($values, $out),
        VectorCodec::DELTA_BITPACK => encode_i64_direct_bitpack(delta($values), $out),
        VectorCodec::FOR_BITPACK => (function () use ($values, $out): void {
            if ($values === []) {
                encode_varuint(0, $out);
                return;
            }
            $minValue = min($values);
            encode_varuint(encode_zigzag($minValue), $out);
            encode_i64_direct_bitpack(array_map(fn (int $v) => $v - $minValue, $values), $out);
        })(),
        VectorCodec::DELTA_FOR_BITPACK => (function () use ($values, $out): void {
            $deltas = delta($values);
            if ($deltas === []) {
                encode_varuint(0, $out);
                return;
            }
            $minValue = min($deltas);
            encode_varuint(encode_zigzag($minValue), $out);
            encode_i64_direct_bitpack(array_map(fn (int $v) => $v - $minValue, $deltas), $out);
        })(),
        VectorCodec::DELTA_DELTA_BITPACK => encode_i64_delta_delta($values, $out),
        VectorCodec::PATCHED_FOR => encode_i64_patched_for($values, $out),
        VectorCodec::SIMPLE8B => encode_i64_simple8b($values, $out),
        VectorCodec::PLAIN, VectorCodec::DICTIONARY, VectorCodec::STRING_REF,
        VectorCodec::PREFIX_DELTA, VectorCodec::XOR_FLOAT => encode_i64_plain($values, $out),
    };
}

function decode_i64_vector(Reader $reader, VectorCodec $codec): array
{
    return match ($codec) {
        VectorCodec::RLE => decode_i64_rle($reader),
        VectorCodec::DIRECT_BITPACK => decode_i64_direct_bitpack($reader),
        VectorCodec::DELTA_BITPACK => undelta(decode_i64_direct_bitpack($reader)),
        VectorCodec::FOR_BITPACK => (function () use ($reader): array {
            $minValue = decode_zigzag($reader->readVaruint());
            if ($reader->isEof()) {
                return [];
            }
            return array_map(fn (int $v) => $v + $minValue, decode_i64_direct_bitpack($reader));
        })(),
        VectorCodec::DELTA_FOR_BITPACK => (function () use ($reader): array {
            $minValue = decode_zigzag($reader->readVaruint());
            if ($reader->isEof()) {
                return [];
            }
            return undelta(array_map(fn (int $v) => $v + $minValue, decode_i64_direct_bitpack($reader)));
        })(),
        VectorCodec::DELTA_DELTA_BITPACK => decode_i64_delta_delta($reader),
        VectorCodec::PATCHED_FOR => decode_i64_patched_for($reader),
        VectorCodec::SIMPLE8B => decode_i64_simple8b($reader),
        VectorCodec::PLAIN, VectorCodec::DICTIONARY, VectorCodec::STRING_REF,
        VectorCodec::PREFIX_DELTA, VectorCodec::XOR_FLOAT => decode_i64_plain($reader),
        default => throw invalid_data('unsupported vector codec'),
    };
}

function encode_u64_vector(array $values, VectorCodec $codec, ByteBuffer $out): void
{
    match ($codec) {
        VectorCodec::RLE => encode_u64_rle($values, $out),
        VectorCodec::DIRECT_BITPACK => encode_u64_direct_bitpack($values, $out),
        VectorCodec::FOR_BITPACK => (function () use ($values, $out): void {
            if ($values === []) {
                encode_varuint(0, $out);
                return;
            }
            $minValue = min($values);
            encode_varuint($minValue, $out);
            encode_u64_direct_bitpack(array_map(fn (int $v) => $v - $minValue, $values), $out);
        })(),
        VectorCodec::PLAIN => encode_u64_plain($values, $out),
        VectorCodec::SIMPLE8B => encode_u64_simple8b($values, $out),
        VectorCodec::DICTIONARY, VectorCodec::STRING_REF, VectorCodec::PREFIX_DELTA,
        VectorCodec::XOR_FLOAT, VectorCodec::DELTA_BITPACK, VectorCodec::DELTA_FOR_BITPACK,
        VectorCodec::DELTA_DELTA_BITPACK, VectorCodec::PATCHED_FOR => encode_u64_plain($values, $out),
    };
}

function decode_u64_vector(Reader $reader, VectorCodec $codec): array
{
    return match ($codec) {
        VectorCodec::RLE => decode_u64_rle($reader),
        VectorCodec::DIRECT_BITPACK => decode_u64_direct_bitpack($reader),
        VectorCodec::FOR_BITPACK => (function () use ($reader): array {
            $minValue = $reader->readVaruint();
            if ($reader->isEof()) {
                return [];
            }
            $out = [];
            foreach (decode_u64_direct_bitpack($reader) as $v) {
                [$sum, $ok] = checked_add_u64($v, $minValue);
                if (!$ok) {
                    throw invalid_data('u64 FOR overflow');
                }
                $out[] = $sum;
            }
            return $out;
        })(),
        VectorCodec::PLAIN => decode_u64_plain($reader),
        VectorCodec::SIMPLE8B => decode_u64_simple8b($reader),
        VectorCodec::DICTIONARY, VectorCodec::STRING_REF, VectorCodec::PREFIX_DELTA,
        VectorCodec::XOR_FLOAT, VectorCodec::DELTA_BITPACK, VectorCodec::DELTA_FOR_BITPACK,
        VectorCodec::DELTA_DELTA_BITPACK, VectorCodec::PATCHED_FOR => decode_u64_plain($reader),
        default => throw invalid_data('unsupported vector codec'),
    };
}

function encode_f64_vector(array $values, VectorCodec $codec, ByteBuffer $out): void
{
    if ($codec === VectorCodec::XOR_FLOAT) {
        encode_xor_float($values, $out);
        return;
    }
    encode_varuint(count($values), $out);
    foreach ($values as $v) {
        append_f64_le($out, $v);
    }
}

/** @return list<float> */
function decode_f64_vector(Reader $reader, VectorCodec $codec): array
{
    if ($codec === VectorCodec::XOR_FLOAT) {
        return decode_xor_float($reader);
    }
    $length = $reader->readVaruint();
    $out = [];
    for ($i = 0; $i < $length; $i++) {
        $out[] = read_f64_le($reader);
    }
    return $out;
}

function encode_u64_plain(array $values, ByteBuffer $out): void
{
    encode_varuint(count($values), $out);
    foreach ($values as $value) {
        encode_varuint($value, $out);
    }
}

/** @return list<int> */
function decode_u64_plain(Reader $reader): array
{
    $length = $reader->readVaruint();
    $out = [];
    for ($i = 0; $i < $length; $i++) {
        $out[] = $reader->readVaruint();
    }
    return $out;
}

function encode_u64_rle(array $values, ByteBuffer $out): void
{
    /** @var list<array{0: int, 1: int}> */
    $runs = [];
    foreach ($values as $value) {
        if ($runs !== [] && $runs[count($runs) - 1][0] === $value) {
            $runs[count($runs) - 1][1]++;
        } else {
            $runs[] = [$value, 1];
        }
    }
    encode_varuint(count($runs), $out);
    foreach ($runs as [$val, $count]) {
        encode_varuint($val, $out);
        encode_varuint($count, $out);
    }
}

/** @return list<int> */
function decode_u64_rle(Reader $reader): array
{
    $runsLen = $reader->readVaruint();
    $out = [];
    for ($i = 0; $i < $runsLen; $i++) {
        $value = $reader->readVaruint();
        $count = $reader->readVaruint();
        for ($j = 0; $j < $count; $j++) {
            $out[] = $value;
        }
    }
    return $out;
}

function encode_u64_direct_bitpack(array $values, ByteBuffer $out): void
{
    encode_varuint(count($values), $out);
    if ($values === []) {
        $out->append(0);
        return;
    }
    $width = 1;
    foreach ($values as $v) {
        $bw = bit_width($v);
        if ($bw > $width) {
            $width = $bw;
        }
    }
    $out->append($width);
    pack_u64_values($values, $width, $out);
}

/** @return list<int> */
function decode_u64_direct_bitpack(Reader $reader): array
{
    $length = $reader->readVaruint();
    $width = $reader->readU8();
    if ($length === 0) {
        return [];
    }
    if ($width === 0 || $width > 64) {
        throw invalid_data('bitpack width');
    }
    return unpack_u64_values($reader, $length, $width);
}

function encode_i64_plain(array $values, ByteBuffer $out): void
{
    encode_varuint(count($values), $out);
    foreach ($values as $value) {
        encode_varuint(encode_zigzag($value), $out);
    }
}

/** @return list<int> */
function decode_i64_plain(Reader $reader): array
{
    $length = $reader->readVaruint();
    $out = [];
    for ($i = 0; $i < $length; $i++) {
        $out[] = decode_zigzag($reader->readVaruint());
    }
    return $out;
}

function encode_i64_simple8b(array $values, ByteBuffer $out): void
{
    $encoded = array_map(encode_zigzag(...), $values);
    encode_u64_simple8b_inner($encoded, $out);
}

/** @return list<int> */
function decode_i64_simple8b(Reader $reader): array
{
    $encoded = decode_u64_simple8b_inner($reader);
    return array_map(decode_zigzag(...), $encoded);
}

function encode_u64_simple8b(array $values, ByteBuffer $out): void
{
    encode_u64_simple8b_inner($values, $out);
}

/** @return list<int> */
function decode_u64_simple8b(Reader $reader): array
{
    return decode_u64_simple8b_inner($reader);
}

function encode_u64_simple8b_inner(array $values, ByteBuffer $out): void
{
    encode_varuint(count($values), $out);
    if ($values === []) {
        return;
    }
    $maxValue = max($values);
    if ($maxValue > (1 << 60) - 1) {
        $out->append(0);
        foreach ($values as $value) {
            encode_varuint($value, $out);
        }
        return;
    }
    $out->append(1);
    $idx = 0;
    $n = count($values);
    while ($idx < $n) {
        $zeroRun = 0;
        while ($idx + $zeroRun < $n && $values[$idx + $zeroRun] === 0 && $zeroRun < 240) {
            $zeroRun++;
        }
        if ($zeroRun >= 120) {
            $take = $zeroRun >= 240 ? 240 : 120;
            $word = $take === 240 ? 0 : (1 << 60);
            append_u64_le($out, $word);
            $idx += $take;
            continue;
        }
        $packed = false;
        foreach (SIMPLE8B_SLOTS as $selectorIdx => $slot) {
            $count = $slot['count'];
            $slotWidth = $slot['width'];
            if ($idx + $count > $n) {
                continue;
            }
            $maxEncodable = $slotWidth === 64 ? U64_MAX : (1 << $slotWidth) - 1;
            $slice = array_slice($values, $idx, $count);
            foreach ($slice as $v) {
                if ($v > $maxEncodable) {
                    continue 2;
                }
            }
            $selector = $selectorIdx + 2;
            $payload = 0;
            $shift = 0;
            foreach ($slice as $value) {
                $payload |= $value << $shift;
                $shift += $slotWidth;
            }
            $word = ($selector << 60) | $payload;
            append_u64_le($out, $word);
            $idx += $count;
            $packed = true;
            break;
        }
        if (!$packed) {
            $selector = 15;
            $word = ($selector << 60) | ($values[$idx] & ((1 << 60) - 1));
            append_u64_le($out, $word);
            $idx++;
        }
    }
}

/** @return list<int> */
function decode_u64_simple8b_inner(Reader $reader): array
{
    $length = $reader->readVaruint();
    if ($length === 0) {
        return [];
    }
    $mode = $reader->readU8();
    if ($mode === 0) {
        $out = [];
        for ($i = 0; $i < $length; $i++) {
            $out[] = $reader->readVaruint();
        }
        return $out;
    }
    if ($mode !== 1) {
        throw invalid_data('simple8b mode');
    }
    $out = [];
    while (count($out) < $length) {
        $packed = read_u64_le($reader);
        $selector = intdiv($packed, 1 << 60);
        $payload = $packed & ((1 << 60) - 1);
        if ($selector === 0 || $selector === 1) {
            $count = $selector === 0 ? 240 : 120;
            $remain = $length - count($out);
            $limit = min($count, $remain);
            for ($i = 0; $i < $limit; $i++) {
                $out[] = 0;
            }
        } elseif ($selector >= 2 && $selector <= 15) {
            if ($selector === 15) {
                $count = 1;
                $width = 60;
            } else {
                $count = SIMPLE8B_SLOTS[$selector - 2]['count'];
                $width = SIMPLE8B_SLOTS[$selector - 2]['width'];
            }
            $mask = $width === 64 ? U64_MAX : (1 << $width) - 1;
            $shift = 0;
            $remain = $length - count($out);
            $limit = min($count, $remain);
            for ($i = 0; $i < $limit; $i++) {
                $out[] = ($payload >> $shift) & $mask;
                $shift += $width;
            }
        } else {
            throw invalid_data('simple8b selector');
        }
    }
    return $out;
}

/** @return list<int> */
function delta(array $values): array
{
    $out = [];
    $prev = 0;
    foreach ($values as $i => $value) {
        if ($i === 0) {
            $out[] = $value;
        } else {
            $out[] = $value - $prev;
        }
        $prev = $value;
    }
    return $out;
}

/** @return list<int> */
function undelta(array $values): array
{
    $out = [];
    $prev = 0;
    foreach ($values as $i => $value) {
        if ($i === 0) {
            $out[] = $value;
            $prev = $value;
            continue;
        }
        [$nxt, $ok] = checked_add_i64($prev, $value);
        if (!$ok) {
            throw invalid_data('delta overflow');
        }
        $out[] = $nxt;
        $prev = $nxt;
    }
    return $out;
}

function encode_i64_rle(array $values, ByteBuffer $out): void
{
    /** @var list<array{0: int, 1: int}> */
    $runs = [];
    foreach ($values as $value) {
        if ($runs !== [] && $runs[count($runs) - 1][0] === $value) {
            $runs[count($runs) - 1][1]++;
        } else {
            $runs[] = [$value, 1];
        }
    }
    encode_varuint(count($runs), $out);
    foreach ($runs as [$val, $count]) {
        encode_varuint(encode_zigzag($val), $out);
        encode_varuint($count, $out);
    }
}

/** @return list<int> */
function decode_i64_rle(Reader $reader): array
{
    $runsLen = $reader->readVaruint();
    $out = [];
    for ($i = 0; $i < $runsLen; $i++) {
        $value = decode_zigzag($reader->readVaruint());
        $count = $reader->readVaruint();
        for ($j = 0; $j < $count; $j++) {
            $out[] = $value;
        }
    }
    return $out;
}

function encode_i64_patched_for(array $values, ByteBuffer $out): void
{
    if ($values === []) {
        encode_varuint(0, $out);
        return;
    }
    $base = min($values);
    $shifted = array_map(fn (int $v) => $v - $base, $values);
    encode_varuint(count($shifted), $out);
    encode_varuint(encode_zigzag($base), $out);
    $maxValue = $shifted === [] ? 0 : max($shifted);
    $bw = bit_width($maxValue);
    $baseWidth = $bw > 2 ? $bw - 2 : 0;
    $out->append($baseWidth);
    /** @var list<array{0: int, 1: int}> */
    $patchPositions = [];
    $mainValues = [];
    foreach ($shifted as $idx => $value) {
        if (bit_width($value) > $baseWidth) {
            $patchPositions[] = [$idx, $value];
            $main = 0;
            if ($baseWidth > 0) {
                $mask = (1 << $baseWidth) - 1;
                $main = $value & $mask;
                if ($main < 0) {
                    $main = 0;
                }
            }
            $mainValues[] = $main;
        } else {
            $mainValues[] = $value;
        }
    }
    foreach ($mainValues as $value) {
        encode_varuint($value, $out);
    }
    encode_varuint(count($patchPositions), $out);
    foreach ($patchPositions as [$pos, $val]) {
        encode_varuint($pos, $out);
        encode_varuint($val, $out);
    }
}

/** @return list<int> */
function decode_i64_patched_for(Reader $reader): array
{
    $length = $reader->readVaruint();
    if ($length === 0) {
        return [];
    }
    $base = decode_zigzag($reader->readVaruint());
    $reader->readU8();
    $values = [];
    for ($i = 0; $i < $length; $i++) {
        $values[] = $reader->readVaruint();
    }
    $patchCount = $reader->readVaruint();
    for ($i = 0; $i < $patchCount; $i++) {
        $pos = $reader->readVaruint();
        $patch = $reader->readVaruint();
        if ($pos < count($values)) {
            $values[$pos] = $patch;
        }
    }
    return array_map(fn (int $v) => $v + $base, $values);
}

function leading_zeros64(int $x): int
{
    if ($x === 0) {
        return 64;
    }
    return 64 - _int_bit_length($x);
}

function trailing_zeros64(int $x): int
{
    if ($x === 0) {
        return 64;
    }
    return _trailing_zeros64($x);
}

function _int_bit_length(int $v): int
{
    if ($v === 0) {
        return 0;
    }
    $bits = 0;
    while ($v > 0) {
        $v >>= 1;
        $bits++;
    }
    return $bits;
}

function _trailing_zeros64(int $x): int
{
    if ($x === 0) {
        return 64;
    }
    $n = 0;
    while (($x & 1) === 0) {
        $x >>= 1;
        $n++;
    }
    return $n;
}

function encode_xor_float(array $values, ByteBuffer $out): void
{
    encode_varuint(count($values), $out);
    if ($values === []) {
        return;
    }
    $firstBits = f64_to_u64($values[0]);
    append_u64_le($out, $firstBits);
    $prev = $firstBits;
    $n = count($values);
    for ($i = 1; $i < $n; $i++) {
        $bitsValue = f64_to_u64($values[$i]);
        $x = $prev ^ $bitsValue;
        if ($x === 0) {
            $out->append(0);
        } else {
            $out->append(1);
            $leading = leading_zeros64($x);
            $trailing = trailing_zeros64($x);
            $width = 64 - ($leading + $trailing);
            encode_varuint($leading, $out);
            encode_varuint($trailing, $out);
            encode_varuint($width, $out);
            $payload = $width === 64 ? $x : ($x >> $trailing) & ((1 << $width) - 1);
            encode_varuint($payload, $out);
        }
        $prev = $bitsValue;
    }
}

/** @return list<float> */
function decode_xor_float(Reader $reader): array
{
    $length = $reader->readVaruint();
    if ($length === 0) {
        return [];
    }
    $firstBits = read_u64_le($reader);
    $out = [u64_to_f64($firstBits)];
    $prev = $firstBits;
    for ($i = 1; $i < $length; $i++) {
        $flag = $reader->readU8();
        $bitsValue = $prev;
        if ($flag !== 0) {
            $leading = $reader->readVaruint();
            $trailing = $reader->readVaruint();
            $width = $reader->readVaruint();
            $payload = $reader->readVaruint();
            if ($leading + $trailing + $width > 64) {
                throw invalid_data('xor-float bit widths');
            }
            $x = $width === 64 ? $payload : $payload << $trailing;
            $bitsValue = $prev ^ $x;
        }
        $out[] = u64_to_f64($bitsValue);
        $prev = $bitsValue;
    }
    return $out;
}

function f64_to_u64(float $v): int
{
    $packed = pack('E', $v);
    $arr = unpack('P', $packed);
    return $arr[1];
}

function u64_to_f64(int $u): float
{
    $packed = pack('P', $u);
    $arr = unpack('E', $packed);
    return $arr[1];
}

function encode_i64_direct_bitpack(array $values, ByteBuffer $out): void
{
    encode_varuint(count($values), $out);
    if ($values === []) {
        $out->append(0);
        return;
    }
    $encoded = array_map(encode_zigzag(...), $values);
    $width = 1;
    foreach ($encoded as $v) {
        $bw = bit_width($v);
        if ($bw > $width) {
            $width = $bw;
        }
    }
    $out->append($width);
    pack_u64_values($encoded, $width, $out);
}

/** @return list<int> */
function decode_i64_direct_bitpack(Reader $reader): array
{
    $length = $reader->readVaruint();
    $width = $reader->readU8();
    if ($length === 0) {
        return [];
    }
    if ($width === 0 || $width > 64) {
        throw invalid_data('bitpack width');
    }
    $encoded = unpack_u64_values($reader, $length, $width);
    return array_map(decode_zigzag(...), $encoded);
}

function encode_i64_delta_delta(array $values, ByteBuffer $out): void
{
    encode_varuint(count($values), $out);
    if ($values === []) {
        return;
    }
    encode_varuint(encode_zigzag($values[0]), $out);
    if (count($values) === 1) {
        return;
    }
    $d1 = $values[1] - $values[0];
    encode_varuint(encode_zigzag($d1), $out);
    $dd = [];
    $prevDelta = $d1;
    $n = count($values);
    for ($i = 1; $i < $n - 1; $i++) {
        $d = $values[$i + 1] - $values[$i];
        $dd[] = $d - $prevDelta;
        $prevDelta = $d;
    }
    encode_i64_direct_bitpack($dd, $out);
}

/** @return list<int> */
function decode_i64_delta_delta(Reader $reader): array
{
    $length = $reader->readVaruint();
    if ($length === 0) {
        return [];
    }
    $first = decode_zigzag($reader->readVaruint());
    if ($length === 1) {
        return [$first];
    }
    $firstDelta = decode_zigzag($reader->readVaruint());
    $dd = decode_i64_direct_bitpack($reader);
    if (count($dd) !== $length - 2) {
        throw invalid_data('delta-delta length');
    }
    $out = [$first];
    $prev = $first;
    [$second, $ok] = checked_add_i64($prev, $firstDelta);
    if (!$ok) {
        throw invalid_data('delta-delta overflow');
    }
    $out[] = $second;
    $prev = $second;
    $prevDelta = $firstDelta;
    foreach ($dd as $ddv) {
        [$d, $ok] = checked_add_i64($prevDelta, $ddv);
        if (!$ok) {
            throw invalid_data('delta-delta overflow');
        }
        [$nxt, $ok] = checked_add_i64($prev, $d);
        if (!$ok) {
            throw invalid_data('delta-delta overflow');
        }
        $out[] = $nxt;
        $prev = $nxt;
        $prevDelta = $d;
    }
    return $out;
}

function pack_u64_values(array $values, int $width, ByteBuffer $out): void
{
    $totalBits = count($values) * $width;
    $byteLen = intdiv($totalBits + 7, 8);
    $bytesArr = str_repeat("\0", $byteLen);
    $bitPos = 0;
    foreach ($values as $value) {
        $written = 0;
        while ($written < $width) {
            $byteIdx = intdiv($bitPos, 8);
            $bitOff = $bitPos % 8;
            $room = 8 - $bitOff;
            $take = min($width - $written, $room);
            $mask = (1 << $take) - 1;
            $part = ($value >> $written) & $mask;
            $bytesArr[$byteIdx] = chr((ord($bytesArr[$byteIdx]) | ($part << $bitOff)) & 0xFF);
            $bitPos += $take;
            $written += $take;
        }
    }
    $out->appendBytes($bytesArr);
}

/** @return list<int> */
function unpack_u64_values(Reader $reader, int $length, int $width): array
{
    $totalBits = $length * $width;
    $byteLen = intdiv($totalBits + 7, 8);
    $raw = $reader->readExact($byteLen);
    $out = [];
    $bitPos = 0;
    for ($i = 0; $i < $length; $i++) {
        $value = 0;
        $written = 0;
        while ($written < $width) {
            $byteIdx = intdiv($bitPos, 8);
            if ($byteIdx >= strlen($raw)) {
                throw invalid_data('bitpack underflow');
            }
            $bitOff = $bitPos % 8;
            $room = 8 - $bitOff;
            $take = min($width - $written, $room);
            $mask = (1 << $take) - 1;
            $part = (ord($raw[$byteIdx]) >> $bitOff) & $mask;
            $value |= $part << $written;
            $bitPos += $take;
            $written += $take;
        }
        $out[] = $value;
    }
    return $out;
}

function bit_width(int $v): int
{
    if ($v === 0) {
        return 1;
    }
    return _int_bit_length($v);
}

/** @return array{0: int, 1: bool} */
function checked_add_u64(int $a, int $b): array
{
    $total = $a + $b;
    if ($total > U64_MAX) {
        return [0, false];
    }
    return [$total, true];
}

/** @return array{0: int, 1: bool} */
function checked_add_i64(int $a, int $b): array
{
    $total = $a + $b;
    if (($b > 0 && $total < $a) || ($b < 0 && $total > $a)) {
        return [0, false];
    }
    return [$total, true];
}
'''


def main() -> None:
    OUT.write_text(HEADER + BODY)
    print("wrote", OUT, "lines", len(OUT.read_text().splitlines()))


if __name__ == "__main__":
    main()
