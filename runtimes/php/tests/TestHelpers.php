<?php

declare(strict_types=1);

namespace Twilic\Tests;

use PHPUnit\Framework\Assert;
use Twilic\ControlMessage;
use Twilic\KeyRef;
use Twilic\Message;
use Twilic\MessageKind;
use Twilic\MessageMapEntry;
use Twilic\Schema;
use Twilic\SchemaField;
use Twilic\TwilicError;
use Twilic\TwilicErrorKind;
use Twilic\Value;
use function Twilic\equal;
use function Twilic\key_ref_literal;

final class TestHelpers
{
    private const TAG_STRING = 6;

    public static function scalarStringMode(string $data): int
    {
        if (strlen($data) < 3) {
            Assert::fail(sprintf('expected at least 3 bytes, got %d', strlen($data)));
        }
        if (ord($data[0]) !== MessageKind::SCALAR->value) {
            Assert::fail(sprintf('expected scalar kind byte, got %d', ord($data[0])));
        }
        if (ord($data[1]) !== self::TAG_STRING) {
            Assert::fail(sprintf('expected string tag byte, got %d', ord($data[1])));
        }

        return ord($data[2]);
    }

    public static function requireTwilicErrorKind(\Throwable $err, TwilicErrorKind $kind): TwilicError
    {
        if (!$err instanceof TwilicError) {
            Assert::fail(sprintf('expected TwilicError, got %s', $err::class));
        }
        if ($err->kind !== $kind) {
            Assert::fail(sprintf('expected error kind %s, got %s', $kind->name, $err->kind->name));
        }

        return $err;
    }

    public static function equalKeyRef(KeyRef $a, KeyRef $b): bool
    {
        return $a->isId === $b->isId && $a->id === $b->id && $a->literal === $b->literal;
    }

    public static function equalMessage(Message $a, Message $b): bool
    {
        if ($a->kind !== $b->kind) {
            return false;
        }
        return match ($a->kind) {
            MessageKind::SCALAR => equal(
                ($a->scalar ?? Assert::fail('missing scalar'))->clone(),
                ($b->scalar ?? Assert::fail('missing scalar'))->clone(),
            ),
            MessageKind::ARRAY => (function () use ($a, $b): bool {
                if (count($a->array) !== count($b->array)) {
                    return false;
                }
                foreach ($a->array as $i => $av) {
                    if (!equal($av, $b->array[$i])) {
                        return false;
                    }
                }

                return true;
            })(),
            MessageKind::MAP => (function () use ($a, $b): bool {
                if (count($a->map) !== count($b->map)) {
                    return false;
                }
                foreach ($a->map as $i => $entry) {
                    if (!self::equalKeyRef($entry->key, $b->map[$i]->key)
                        || !equal($entry->value, $b->map[$i]->value)) {
                        return false;
                    }
                }

                return true;
            })(),
            default => serialize($a->clone()) === serialize($b->clone()),
        };
    }

    public static function messageMapEntry(string $key, Value $value): MessageMapEntry
    {
        return new MessageMapEntry(key: key_ref_literal($key), value: $value);
    }

    public static function sampleSchema(): Schema
    {
        return new Schema(
            schemaId: 41,
            name: 'User',
            fields: [
                new SchemaField(
                    number: 1,
                    name: 'id',
                    logicalType: 'u64',
                    required: true,
                    min: 1000,
                    max: 1100,
                ),
                new SchemaField(number: 2, name: 'name', logicalType: 'string', required: true),
                new SchemaField(
                    number: 3,
                    name: 'score',
                    logicalType: 'i64',
                    required: false,
                    min: 0,
                    max: 100,
                ),
            ],
        );
    }
}
