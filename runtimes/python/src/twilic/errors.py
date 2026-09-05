"""Twilic error types."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum


class TwilicErrorKind(IntEnum):
    ERR_UNEXPECTED_EOF = 0
    ERR_INVALID_KIND = 1
    ERR_INVALID_TAG = 2
    ERR_INVALID_DATA = 3
    ERR_UTF8 = 4
    ERR_UNKNOWN_REFERENCE = 5
    ERR_STATELESS_RETRY_REQUIRED = 6


# Public aliases matching Go export names
ErrUnexpectedEOF = TwilicErrorKind.ERR_UNEXPECTED_EOF
ErrInvalidKind = TwilicErrorKind.ERR_INVALID_KIND
ErrInvalidTag = TwilicErrorKind.ERR_INVALID_TAG
ErrInvalidData = TwilicErrorKind.ERR_INVALID_DATA
ErrUTF8 = TwilicErrorKind.ERR_UTF8
ErrUnknownReference = TwilicErrorKind.ERR_UNKNOWN_REFERENCE
ErrStatelessRetryRequired = TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED


@dataclass
class TwilicError(Exception):
    kind: TwilicErrorKind
    byte: int = 0
    msg: str = ""
    ref_kind: str = ""
    ref_id: int = 0

    def __str__(self) -> str:
        match self.kind:
            case TwilicErrorKind.ERR_UNEXPECTED_EOF:
                return "unexpected end of input"
            case TwilicErrorKind.ERR_INVALID_KIND:
                return f"invalid message kind: {self.byte:#04x}"
            case TwilicErrorKind.ERR_INVALID_TAG:
                return f"invalid value tag: {self.byte:#04x}"
            case TwilicErrorKind.ERR_INVALID_DATA:
                return f"invalid data: {self.msg}"
            case TwilicErrorKind.ERR_UTF8:
                return "utf8 decode error"
            case TwilicErrorKind.ERR_UNKNOWN_REFERENCE:
                return f"unknown reference: {self.ref_kind}={self.ref_id}"
            case TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED:
                return f"stateless retry required for reference: {self.ref_kind}={self.ref_id}"
            case _:
                return "twilic error"


def unexpected_eof() -> TwilicError:
    return TwilicError(kind=TwilicErrorKind.ERR_UNEXPECTED_EOF)


def invalid_kind(b: int) -> TwilicError:
    return TwilicError(kind=TwilicErrorKind.ERR_INVALID_KIND, byte=b)


def invalid_tag(b: int) -> TwilicError:
    return TwilicError(kind=TwilicErrorKind.ERR_INVALID_TAG, byte=b)


def invalid_data(msg: str) -> TwilicError:
    return TwilicError(kind=TwilicErrorKind.ERR_INVALID_DATA, msg=msg)


def utf8_error() -> TwilicError:
    return TwilicError(kind=TwilicErrorKind.ERR_UTF8)


def unknown_reference(kind: str, ref_id: int) -> TwilicError:
    return TwilicError(kind=TwilicErrorKind.ERR_UNKNOWN_REFERENCE, ref_kind=kind, ref_id=ref_id)


def stateless_retry_required(kind: str, ref_id: int) -> TwilicError:
    return TwilicError(
        kind=TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED, ref_kind=kind, ref_id=ref_id
    )


def is_stateless_retry(err: BaseException) -> bool:
    return isinstance(err, TwilicError) and err.kind == TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED


def is_unknown_reference(err: BaseException) -> bool:
    return isinstance(err, TwilicError) and err.kind == TwilicErrorKind.ERR_UNKNOWN_REFERENCE
