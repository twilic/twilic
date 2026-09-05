<?php

declare(strict_types=1);

namespace Twilic;

require_once __DIR__ . '/Twilic/Version.php';
require_once __DIR__ . '/Twilic/Errors.php';
require_once __DIR__ . '/Twilic/ByteBuffer.php';
require_once __DIR__ . '/Twilic/Wire.php';
require_once __DIR__ . '/Twilic/Model.php';
require_once __DIR__ . '/Twilic/Session.php';
require_once __DIR__ . '/Twilic/Codec.php';
require_once __DIR__ . '/Twilic/Dictionary.php';
require_once __DIR__ . '/Twilic/ProtocolHelpers.php';
require_once __DIR__ . '/Twilic/Protocol.php';
require_once __DIR__ . '/Twilic/V2.php';

function encode(Value $value): string
{
    return encode_v2($value);
}

function decode(string $data): Value
{
    return decode_v2($data);
}

function encode_with_schema(Schema $schema, Value $value): string
{
    return new_session_encoder(default_session_options())->encodeWithSchema($schema, $value);
}

/** @param list<Value> $values */
function encode_batch(array $values): string
{
    return new_session_encoder(default_session_options())->encodeBatch($values);
}
