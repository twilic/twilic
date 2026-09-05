<?php

declare(strict_types=1);

namespace Twilic;

/** Truncate to unsigned 64-bit range on 64-bit PHP (all bits set == -1). */
function u64(int $value): int
{
    return $value & -1;
}

/** Low `width` bits set; width 64 yields all bits. */
function u64_mask_width(int $width): int
{
    if ($width <= 0) {
        return 0;
    }
    if ($width >= 64) {
        return -1;
    }
    $high = 1 << ($width - 1);

    return ($high - 1) + $high;
}

final class WideU128
{
    public function __construct(
        public int $lo = 0,
        public int $hi = 0,
    ) {
        $this->lo = u64($lo);
        $this->hi = u64($hi);
    }

    public static function fromU64(int $v): self
    {
        return new self(lo: $v);
    }

    public static function mask(int $width): self
    {
        if ($width === 0) {
            return new self();
        }
        if ($width <= 64) {
            return new self(lo: u64_mask_width($width));
        }
        return new self(lo: -1, hi: u64_mask_width($width - 64));
    }

    public function isZero(): bool
    {
        return $this->lo === 0 && $this->hi === 0;
    }

    public function and_(self $other): self
    {
        return new self(lo: $this->lo & $other->lo, hi: $this->hi & $other->hi);
    }

    public function or_(self $other): self
    {
        return new self(lo: $this->lo | $other->lo, hi: $this->hi | $other->hi);
    }

    public function shl(int $n): self
    {
        if ($n === 0) {
            return new self(lo: $this->lo, hi: $this->hi);
        }
        if ($n >= 128) {
            return new self();
        }
        if ($n < 64) {
            $hi = u64(($this->hi << $n) | ($this->lo >> (64 - $n)));
            $lo = u64($this->lo << $n);
            return new self(lo: $lo, hi: $hi);
        }
        $n -= 64;
        return new self(lo: 0, hi: u64($this->lo << $n));
    }

    public function shr(int $n): self
    {
        if ($n === 0) {
            return new self(lo: $this->lo, hi: $this->hi);
        }
        if ($n >= 128) {
            return new self();
        }
        if ($n < 64) {
            $lo = u64(($this->lo >> $n) | ($this->hi << (64 - $n)));
            $hi = u64($this->hi >> $n);
            return new self(lo: $lo, hi: $hi);
        }
        $n -= 64;
        return new self(lo: u64($this->hi >> $n), hi: 0);
    }
}

function decode_trained_dictionary_payload(string $payload): array
{
    $reader = new_reader($payload);
    $n = $reader->readCount();
    $values = [];
    for ($i = 0; $i < $n; $i++) {
        $values[] = $reader->readString();
    }
    if (!$reader->isEof()) {
        throw invalid_data('trained dictionary payload trailing bytes');
    }
    return $values;
}

/** @param list<string> $values @param list<string> $dictionary */
/** @return array{0: ?string, 1: bool, 2: null} */
function encode_trained_dictionary_block(array $values, array $dictionary): array
{
    if ($values === []) {
        $out = new ByteBuffer();
        $out->append(0);
        encode_varuint(0, $out);
        return [$out->bytes(), true, null];
    }
    $byValue = [];
    foreach ($dictionary as $idx => $value) {
        $byValue[$value] = $idx;
    }
    $ids = [];
    foreach ($values as $value) {
        if (!array_key_exists($value, $byValue)) {
            return [null, false, null];
        }
        $ids[] = $byValue[$value];
    }
    $raw = new ByteBuffer();
    $raw->append(0);
    encode_varuint(count($ids), $raw);
    foreach ($ids as $refId) {
        encode_varuint($refId, $raw);
    }
    $maxId = $ids === [] ? 0 : max($ids);
    $bitWidth = $maxId === 0 ? 0 : int_bit_length($maxId);
    $packed = new ByteBuffer();
    pack_fixed_width_u64($ids, $bitWidth, $packed);
    $bitpacked = new ByteBuffer();
    $bitpacked->append(1);
    encode_varuint(count($ids), $bitpacked);
    $bitpacked->append($bitWidth);
    $bitpacked->appendBytes($packed->bytes());
    if (strlen($bitpacked->bytes()) < strlen($raw->bytes())) {
        return [$bitpacked->bytes(), true, null];
    }
    return [$raw->bytes(), true, null];
}

/** @param list<string> $dictionary */
function decode_trained_dictionary_block(string $block, array $dictionary): array
{
    $reader = new_reader($block);
    $mode = $reader->readU8();
    $n = $reader->readCount();
    if ($mode === 0) {
        $ids = [];
        for ($i = 0; $i < $n; $i++) {
            $ids[] = $reader->readVaruint();
        }
    } elseif ($mode === 1) {
        $bitWidth = $reader->readU8();
        $remaining = strlen($block) - $reader->position();
        $packed = $reader->readExact($remaining);
        $ids = unpack_fixed_width_u64($packed, $n, $bitWidth);
    } else {
        throw invalid_data('trained dictionary block mode');
    }
    if (!$reader->isEof()) {
        throw invalid_data('trained dictionary block trailing bytes');
    }
    $out = [];
    foreach ($ids as $refId) {
        if ($refId >= count($dictionary)) {
            throw invalid_data('trained dictionary block id');
        }
        $out[] = $dictionary[$refId];
    }
    return $out;
}

/** @param list<int> $values */
function pack_fixed_width_u64(array $values, int $width, ByteBuffer $out): void
{
    if ($width > 64) {
        throw invalid_data('fixed-width u64 bit width');
    }
    if ($width === 0) {
        foreach ($values as $value) {
            if ($value !== 0) {
                throw invalid_data('fixed-width u64 value overflow');
            }
        }
        return;
    }
    $acc = new WideU128();
    $accBits = 0;
    foreach ($values as $value) {
        if ($width < 64 && $value >> $width) {
            throw invalid_data('fixed-width u64 value overflow');
        }
        $acc = $acc->or_(WideU128::fromU64($value)->shl($accBits));
        $accBits += $width;
        while ($accBits >= 8) {
            $out->append($acc->lo & 0xFF);
            $acc = $acc->shr(8);
            $accBits -= 8;
        }
    }
    if ($accBits > 0) {
        $out->append($acc->lo & 0xFF);
    }
}

/** @return list<int> */
function unpack_fixed_width_u64(string $data, int $count, int $width): array
{
    if ($width > 64) {
        throw invalid_data('fixed-width u64 bit width');
    }
    if ($width === 0) {
        foreach (str_split($data) as $b) {
            if (ord($b) !== 0) {
                throw invalid_data('fixed-width u64 trailing bytes');
            }
        }
        return array_fill(0, $count, 0);
    }
    $out = [];
    $acc = new WideU128();
    $accBits = 0;
    $idx = 0;
    $mask = WideU128::mask($width);
    $dataLen = strlen($data);
    for ($i = 0; $i < $count; $i++) {
        while ($accBits < $width) {
            if ($idx >= $dataLen) {
                throw invalid_data('fixed-width u64 underflow');
            }
            $acc = $acc->or_(WideU128::fromU64(ord($data[$idx]))->shl($accBits));
            $idx++;
            $accBits += 8;
        }
        $out[] = $acc->and_($mask)->lo;
        $acc = $acc->shr($width);
        $accBits -= $width;
    }
    if (!$acc->isZero()) {
        throw invalid_data('fixed-width u64 trailing bytes');
    }
    for ($j = $idx; $j < $dataLen; $j++) {
        if (ord($data[$j]) !== 0) {
            throw invalid_data('fixed-width u64 trailing bytes');
        }
    }
    return $out;
}

function int_bit_length(int $n): int
{
    if ($n <= 0) {
        return 0;
    }
    $bits = 0;
    while ($n > 0) {
        $bits++;
        $n >>= 1;
    }
    return $bits;
}

/** @param list<Column> $columns */
function apply_dictionary_references(SessionState $state, array $columns): void
{
    foreach ($columns as $column) {
        if ($column->values->kind !== ElementType::STRING) {
            continue;
        }
        $values = $column->values->strings;
        if (count($values) < 16) {
            continue;
        }
        $unique = array_values(array_unique($values));
        if (count($unique) / count($values) > 0.5) {
            continue;
        }
        if (!in_array($column->codec, [VectorCodec::DICTIONARY, VectorCodec::STRING_REF], true)) {
            continue;
        }
        $dictId = allocate_dictionary_id($state);
        $payload = new ByteBuffer();
        sort($unique);
        encode_varuint(count($unique), $payload);
        foreach ($unique as $item) {
            encode_string($item, $payload);
        }
        $profile = new DictionaryProfile(
            version: 1,
            hash: dictionary_payload_hash($payload->bytes()),
            expiresAt: 0,
            fallback: DictionaryFallbackFailFast,
        );
        if ($state->options->unknownReferencePolicy === UnknownReferencePolicy::STATELESS_RETRY) {
            $profile->fallback = DictionaryFallbackStatelessRetry;
        }
        $state->dictionaries[$dictId] = $payload->bytes();
        $state->dictionaryProfiles[$dictId] = $profile;
        $column->dictionaryId = $dictId;
    }
}

function fnv1a64(string $payload): int
{
    $h = gmp_init('14695981039346656037');
    $prime = gmp_init('1099511628211');
    $mod = gmp_init('18446744073709551615');
    $len = strlen($payload);
    for ($i = 0; $i < $len; $i++) {
        $h = gmp_xor($h, ord($payload[$i]));
        $h = gmp_mod(gmp_mul($h, $prime), $mod);
    }

    return gmp_intval($h);
}

function dictionary_payload_hash(string $payload): int
{
    return fnv1a64($payload);
}
