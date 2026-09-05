<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\TestCase;
use Twilic\InteropFixtures;
use Twilic\TwilicCodec;
use function Twilic\equal;
use function Twilic\new_twilic_codec;

final class InteropFixturesTest extends TestCase
{
    public function testCodecEncodeDecodeRoundtrip(): void
    {
        $frames = InteropFixtures::parseInteropFrames(InteropFixtures::emitInteropFixtures());
        $codec = new_twilic_codec();
        foreach ($frames as $frame) {
            if ($frame->stream !== 'codec') {
                continue;
            }
            InteropFixtures::assertInteropCodecDecode($codec, $frame->label, $frame->bytes);
            if ($this->expectsCodecValue($frame->label)) {
                $iso = $this->replayCodecState($frames, $frame->label);
                $got = $iso->decodeValue($frame->bytes);
                $reencoded = $iso->encodeValue($got);
                $roundtrip = $iso->decodeValue($reencoded);
                self::assertTrue(equal($roundtrip, $got), $frame->label . ': roundtrip value mismatch');
            }
        }
    }

    public function testSessionEncodeDecodeRoundtrip(): void
    {
        $frames = InteropFixtures::parseInteropFrames(InteropFixtures::emitInteropFixtures());
        $codec = new_twilic_codec();
        $sessionCount = 0;
        foreach ($frames as $frame) {
            if ($frame->stream !== 'session') {
                continue;
            }
            $sessionCount++;
            InteropFixtures::assertInteropSessionDecode($codec, $frame->label, $frame->bytes);
        }
        self::assertGreaterThan(0, $sessionCount);
    }

    public function testDecodeRustServerFrames(): void
    {
        $root = $this->interopModuleRoot();
        $this->interopRequireTwilicRust($root);
        $rustManifest = $root . '/scripts/rust-server-fixtures/Cargo.toml';
        if (!is_file($rustManifest)) {
            self::markTestSkipped('rust fixtures not available');
        }

        $rustOut = $this->runProcess($root, null, 'cargo', 'run', '--quiet', '--manifest-path', $rustManifest);
        $frames = InteropFixtures::parseInteropFrames($rustOut);
        $codecStream = new_twilic_codec();
        $sessionStream = new_twilic_codec();
        foreach ($frames as $frame) {
            if ($frame->stream === 'codec') {
                InteropFixtures::assertInteropCodecDecode($codecStream, $frame->label, $frame->bytes);
            } elseif ($frame->stream === 'session') {
                InteropFixtures::assertInteropSessionDecode($sessionStream, $frame->label, $frame->bytes);
            } else {
                self::fail('unknown stream ' . $frame->stream);
            }
        }
        self::assertGreaterThan(0, count($frames));
    }

    public function testRustDecodesPhpFramesWithSameValues(): void
    {
        $root = $this->interopModuleRoot();
        $this->interopRequireTwilicRust($root);
        $rustCheck = $root . '/scripts/rust-client-check/Cargo.toml';
        if (!is_file($rustCheck)) {
            self::markTestSkipped('rust client check not available');
        }

        $phpFixtures = InteropFixtures::emitInteropFixtures();
        $out = $this->runProcess(
            $root,
            $phpFixtures,
            'cargo',
            'run',
            '--quiet',
            '--manifest-path',
            $rustCheck,
        );
        self::assertStringContainsString('value checks passed for', $out);
    }

    private function replayCodecState(array $frames, string $stopLabel): TwilicCodec
    {
        $iso = new_twilic_codec();
        foreach ($frames as $frame) {
            if ($frame->stream !== 'codec') {
                continue;
            }
            if ($frame->label === $stopLabel) {
                break;
            }
            if ($frame->label === 'base_snapshot') {
                $iso->decodeMessage($frame->bytes);
                continue;
            }
            if ($this->expectsCodecValue($frame->label)) {
                $iso->decodeValue($frame->bytes);
            }
        }

        return $iso;
    }

    private function expectsCodecValue(string $label): bool
    {
        return $label === 'scalar_string'
            || str_starts_with($label, 'map_two_fields_')
            || str_starts_with($label, 'map_three_fields_')
            || str_starts_with($label, 'bulk_map_');
    }

    private function interopModuleRoot(): string
    {
        return dirname(__DIR__);
    }

    private function interopRequireTwilicRust(string $moduleRoot): void
    {
        if ($this->findExecutable('cargo') === null) {
            self::markTestSkipped('cargo not found in PATH');
        }
        $env = getenv('TWILIC_RUST_ROOT');
        $envRoot = is_string($env) && $env !== '' ? $env : null;
        $sibling = realpath($moduleRoot . '/../rust');
        $found = ($envRoot !== null && is_file($envRoot . '/Cargo.toml'))
            || ($sibling !== false && is_file($sibling . '/Cargo.toml'));
        if (!$found) {
            self::markTestSkipped('Rust runtime not found');
        }
    }

    private function findExecutable(string $command): ?string
    {
        $out = shell_exec('command -v ' . escapeshellarg($command) . ' 2>/dev/null');

        return is_string($out) && trim($out) !== '' ? trim($out) : null;
    }

    /** @param list<string> $command */
    private function runProcess(string $dir, ?string $stdin, string ...$command): string
    {
        $spec = [
            0 => ['pipe', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];
        $process = proc_open($command, $spec, $pipes, $dir);
        if (!is_resource($process)) {
            throw new \RuntimeException('failed to start process');
        }
        if ($stdin !== null) {
            fwrite($pipes[0], $stdin);
        }
        fclose($pipes[0]);
        $stdout = stream_get_contents($pipes[1]);
        $stderr = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $code = proc_close($process);
        $out = ($stdout === false ? '' : $stdout) . ($stderr === false ? '' : $stderr);
        if ($code !== 0) {
            throw new \RuntimeException('command failed (' . $code . '): ' . implode(' ', $command) . "\n" . $out);
        }

        return $out;
    }
}
