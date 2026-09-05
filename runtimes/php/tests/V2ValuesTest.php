<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\TestCase;
use function Twilic\decode;
use function Twilic\encode;
use function Twilic\entry;
use function Twilic\equal;
use function Twilic\new_array;
use function Twilic\new_bool;
use function Twilic\new_i64;
use function Twilic\new_map;
use function Twilic\new_null;
use function Twilic\new_string;
use function Twilic\new_u64;

final class V2ValuesTest extends TestCase
{
    /** @param array<string, mixed> $cases */
    private function assertRoundtripCases(array $cases): void
    {
        foreach ($cases as $label => $value) {
            $data = encode($value);
            self::assertTrue(equal($value, decode($data)), $label);
        }
    }

    public function testScalarRoundtrip(): void
    {
        $this->assertRoundtripCases([
            'null' => new_null(),
            'true' => new_bool(true),
            'false' => new_bool(false),
            'i64_neg' => new_i64(-42),
            'i64_pos' => new_i64(128),
            'u64' => new_u64(200),
            'string' => new_string('hello'),
        ]);
    }

    public function testContainerRoundtrip(): void
    {
        $map = new_map(
            entry('a', new_string('1')),
            entry('b', new_u64(2)),
        );
        $array = new_array([new_u64(1), new_u64(2), new_u64(3)]);
        $this->assertRoundtripCases([
            'map' => $map,
            'array' => $array,
        ]);
    }
}
