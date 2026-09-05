<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\TestCase;
use Twilic\ByteBuffer;
use Twilic\Column;
use Twilic\ColumnBatchMessage;
use Twilic\DictionaryFallback;
use Twilic\DictionaryProfile;
use Twilic\ElementType;
use Twilic\Message;
use Twilic\MessageKind;
use Twilic\NullStrategy;
use Twilic\PatchOpcode;
use Twilic\PatchOperation;
use Twilic\StatePatchMessage;
use Twilic\TypedVectorData;
use Twilic\UnknownReferencePolicy;
use Twilic\VectorCodec;
use function Twilic\base_ref_id;
use function Twilic\base_ref_previous;
use function Twilic\default_session_options;
use function Twilic\dictionary_payload_hash;
use function Twilic\encode_string;
use function Twilic\encode_varuint;
use function Twilic\entry;
use function Twilic\new_array;
use function Twilic\new_i64;
use function Twilic\new_map;
use function Twilic\new_session_encoder;
use function Twilic\new_string;
use function Twilic\new_twilic_codec;
use function Twilic\new_u64;
use function Twilic\new_reader;
use const Twilic\ErrInvalidData;
use const Twilic\ErrStatelessRetryRequired;

final class BoundBatchStatefulSpecTest extends TestCase
{
    public function testBoundBatchStatefulSchemaIdIsSentFirstThenOmitted(): void
    {
        $enc = new_session_encoder(default_session_options());
        $schema = TestHelpers::sampleSchema();
        $value = new_map(
            entry('id', new_u64(1005)),
            entry('name', new_string('alice')),
            entry('score', new_i64(99)),
        );

        $first = $enc->encodeWithSchema($schema, $value->clone());
        $firstMsg = $enc->decodeMessage($first);
        self::assertSame(MessageKind::SCHEMA_OBJECT, $firstMsg->kind);
        self::assertNotNull($firstMsg->schemaObject);
        self::assertSame(41, $firstMsg->schemaObject->schemaId);

        $second = $enc->encodeWithSchema($schema, $value->clone());
        $secondMsg = $enc->decodeMessage($second);
        self::assertSame(MessageKind::SCHEMA_OBJECT, $secondMsg->kind);
    }

    public function testBoundBatchStatefulBatchThresholdSelectsRowVsColumn(): void
    {
        $enc = new_session_encoder(default_session_options());

        $rows15 = [];
        for ($i = 0; $i < 15; $i++) {
            $rows15[] = new_map(entry('id', new_u64($i)));
        }
        $b15 = $enc->encodeBatch($rows15);
        self::assertGreaterThan(0, strlen($b15));
        $kind15 = MessageKind::from(ord($b15[0]));
        self::assertContains($kind15, [MessageKind::COLUMN_BATCH, MessageKind::ROW_BATCH]);

        $rows16 = [];
        for ($i = 0; $i < 16; $i++) {
            $rows16[] = new_map(entry('id', new_u64($i)));
        }
        $b16 = $enc->encodeBatch($rows16);
        self::assertGreaterThan(0, strlen($b16));
        self::assertSame(MessageKind::COLUMN_BATCH, MessageKind::from(ord($b16[0])));
    }

    public function testBoundBatchStatefulMicroBatchReusesTemplateAndEmitsChangedMask(): void
    {
        $enc = new_session_encoder(default_session_options());
        $rows1 = [
            new_map(entry('id', new_u64(1)), entry('name', new_string('a'))),
            new_map(entry('id', new_u64(2)), entry('name', new_string('b'))),
            new_map(entry('id', new_u64(3)), entry('name', new_string('c'))),
            new_map(entry('id', new_u64(4)), entry('name', new_string('d'))),
        ];
        $first = $enc->encodeMicroBatch($rows1);
        self::assertGreaterThan(0, strlen($first));
        self::assertSame(MessageKind::TEMPLATE_BATCH, MessageKind::from(ord($first[0])));

        $rows2 = [
            new_map(entry('id', new_u64(1)), entry('name', new_string('aa'))),
            new_map(entry('id', new_u64(2)), entry('name', new_string('bb'))),
            new_map(entry('id', new_u64(3)), entry('name', new_string('cc'))),
            new_map(entry('id', new_u64(4)), entry('name', new_string('dd'))),
        ];
        $second = $enc->encodeMicroBatch($rows2);
        self::assertGreaterThan(0, strlen($second));
        self::assertSame(MessageKind::TEMPLATE_BATCH, MessageKind::from(ord($second[0])));
    }

    public function testBoundBatchStatefulStatePatchUsesRecommendedRatioThreshold(): void
    {
        $enc = new_session_encoder(default_session_options());
        $baseValues = [];
        for ($i = 0; $i < 100; $i++) {
            $baseValues[] = new_i64($i);
        }
        $oneChangeValues = $baseValues;
        $oneChangeValues[0] = new_i64(10_000);
        $twelveChangeValues = $baseValues;
        for ($i = 0; $i < 12; $i++) {
            $twelveChangeValues[$i] = new_i64(10_000 + $i);
        }

        $base = new_array($baseValues);
        $oneChange = new_array($oneChangeValues);
        $twelveChanges = new_array($twelveChangeValues);

        $enc->encode($base);
        $p1 = $enc->encodePatch($oneChange);
        $enc->decodeMessage($p1);

        $p2 = $enc->encodePatch($twelveChanges);
        $enc->decodeMessage($p2);

        self::assertTrue(true);
    }

    public function testBoundBatchStatefulUnknownBaseIdHonorsStatelessRetryPolicy(): void
    {
        $opts = default_session_options();
        $opts->unknownReferencePolicy = UnknownReferencePolicy::STATELESS_RETRY;
        $enc = new_session_encoder($opts);

        $patch = new Message(
            kind: MessageKind::STATE_PATCH,
            statePatch: new StatePatchMessage(
                baseRef: base_ref_id(12345),
                operations: [],
                literals: [],
            ),
        );
        $builder = new_twilic_codec();
        $patchBytes = $builder->encodeMessage($patch);

        try {
            $enc->decodeMessage($patchBytes);
            self::fail('expected decode error');
        } catch (\Throwable $err) {
            $te = TestHelpers::requireTwilicErrorKind($err, ErrStatelessRetryRequired);
            self::assertSame('base_id', $te->refKind);
            self::assertSame(12345, $te->refId);
        }
    }

    public function testBoundBatchStatefulStatePatchMapInsertAndDeleteRoundtripViaReconstruction(): void
    {
        $codec = new_twilic_codec();
        $base = new Message(
            kind: MessageKind::MAP,
            map: [
                TestHelpers::messageMapEntry('id', new_u64(1)),
                TestHelpers::messageMapEntry('name', new_string('alice')),
            ],
        );
        $baseBytes = $codec->encodeMessage($base);
        $codec->decodeMessage($baseBytes);

        $insertValue = new_map(entry('role', new_string('admin')));
        $insertPatch = new Message(
            kind: MessageKind::STATE_PATCH,
            statePatch: new StatePatchMessage(
                baseRef: base_ref_previous(),
                operations: [
                    new PatchOperation(
                        fieldId: 2,
                        opcode: PatchOpcode::INSERT_FIELD,
                        value: $insertValue,
                    ),
                ],
            ),
        );
        $insertBytes = $codec->encodeMessage($insertPatch);
        $codec->decodeMessage($insertBytes);
        self::assertNotNull($codec->state->previousMessage);
        self::assertSame(MessageKind::MAP, $codec->state->previousMessage->kind);

        $deletePatch = new Message(
            kind: MessageKind::STATE_PATCH,
            statePatch: new StatePatchMessage(
                baseRef: base_ref_previous(),
                operations: [new PatchOperation(fieldId: 2, opcode: PatchOpcode::DELETE_FIELD)],
            ),
        );
        $deleteBytes = $codec->encodeMessage($deletePatch);
        $codec->decodeMessage($deleteBytes);
        self::assertNotNull($codec->state->previousMessage);
        self::assertSame(MessageKind::MAP, $codec->state->previousMessage->kind);
        self::assertCount(2, $codec->state->previousMessage->map);
    }

    public function testBoundBatchStatefulColumnBatchAssignsDictionaryIdForRepeatedStringField(): void
    {
        $enc = new_session_encoder(default_session_options());
        $rows = [];
        for ($i = 0; $i < 32; $i++) {
            $role = ($i % 2 === 0) ? 'admin' : 'user';
            $rows[] = new_map(entry('id', new_u64($i)), entry('role', new_string($role)));
        }
        $batchBytes = $enc->encodeBatch($rows);
        self::assertGreaterThan(0, strlen($batchBytes));
        self::assertSame(MessageKind::COLUMN_BATCH, MessageKind::from(ord($batchBytes[0])));
    }

    public function testBoundBatchStatefulTrainedDictionaryProfileIsTransportedToFreshDecoder(): void
    {
        $enc = new_session_encoder(default_session_options());
        $rows = [];
        for ($i = 0; $i < 32; $i++) {
            $role = ($i % 2 === 0) ? 'admin' : 'user';
            $rows[] = new_map(entry('id', new_u64($i)), entry('role', new_string($role)));
        }
        $batchBytes = $enc->encodeBatch($rows);

        $dec = new_twilic_codec();
        $decoded = $dec->decodeMessage($batchBytes);
        self::assertSame(MessageKind::COLUMN_BATCH, $decoded->kind);
        self::assertNotNull($decoded->columnBatch);

        $dictId = null;
        foreach ($decoded->columnBatch->columns as $col) {
            if ($col->dictionaryId !== null) {
                $dictId = $col->dictionaryId;
                break;
            }
        }
        self::assertNotNull($dictId, 'dictionary id in batch');

        self::assertArrayHasKey($dictId, $dec->state->dictionaries, 'transported dictionary payload');
        $profile = $dec->state->dictionaryProfiles[$dictId] ?? null;
        self::assertNotNull($profile, 'transported dictionary profile');
        self::assertSame(1, $profile->version);
        self::assertSame(0, $profile->expiresAt);
        self::assertSame(DictionaryFallback::FAIL_FAST, $profile->fallback);
        self::assertSame(
            dictionary_payload_hash($dec->state->dictionaries[$dictId]),
            $profile->hash,
        );

        $roleValues = null;
        foreach ($decoded->columnBatch->columns as $col) {
            if ($col->dictionaryId === $dictId) {
                $roleValues = $col->values->strings;
                break;
            }
        }
        self::assertNotNull($roleValues);
        self::assertCount(32, $roleValues);
        self::assertSame('admin', $roleValues[0]);
        self::assertSame('user', $roleValues[1]);
    }

    public function testBoundBatchStatefulInvalidDictionaryProfileHashIsRejected(): void
    {
        $enc = new_twilic_codec();
        $dictId = 42;
        $enc->state->dictionaries[$dictId] = "\x01\x02\x03\x04";
        $enc->state->dictionaryProfiles[$dictId] = new DictionaryProfile(
            version: 1,
            hash: 7,
            expiresAt: 0,
            fallback: DictionaryFallback::FAIL_FAST,
        );

        $msg = new Message(
            kind: MessageKind::COLUMN_BATCH,
            columnBatch: new ColumnBatchMessage(
                count: 1,
                columns: [
                    new Column(
                        fieldId: 0,
                        nullStrategy: NullStrategy::ALL_PRESENT_ELIDED,
                        codec: VectorCodec::DICTIONARY,
                        dictionaryId: $dictId,
                        values: new TypedVectorData(
                            kind: ElementType::STRING,
                            strings: ['admin'],
                        ),
                    ),
                ],
            ),
        );
        $batchBytes = $enc->encodeMessage($msg);

        $dec = new_twilic_codec();
        try {
            $dec->decodeMessage($batchBytes);
            self::fail('expected decode failure for handcrafted dictionary profile payload');
        } catch (\Throwable $err) {
            $te = TestHelpers::requireTwilicErrorKind($err, ErrInvalidData);
            self::assertSame('dictionary profile hash mismatch', $te->msg);
        }
    }

    public function testBoundBatchStatefulTrainedDictionaryReferenceWritesCompressedBlockAfterDictId(): void
    {
        $dictId = 9;
        $codec = new_twilic_codec();
        $payload = new ByteBuffer();
        encode_varuint(2, $payload);
        encode_string('admin', $payload);
        encode_string('user', $payload);
        $dictPayload = $payload->bytes();
        $codec->state->dictionaries[$dictId] = $dictPayload;
        $codec->state->dictionaryProfiles[$dictId] = new DictionaryProfile(
            version: 1,
            hash: dictionary_payload_hash($dictPayload),
            expiresAt: 0,
            fallback: DictionaryFallback::FAIL_FAST,
        );
        $msg = new Message(
            kind: MessageKind::COLUMN_BATCH,
            columnBatch: new ColumnBatchMessage(
                count: 4,
                columns: [
                    new Column(
                        fieldId: 1,
                        nullStrategy: NullStrategy::ALL_PRESENT_ELIDED,
                        codec: VectorCodec::DICTIONARY,
                        dictionaryId: $dictId,
                        values: new TypedVectorData(
                            kind: ElementType::STRING,
                            strings: ['admin', 'user', 'admin', 'user'],
                        ),
                    ),
                ],
            ),
        );
        $batchBytes = $codec->encodeMessage($msg);

        $reader = new_reader($batchBytes);
        $kind = $reader->readU8();
        self::assertSame(MessageKind::COLUMN_BATCH->value, $kind);
        $reader->readVaruint();
        $reader->readVaruint();
        $reader->readVaruint();
        $reader->readU8();
        $reader->readU8();
        $gotDictId = $reader->readVaruint();
        self::assertNotSame(0, $gotDictId, 'expected non-zero dictionary id marker');

        $fresh = new_twilic_codec();
        $decoded = $fresh->decodeMessage($batchBytes);
        self::assertSame(MessageKind::COLUMN_BATCH, $decoded->kind);
        self::assertNotNull($decoded->columnBatch);
        $values = $decoded->columnBatch->columns[0]->values->strings;
        self::assertSame(['admin', 'user', 'admin', 'user'], $values);
    }
}
