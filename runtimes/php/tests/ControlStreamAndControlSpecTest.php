<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\TestCase;
use Twilic\ControlMessage;
use Twilic\ControlOpcode;
use Twilic\ControlStreamCodec;
use Twilic\ControlStreamMessage;
use Twilic\Message;
use Twilic\MessageKind;
use Twilic\RegisterShapeControl;
use Twilic\ShapedObjectMessage;
use Twilic\ValueKind;
use function Twilic\key_ref_id;
use function Twilic\key_ref_literal;
use function Twilic\new_reader;
use function Twilic\new_string;
use function Twilic\new_twilic_codec;
use function Twilic\new_u64;
use const Twilic\ErrUnknownReference;

final class ControlStreamAndControlSpecTest extends TestCase
{
    private function encodedControlStreamLen(ControlStreamCodec $streamCodec, string $payload): int
    {
        $codec = new_twilic_codec();
        $msg = new Message(
            kind: MessageKind::CONTROL_STREAM,
            controlStream: new ControlStreamMessage(codec: $streamCodec, payload: $payload),
        );

        return strlen($codec->encodeMessage($msg));
    }

    public function testControlStreamAndControlSpecControlStreamRoundtripsForAllDeclaredCodecs(): void
    {
        $codec = new_twilic_codec();
        $payload = pack('C*', 0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4);
        foreach (
            [
                ControlStreamCodec::PLAIN,
                ControlStreamCodec::RLE,
                ControlStreamCodec::BITPACK,
                ControlStreamCodec::HUFFMAN,
                ControlStreamCodec::FSE,
            ] as $streamCodec
        ) {
            $msg = new Message(
                kind: MessageKind::CONTROL_STREAM,
                controlStream: new ControlStreamMessage(codec: $streamCodec, payload: $payload),
            );
            $data = $codec->encodeMessage($msg);
            $decoded = $codec->decodeMessage($data);
            self::assertTrue(
                TestHelpers::equalMessage($decoded, $msg),
                sprintf('control stream mismatch for codec %s', $streamCodec->name),
            );
        }
    }

    public function testControlStreamAndControlSpecControlStreamBitpackHuffmanFseCompactRepetitivePayloads(): void
    {
        $binaryPayload = '';
        for ($i = 0; $i < 512; $i++) {
            $binaryPayload .= chr($i % 2);
        }
        $plainBinaryLen = $this->encodedControlStreamLen(ControlStreamCodec::PLAIN, $binaryPayload);
        $bitpackLen = $this->encodedControlStreamLen(ControlStreamCodec::BITPACK, $binaryPayload);
        self::assertLessThanOrEqual($plainBinaryLen, $bitpackLen, 'expected bitpack <= plain for binary payload');

        $rleFriendly = str_repeat("\x07", 512);
        $plainRleLen = $this->encodedControlStreamLen(ControlStreamCodec::PLAIN, $rleFriendly);
        $huffmanLen = $this->encodedControlStreamLen(ControlStreamCodec::HUFFMAN, $rleFriendly);
        self::assertLessThanOrEqual($plainRleLen, $huffmanLen, 'expected huffman <= plain for repetitive payload');

        $lowCard = '';
        for ($i = 0; $i < 512; $i++) {
            $lowCard .= chr($i % 4);
        }
        $plainLowCardLen = $this->encodedControlStreamLen(ControlStreamCodec::PLAIN, $lowCard);
        $fseLen = $this->encodedControlStreamLen(ControlStreamCodec::FSE, $lowCard);
        self::assertLessThanOrEqual($plainLowCardLen, $fseLen, 'expected fse <= plain for low-cardinality payload');
    }

    public function testControlStreamAndControlSpecControlStreamFseUsesFseFrameMode(): void
    {
        $codec = new_twilic_codec();
        $payload = '';
        for ($i = 0; $i < 512; $i++) {
            $payload .= chr($i % 4);
        }
        $msg = new Message(
            kind: MessageKind::CONTROL_STREAM,
            controlStream: new ControlStreamMessage(codec: ControlStreamCodec::FSE, payload: $payload),
        );
        $data = $codec->encodeMessage($msg);

        $reader = new_reader($data);
        $kind = $reader->readU8();
        self::assertSame(MessageKind::CONTROL_STREAM->value, $kind);
        $codecByte = $reader->readU8();
        self::assertSame(ControlStreamCodec::FSE->value, $codecByte);
        $framed = $reader->readBytes();
        self::assertGreaterThan(0, strlen($framed), 'expected non-empty framed payload');
    }

    public function testControlStreamAndControlSpecRegisterShapeWithKeyIdsRoundtrips(): void
    {
        $codec = new_twilic_codec();
        $regKeys = new Message(
            kind: MessageKind::CONTROL,
            control: new ControlMessage(
                opcode: ControlOpcode::REGISTER_KEYS,
                registerKeys: ['id', 'name'],
            ),
        );
        $regKeysBytes = $codec->encodeMessage($regKeys);
        $codec->decodeMessage($regKeysBytes);

        $regShape = new Message(
            kind: MessageKind::CONTROL,
            control: new ControlMessage(
                opcode: ControlOpcode::REGISTER_SHAPE,
                registerShape: new RegisterShapeControl(
                    shapeId: 99,
                    keys: [key_ref_id(0), key_ref_id(1)],
                ),
            ),
        );
        $regShapeBytes = $codec->encodeMessage($regShape);
        $decoded = $codec->decodeMessage($regShapeBytes);
        self::assertSame(MessageKind::CONTROL, $decoded->kind);
        self::assertNotNull($decoded->control);
        self::assertNotNull($decoded->control->registerShape);

        $shaped = new Message(
            kind: MessageKind::SHAPED_OBJECT,
            shapedObject: new ShapedObjectMessage(
                shapeId: 99,
                values: [new_u64(1), new_string('alice')],
            ),
        );
        $shapedBytes = $codec->encodeMessage($shaped);
        $value = $codec->decodeValue($shapedBytes);
        self::assertSame(ValueKind::MAP, $value->kind);
    }

    public function testControlStreamAndControlSpecResetStateClearsShapeResolution(): void
    {
        $codec = new_twilic_codec();
        $regShape = new Message(
            kind: MessageKind::CONTROL,
            control: new ControlMessage(
                opcode: ControlOpcode::REGISTER_SHAPE,
                registerShape: new RegisterShapeControl(
                    shapeId: 7,
                    keys: [key_ref_literal('id'), key_ref_literal('name')],
                ),
            ),
        );
        $regBytes = $codec->encodeMessage($regShape);
        $codec->decodeMessage($regBytes);

        $reset = new Message(
            kind: MessageKind::CONTROL,
            control: new ControlMessage(opcode: ControlOpcode::RESET_STATE, resetState: true),
        );
        $resetBytes = $codec->encodeMessage($reset);
        $codec->decodeMessage($resetBytes);

        $shaped = new Message(
            kind: MessageKind::SHAPED_OBJECT,
            shapedObject: new ShapedObjectMessage(
                shapeId: 7,
                values: [new_u64(1), new_string('alice')],
            ),
        );
        $shapedBytes = $codec->encodeMessage($shaped);

        try {
            $codec->decodeValue($shapedBytes);
            self::fail('expected decode error');
        } catch (\Throwable $err) {
            $te = TestHelpers::requireTwilicErrorKind($err, ErrUnknownReference);
            self::assertSame('shape_id', $te->refKind);
            self::assertSame(7, $te->refId);
        }
    }
}
