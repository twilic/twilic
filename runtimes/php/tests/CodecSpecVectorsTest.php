<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\TestCase;
use Twilic\Reader;
use Twilic\TwilicError;
use const Twilic\ErrInvalidData;
use Twilic\VectorCodec;
use function Twilic\decode_f64_vector;
use function Twilic\decode_i64_vector;
use function Twilic\decode_u64_vector;
use function Twilic\encode_f64_vector;
use function Twilic\encode_i64_vector;
use function Twilic\encode_u64_vector;
use function Twilic\encode_varuint;
use function Twilic\invalid_data;
use function Twilic\new_reader;
use Twilic\ByteBuffer;

final class CodecSpecVectorsTest extends TestCase
{
    private function requireInvalidData(\Throwable $err): TwilicError
    {
        self::assertInstanceOf(TwilicError::class, $err);
        self::assertSame(ErrInvalidData, $err->kind);
        return $err;
    }

    public function testSimple8bI64RoundtripSmallValues(): void
    {
        $values = [1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5];
        $out = new ByteBuffer();
        encode_i64_vector($values, VectorCodec::SIMPLE8B, $out);
        $decoded = decode_i64_vector(new_reader($out->bytes()), VectorCodec::SIMPLE8B);
        self::assertCount(count($values), $decoded);
        self::assertSame($values, $decoded);
    }

    public function testSimple8bU64RoundtripWithLongZeroRuns(): void
    {
        $values = array_merge(array_fill(0, 130, 0), [1, 2, 3, 4, 5], array_fill(0, 250, 0));
        $out = new ByteBuffer();
        encode_u64_vector($values, VectorCodec::SIMPLE8B, $out);
        $decoded = decode_u64_vector(new_reader($out->bytes()), VectorCodec::SIMPLE8B);
        self::assertSame($values, $decoded);
    }

    public function testSimple8bU64FallsBackForLargeValues(): void
    {
        $values = [1 << 61, (1 << 61) + 7, (1 << 61) + 99];
        $out = new ByteBuffer();
        encode_u64_vector($values, VectorCodec::SIMPLE8B, $out);
        $decoded = decode_u64_vector(new_reader($out->bytes()), VectorCodec::SIMPLE8B);
        self::assertSame($values, $decoded);
    }

    public function testForU64OverflowIsRejected(): void
    {
        // Bytes from Python reference (PHP int cannot represent (1<<64)-1 exactly).
        $payload = hex2bin('ffffffffffffffffff01010101');

        try {
            decode_u64_vector(new_reader($payload), VectorCodec::FOR_BITPACK);
            self::fail('expected decode error');
        } catch (\Throwable $err) {
            $te = $this->requireInvalidData($err);
            self::assertSame('u64 FOR overflow', $te->msg);
        }
    }

    public function testDirectBitpackInvalidWidthIsRejected(): void
    {
        $out = new ByteBuffer();
        encode_varuint(1, $out);
        $out->append(0);

        try {
            decode_i64_vector(new_reader($out->bytes()), VectorCodec::DIRECT_BITPACK);
            self::fail('expected decode error');
        } catch (\Throwable $err) {
            $te = $this->requireInvalidData($err);
            self::assertSame('bitpack width', $te->msg);
        }
    }

    public function testXorFloatRoundtripSmoothSeries(): void
    {
        $values = [];
        for ($i = 0; $i < 64; $i++) {
            $values[] = 1.0 + $i * 0.01;
        }
        $out = new ByteBuffer();
        encode_f64_vector($values, VectorCodec::XOR_FLOAT, $out);
        $decoded = decode_f64_vector(new_reader($out->bytes()), VectorCodec::XOR_FLOAT);
        self::assertCount(count($values), $decoded);
        foreach ($values as $i => $expected) {
            self::assertEqualsWithDelta($expected, $decoded[$i], 1e-9, "index $i");
        }
    }
}
