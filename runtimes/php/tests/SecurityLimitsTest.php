<?php
declare(strict_types=1);
namespace Twilic\Tests;
use PHPUnit\Framework\TestCase;
use Twilic\Reader;
final class SecurityLimitsTest extends TestCase {
    public function testCumulativeBudget(): void {
        $reader = new Reader("\0");
        $reader->claimOutput(100);
        $this->expectException(\Twilic\TwilicError::class);
        $reader->claimOutput(100);
    }
    public function testDepth(): void {
        $this->expectException(\Twilic\TwilicError::class);
        \Twilic\decode(str_repeat(chr(0xa1), 70) . chr(0xc0));
    }
}
