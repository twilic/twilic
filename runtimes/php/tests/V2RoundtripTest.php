<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\TestCase;
use function Twilic\decode;
use function Twilic\encode;
use function Twilic\entry;
use function Twilic\equal;
use function Twilic\new_map;
use function Twilic\new_string;

final class V2RoundtripTest extends TestCase
{
    public function testEncodeDecodeMapMatchesPythonVector(): void
    {
        $value = new_map(entry('x', new_string('y')));
        $data = encode($value);
        self::assertSame('b181788179', bin2hex($data));
        self::assertTrue(equal($value, decode($data)));
    }
}
