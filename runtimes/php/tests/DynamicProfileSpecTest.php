<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\TestCase;
use Twilic\ControlMessage;
use Twilic\ControlOpcode;
use Twilic\Message;
use Twilic\MessageKind;
use Twilic\StringMode;
use function Twilic\entry;
use function Twilic\new_array;
use function Twilic\new_i64;
use function Twilic\new_map;
use function Twilic\new_string;
use function Twilic\new_twilic_codec;
use function Twilic\new_u64;

final class DynamicProfileSpecTest extends TestCase
{
    public function testDynamicProfileShapePromotesAfterSecondThreeFieldMap(): void
    {
        $codec = new_twilic_codec();
        $value = new_map(
            entry('id', new_u64(1)),
            entry('name', new_string('alice')),
            entry('role', new_string('admin')),
        );

        $firstBytes = $codec->encodeValue($value->clone());
        $firstMsg = $codec->decodeMessage($firstBytes);
        self::assertSame(MessageKind::MAP, $firstMsg->kind);

        $secondBytes = $codec->encodeValue($value->clone());
        $secondMsg = $codec->decodeMessage($secondBytes);
        self::assertSame(MessageKind::SHAPED_OBJECT, $secondMsg->kind);

        $thirdBytes = $codec->encodeValue($value->clone());
        $thirdMsg = $codec->decodeMessage($thirdBytes);
        self::assertSame(MessageKind::SHAPED_OBJECT, $thirdMsg->kind);
    }

    public function testDynamicProfileTwoFieldMapKeepsMapAndUsesKeyIds(): void
    {
        $codec = new_twilic_codec();
        $value = new_map(entry('id', new_u64(1)), entry('name', new_string('alice')));

        $firstBytes = $codec->encodeValue($value->clone());
        $firstMsg = $codec->decodeMessage($firstBytes);
        self::assertSame(MessageKind::MAP, $firstMsg->kind);
        foreach ($firstMsg->map as $entryItem) {
            self::assertFalse($entryItem->key->isId, 'expected literal keys on first map');
        }

        $secondBytes = $codec->encodeValue($value->clone());
        $secondMsg = $codec->decodeMessage($secondBytes);
        self::assertContains($secondMsg->kind, [MessageKind::MAP, MessageKind::SHAPED_OBJECT]);
        if ($secondMsg->kind === MessageKind::MAP) {
            foreach ($secondMsg->map as $entryItem) {
                self::assertTrue($entryItem->key->isId, 'expected key ref ids on second map');
            }
        }
    }

    public function testDynamicProfileTypedVectorThresholdIsApplied(): void
    {
        $codec = new_twilic_codec();

        $short = new_array([new_i64(1), new_i64(2), new_i64(3)]);
        $shortBytes = $codec->encodeValue($short);
        $shortMsg = $codec->decodeMessage($shortBytes);
        self::assertSame(MessageKind::ARRAY, $shortMsg->kind);

        $long = new_array([new_i64(1), new_i64(2), new_i64(3), new_i64(4)]);
        $longBytes = $codec->encodeValue($long);
        $longMsg = $codec->decodeMessage($longBytes);
        self::assertSame(MessageKind::TYPED_VECTOR, $longMsg->kind);
    }

    public function testDynamicProfileStringModesEmptyRefAndPrefixDeltaAreUsed(): void
    {
        $codec = new_twilic_codec();

        $emptyBytes = $codec->encodeValue(new_string(''));
        self::assertSame(StringMode::EMPTY->value, TestHelpers::scalarStringMode($emptyBytes));

        $litBytes = $codec->encodeValue(new_string('alpha'));
        self::assertSame(StringMode::LITERAL->value, TestHelpers::scalarStringMode($litBytes));

        $refBytes = $codec->encodeValue(new_string('alpha'));
        self::assertSame(StringMode::REF->value, TestHelpers::scalarStringMode($refBytes));

        $codec->encodeValue(new_string('prefix_common_aaaa'));
        $prefixDeltaBytes = $codec->encodeValue(new_string('prefix_common_bbbb'));
        self::assertSame(StringMode::PREFIX_DELTA->value, TestHelpers::scalarStringMode($prefixDeltaBytes));
    }

    public function testDynamicProfileResetTablesClearsStringInterning(): void
    {
        $codec = new_twilic_codec();

        $codec->encodeValue(new_string('ephemeral'));
        $reusedBytes = $codec->encodeValue(new_string('ephemeral'));
        self::assertSame(StringMode::REF->value, TestHelpers::scalarStringMode($reusedBytes));

        $reset = new Message(
            kind: MessageKind::CONTROL,
            control: new ControlMessage(opcode: ControlOpcode::RESET_TABLES, resetTables: true),
        );
        $resetBytes = $codec->encodeMessage($reset);
        $codec->decodeMessage($resetBytes);

        $afterBytes = $codec->encodeValue(new_string('ephemeral'));
        self::assertSame(StringMode::LITERAL->value, TestHelpers::scalarStringMode($afterBytes));
    }
}
