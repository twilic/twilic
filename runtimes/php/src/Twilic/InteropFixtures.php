<?php

declare(strict_types=1);

namespace Twilic;

use function Twilic\equal;
use function Twilic\new_array;
use function Twilic\new_i64;
use function Twilic\new_map;
use function Twilic\new_session_encoder;
use function Twilic\new_string;
use function Twilic\new_twilic_codec;
use function Twilic\new_u64;
use function Twilic\reset_encode_shape_observation;

final class InteropFrame
{
    public function __construct(
        public string $stream,
        public string $label,
        public string $hex,
        public string $bytes,
    ) {
    }
}

final class InteropFixtures
{
    private function __construct()
    {
    }

    public static function interopIdNameMap(int $id, string $name): Value
    {
        return new_map(entry('id', new_u64($id)), entry('name', new_string($name)));
    }

    public static function interopIdNameRoleMap(int $id, string $name, string $role): Value
    {
        return new_map(
            entry('id', new_u64($id)),
            entry('name', new_string($name)),
            entry('role', new_string($role)),
        );
    }

    /** @return list<Value> */
    public static function interopMakeI64Array(int $length, int $start): array
    {
        $out = [];
        for ($i = 0; $i < $length; $i++) {
            $out[] = new_i64($start + $i);
        }

        return $out;
    }

    /** @param list<string> $names @return list<Value> */
    public static function interopMakeUserRows(array $names): array
    {
        $rows = [];
        foreach ($names as $i => $name) {
            $rows[] = new_map(
                entry('id', new_u64($i + 1)),
                entry('name', new_string($name)),
            );
        }

        return $rows;
    }

    public static function emitInteropFixtures(): string
    {
        $out = '';
        $codec = new_twilic_codec();

        self::emitInteropValue($out, 'codec', 'scalar_string', $codec, new_string('alpha'));

        $mapTwo = self::interopIdNameMap(1, 'alice');
        self::emitInteropValue($out, 'codec', 'map_two_fields_first', $codec, $mapTwo);
        reset_encode_shape_observation($codec, ['id', 'name']);
        self::emitInteropValue($out, 'codec', 'map_two_fields_second', $codec, $mapTwo);

        $mapThree = self::interopIdNameRoleMap(1, 'alice', 'admin');
        self::emitInteropValue($out, 'codec', 'map_three_fields_first', $codec, $mapThree);
        reset_encode_shape_observation($codec, ['id', 'name', 'role']);
        self::emitInteropValue($out, 'codec', 'map_three_fields_second', $codec, $mapThree);

        for ($i = 0; $i < 8; $i++) {
            self::emitInteropValue(
                $out,
                'codec',
                'bulk_map_' . $i,
                $codec,
                self::interopIdNameMap(10 + $i, 'user-' . $i),
            );
        }

        $baseSnapshot = new Message(
            kind: MessageKind::BASE_SNAPSHOT,
            baseSnapshot: new BaseSnapshotMessage(
                baseId: 77,
                schemaOrShapeRef: 0,
                payload: new Message(kind: MessageKind::SCALAR, scalar: new_i64(42)),
            ),
        );
        self::emitInteropMessage($out, 'codec', 'base_snapshot', $codec, $baseSnapshot);

        $enc = new_session_encoder();
        self::emitInteropFrame($out, 'session', 'session_base_array', $enc->encode(new_array(self::interopMakeI64Array(100, 0))));

        $oneChangeArr = self::interopMakeI64Array(100, 0);
        $oneChangeArr[0] = new_i64(10_000);
        self::emitInteropFrame(
            $out,
            'session',
            'session_patch_one_change',
            $enc->encodePatch(new_array($oneChangeArr)),
        );

        for ($step = 0; $step < 4; $step++) {
            $iterArr = self::interopMakeI64Array(100, 0);
            $iterArr[$step] = new_i64(20_000 + $step);
            self::emitInteropFrame(
                $out,
                'session',
                'session_patch_iter_' . $step,
                $enc->encodePatch(new_array($iterArr)),
            );
        }

        $manyArr = self::interopMakeI64Array(100, 0);
        for ($i = 0; $i < 12; $i++) {
            $manyArr[$i] = new_i64(10_000 + $i);
        }
        self::emitInteropFrame(
            $out,
            'session',
            'session_patch_many_changes',
            $enc->encodePatch(new_array($manyArr)),
        );

        self::emitInteropFrame(
            $out,
            'session',
            'session_micro_batch_first',
            $enc->encodeMicroBatch(self::interopMakeUserRows(['a', 'b', 'c', 'd'])),
        );
        self::emitInteropFrame(
            $out,
            'session',
            'session_micro_batch_second',
            $enc->encodeMicroBatch(self::interopMakeUserRows(['aa', 'bb', 'cc', 'dd'])),
        );

        return $out;
    }

    /** @return list<InteropFrame> */
    public static function parseInteropFrames(string $input): array
    {
        $frames = [];
        $lines = preg_split("/\r\n|\n|\r/", $input) ?: [];
        foreach ($lines as $i => $line) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            $parts = explode('|', $line, 3);
            if (count($parts) !== 3) {
                throw new \InvalidArgumentException('line ' . ($i + 1) . ': invalid frame');
            }
            $frames[] = new InteropFrame(
                $parts[0],
                $parts[1],
                $parts[2],
                self::decodeInteropHex($parts[2]),
            );
        }
        if ($frames === []) {
            throw new \InvalidArgumentException('no fixture frames found');
        }

        return $frames;
    }

    public static function decodeRustServerInput($input): void
    {
        $text = stream_get_contents($input);
        if ($text === false) {
            throw new \RuntimeException('failed to read stdin');
        }
        self::decodeRustServerFrames($text);
    }

    public static function decodeRustServerFrames(string $input): void
    {
        $frames = self::parseInteropFrames($input);
        $codecStream = new_twilic_codec();
        $sessionStream = new_twilic_codec();
        $decoded = 0;
        foreach ($frames as $frame) {
            if ($frame->stream === 'codec') {
                self::assertInteropCodecDecode($codecStream, $frame->label, $frame->bytes);
            } elseif ($frame->stream === 'session') {
                self::assertInteropSessionDecode($sessionStream, $frame->label, $frame->bytes);
            } else {
                throw new \InvalidArgumentException('unknown stream ' . $frame->stream);
            }
            $decoded++;
        }
        echo sprintf("PHP client decode and value checks passed for %d Rust frames\n", $decoded);
    }

    public static function assertInteropCodecDecode(TwilicCodec $codec, string $label, string $frame): void
    {
        if ($label === 'base_snapshot') {
            $msg = $codec->decodeMessage($frame);
            self::require($msg->kind === MessageKind::BASE_SNAPSHOT, 'expected base snapshot');
            self::require($msg->baseSnapshot !== null, 'missing base snapshot');
            self::require($msg->baseSnapshot->baseId === 77, 'base_id mismatch');
            self::require($msg->baseSnapshot->payload->kind === MessageKind::SCALAR, 'payload kind mismatch');
            self::require($msg->baseSnapshot->payload->scalar?->kind === ValueKind::I64, 'payload scalar kind mismatch');
            self::require($msg->baseSnapshot->payload->scalar->i64 === 42, 'payload mismatch');

            return;
        }

        $controlCodec = self::interopExpectControlStreamCodec($label);
        if ($controlCodec !== null) {
            $msg = $codec->decodeMessage($frame);
            self::require($msg->kind === MessageKind::CONTROL_STREAM, 'expected control stream');
            self::require($msg->controlStream !== null, 'missing control stream');
            self::require($msg->controlStream->codec === $controlCodec, 'control stream codec mismatch for ' . $label);
            self::require($msg->controlStream->payload !== '', 'control stream payload empty for ' . $label);

            return;
        }

        $expected = self::interopExpectCodecValue($label);
        if ($expected === null) {
            throw new \InvalidArgumentException('no codec expectation for label ' . $label);
        }
        $got = $codec->decodeValue($frame);
        self::require(equal($got, $expected), 'decoded value mismatch for ' . $label);
    }

    public static function assertInteropSessionDecode(TwilicCodec $codec, string $label, string $frame): void
    {
        switch ($label) {
            case 'session_base_array':
                $got = $codec->decodeValue($frame);
                $want = new_array(self::interopMakeI64Array(100, 0));
                self::require(equal($got, $want), 'session_base_array value mismatch');
                break;
            case 'session_patch_one_change':
                $msg = $codec->decodeMessage($frame);
                self::require(
                    $msg->kind === MessageKind::STATE_PATCH
                    || $msg->kind === MessageKind::TYPED_VECTOR
                    || $msg->kind === MessageKind::ARRAY,
                    'unexpected message kind for session_patch_one_change',
                );
                break;
            case 'session_patch_many_changes':
            case 'session_micro_batch_first':
            case 'session_micro_batch_second':
                $msg = $codec->decodeMessage($frame);
                if ($label === 'session_patch_many_changes') {
                    self::require(
                        $msg->kind === MessageKind::STATE_PATCH
                        || $msg->kind === MessageKind::TYPED_VECTOR
                        || $msg->kind === MessageKind::ARRAY,
                        'expected patch or array message',
                    );
                } else {
                    self::require($msg->kind === MessageKind::TEMPLATE_BATCH, 'expected template batch');
                    self::require($msg->templateBatch !== null, 'missing template batch');
                    self::require($msg->templateBatch->count === 4, 'expected template batch with 4 rows');
                }
                break;
            default:
                if (str_starts_with($label, 'session_patch_iter_')) {
                    $msg = $codec->decodeMessage($frame);
                    self::require(
                        $msg->kind === MessageKind::STATE_PATCH
                        || $msg->kind === MessageKind::TYPED_VECTOR
                        || $msg->kind === MessageKind::ARRAY,
                        'expected patch or array message',
                    );
                    break;
                }
                throw new \InvalidArgumentException('no session expectation for label ' . $label);
        }
    }

    private static function require(bool $condition, string $message): void
    {
        if (!$condition) {
            throw new \RuntimeException($message);
        }
    }

    private static function emitInteropValue(
        string &$out,
        string $stream,
        string $label,
        TwilicCodec $codec,
        Value $value,
    ): void {
        self::emitInteropFrame($out, $stream, $label, $codec->encodeValue($value));
    }

    private static function emitInteropMessage(
        string &$out,
        string $stream,
        string $label,
        TwilicCodec $codec,
        Message $message,
    ): void {
        self::emitInteropFrame($out, $stream, $label, $codec->encodeMessage($message));
    }

    private static function emitInteropFrame(string &$out, string $stream, string $label, string $bytes): void
    {
        $out .= $stream . '|' . $label . '|';
        $len = strlen($bytes);
        for ($i = 0; $i < $len; $i++) {
            $out .= sprintf('%02x', ord($bytes[$i]));
        }
        $out .= "\n";
    }

    private static function decodeInteropHex(string $hex): string
    {
        if (strlen($hex) % 2 !== 0) {
            throw new \InvalidArgumentException('invalid hex length');
        }
        $decoded = hex2bin($hex);
        if ($decoded === false) {
            throw new \InvalidArgumentException('invalid hex');
        }

        return $decoded;
    }

    private static function interopExpectCodecValue(string $label): ?Value
    {
        if ($label === 'scalar_string') {
            return new_string('alpha');
        }
        if (str_starts_with($label, 'map_two_fields_')) {
            return self::interopIdNameMap(1, 'alice');
        }
        if (str_starts_with($label, 'map_three_fields_')) {
            return self::interopIdNameRoleMap(1, 'alice', 'admin');
        }
        if (str_starts_with($label, 'bulk_map_')) {
            $idx = (int) substr($label, strlen('bulk_map_'));

            return self::interopIdNameMap(10 + $idx, 'user-' . $idx);
        }

        return null;
    }

    private static function interopExpectControlStreamCodec(string $label): ?ControlStreamCodec
    {
        return match ($label) {
            'control_stream_bitpack' => ControlStreamCodec::BITPACK,
            'control_stream_huffman' => ControlStreamCodec::HUFFMAN,
            'control_stream_fse' => ControlStreamCodec::FSE,
            default => null,
        };
    }
}
