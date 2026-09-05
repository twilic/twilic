<?php

declare(strict_types=1);

namespace Twilic;

enum TwilicErrorKind: int
{
    case ERR_UNEXPECTED_EOF = 0;
    case ERR_INVALID_KIND = 1;
    case ERR_INVALID_TAG = 2;
    case ERR_INVALID_DATA = 3;
    case ERR_UTF8 = 4;
    case ERR_UNKNOWN_REFERENCE = 5;
    case ERR_STATELESS_RETRY_REQUIRED = 6;
}

// Public aliases matching Go export names
const ErrUnexpectedEOF = TwilicErrorKind::ERR_UNEXPECTED_EOF;
const ErrInvalidKind = TwilicErrorKind::ERR_INVALID_KIND;
const ErrInvalidTag = TwilicErrorKind::ERR_INVALID_TAG;
const ErrInvalidData = TwilicErrorKind::ERR_INVALID_DATA;
const ErrUTF8 = TwilicErrorKind::ERR_UTF8;
const ErrUnknownReference = TwilicErrorKind::ERR_UNKNOWN_REFERENCE;
const ErrStatelessRetryRequired = TwilicErrorKind::ERR_STATELESS_RETRY_REQUIRED;

final class TwilicError extends \Exception
{
    public function __construct(
        public readonly TwilicErrorKind $kind,
        public readonly int $byte = 0,
        public readonly string $msg = '',
        public readonly string $refKind = '',
        public readonly int $refId = 0,
    ) {
        parent::__construct($this->formatMessage());
    }

    private function formatMessage(): string
    {
        return match ($this->kind) {
            TwilicErrorKind::ERR_UNEXPECTED_EOF => 'unexpected end of input',
            TwilicErrorKind::ERR_INVALID_KIND => sprintf('invalid message kind: 0x%02x', $this->byte),
            TwilicErrorKind::ERR_INVALID_TAG => sprintf('invalid value tag: 0x%02x', $this->byte),
            TwilicErrorKind::ERR_INVALID_DATA => 'invalid data: ' . $this->msg,
            TwilicErrorKind::ERR_UTF8 => 'utf8 decode error',
            TwilicErrorKind::ERR_UNKNOWN_REFERENCE => "unknown reference: {$this->refKind}={$this->refId}",
            TwilicErrorKind::ERR_STATELESS_RETRY_REQUIRED => "stateless retry required for reference: {$this->refKind}={$this->refId}",
        };
    }
}

function unexpected_eof(): TwilicError
{
    return new TwilicError(kind: TwilicErrorKind::ERR_UNEXPECTED_EOF);
}

function invalid_kind(int $b): TwilicError
{
    return new TwilicError(kind: TwilicErrorKind::ERR_INVALID_KIND, byte: $b);
}

function invalid_tag(int $b): TwilicError
{
    return new TwilicError(kind: TwilicErrorKind::ERR_INVALID_TAG, byte: $b);
}

function invalid_data(string $msg): TwilicError
{
    return new TwilicError(kind: TwilicErrorKind::ERR_INVALID_DATA, msg: $msg);
}

function utf8_error(): TwilicError
{
    return new TwilicError(kind: TwilicErrorKind::ERR_UTF8);
}

function unknown_reference(string $kind, int $refId): TwilicError
{
    return new TwilicError(kind: TwilicErrorKind::ERR_UNKNOWN_REFERENCE, refKind: $kind, refId: $refId);
}

function stateless_retry_required(string $kind, int $refId): TwilicError
{
    return new TwilicError(kind: TwilicErrorKind::ERR_STATELESS_RETRY_REQUIRED, refKind: $kind, refId: $refId);
}

function is_stateless_retry(\Throwable $err): bool
{
    return $err instanceof TwilicError && $err->kind === TwilicErrorKind::ERR_STATELESS_RETRY_REQUIRED;
}

function is_unknown_reference(\Throwable $err): bool
{
    return $err instanceof TwilicError && $err->kind === TwilicErrorKind::ERR_UNKNOWN_REFERENCE;
}
