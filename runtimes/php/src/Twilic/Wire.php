<?php

declare(strict_types=1);

namespace Twilic;

final class Reader
{
    private string $input;
    private int $offset = 0;
    private int $depth = 0;
    private int $budget;

    public function __construct(string $inputData)
    {
        $this->input = $inputData;
        $this->budget = min(strlen($inputData), 1024) * 1024;
    }

    public function claimOutput(int $count): void
    {
        if ($count < 0 || $count > (1 << 20)) throw invalid_data('decode count limit exceeded');
        if ($count > intdiv($this->budget, 8)) throw invalid_data('decode output ratio exceeded');
        $this->budget -= $count * 8;
    }
    public function readCount(int $maximum = 1 << 20): int
    {
        $count = $this->readVaruint();
        if ($count < 0 || $count > $maximum) throw invalid_data('decode count limit exceeded');
        $this->claimOutput($count);
        return $count;
    }
    public function withDepth(callable $decode): mixed
    {
        if ($this->depth >= 64) throw invalid_data('decode depth limit exceeded');
        $this->depth++;
        try { return $decode(); } finally { $this->depth--; }
    }

    public function position(): int
    {
        return $this->offset;
    }

    public function isEof(): bool
    {
        return $this->offset >= strlen($this->input);
    }

    public function readU8(): int
    {
        if ($this->offset >= strlen($this->input)) {
            throw unexpected_eof();
        }
        $b = ord($this->input[$this->offset]);
        $this->offset++;
        return $b;
    }

    public function readExact(int $n): string
    {
        $end = $this->offset + $n;
        if ($n < 0 || $n > strlen($this->input) - $this->offset) {
            throw unexpected_eof();
        }
        $slice = substr($this->input, $this->offset, $n);
        $this->offset = $end;
        return $slice;
    }

    public function readVaruint(): int
    {
        $shift = 0;
        $result = 0;
        while (true) {
            if ($shift >= 64) {
                throw invalid_data('varuint too large');
            }
            $b = $this->readU8();
            if ($shift === 63 && ($b & 0x7E) !== 0) throw invalid_data("varuint too large");
            $result |= ($b & 0x7F) << $shift;
            if (($b & 0x80) === 0) {
                return $result;
            }
            $shift += 7;
        }
    }

    public function readI64Zigzag(): int
    {
        return decode_zigzag($this->readVaruint());
    }

    public function readBytes(): string
    {
        $n = $this->readVaruint();
        return $this->readExact($n);
    }

    public function readString(): string
    {
        $n = $this->readVaruint();
        $data = $this->readExact($n);
        if (!mb_check_encoding($data, 'UTF-8')) {
            throw utf8_error();
        }
        return $data;
    }

    /** @return list<bool> */
    public function readBitmap(): array
    {
        $bitCount = $this->readCount();
        $byteCount = intdiv($bitCount + 7, 8);
        $raw = $this->readExact($byteCount);
        $bits = array_fill(0, $bitCount, false);
        for ($i = 0; $i < $bitCount; $i++) {
            $bits[$i] = ((ord($raw[intdiv($i, 8)]) >> ($i % 8)) & 1) === 1;
        }
        return $bits;
    }
}

function encode_varuint(int $value, ByteBuffer $out): void
{
    if ($value < 0x80) {
        $out->append($value);
        return;
    }
    while (true) {
        $b = $value & 0x7F;
        $value >>= 7;
        if ($value !== 0) {
            $b |= 0x80;
        }
        $out->append($b);
        if ($value === 0) {
            break;
        }
    }
}

function encode_zigzag(int $value): int
{
    return ($value << 1) ^ ($value >> 63);
}

function decode_zigzag(int $value): int
{
    $u = ($value >> 1) ^ -($value & 1);
    if ($u > PHP_INT_MAX) {
        $u -= 0x10000000000000000;
    }
    return $u;
}

function encode_bytes(string $data, ByteBuffer $out): void
{
    encode_varuint(strlen($data), $out);
    $out->appendBytes($data);
}

function encode_string(string $value, ByteBuffer $out): void
{
    encode_bytes($value, $out);
}

/** @param list<bool> $bits */
function encode_bitmap(array $bits, ByteBuffer $out): void
{
    encode_varuint(count($bits), $out);
    $current = 0;
    foreach ($bits as $i => $bit) {
        if ($bit) {
            $current |= 1 << ($i % 8);
        }
        if ($i % 8 === 7) {
            $out->append($current);
            $current = 0;
        }
    }
    if (count($bits) % 8 !== 0) {
        $out->append($current);
    }
}

function new_reader(string $inputData): Reader
{
    return new Reader($inputData);
}

function read_u64_le(Reader $reader): int
{
    $b = $reader->readExact(8);
    $lo = unpack('V', substr($b, 0, 4))[1];
    $hi = unpack('V', substr($b, 4, 4))[1];
    return $lo + ($hi << 32);
}

function read_f64_le(Reader $reader): float
{
    $arr = unpack('e', $reader->readExact(8));
    return $arr[1];
}

function append_u64_le(ByteBuffer $out, int $v): void
{
    $out->appendBytes(pack('V', $v & 0xFFFFFFFF) . pack('V', ($v >> 32) & 0xFFFFFFFF));
}

function append_f64_le(ByteBuffer $out, float $v): void
{
    $out->appendBytes(pack('e', $v));
}
