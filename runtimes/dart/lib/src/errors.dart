enum TwilicErrorKind {
  errUnexpectedEof,
  errInvalidKind,
  errInvalidTag,
  errInvalidData,
  errUtf8,
  errUnknownReference,
  errStatelessRetryRequired,
}

const errUnexpectedEof = TwilicErrorKind.errUnexpectedEof;
const errInvalidKind = TwilicErrorKind.errInvalidKind;
const errInvalidTag = TwilicErrorKind.errInvalidTag;
const errInvalidData = TwilicErrorKind.errInvalidData;
const errUtf8 = TwilicErrorKind.errUtf8;
const errUnknownReference = TwilicErrorKind.errUnknownReference;
const errStatelessRetryRequired = TwilicErrorKind.errStatelessRetryRequired;

class TwilicError implements Exception {
  TwilicError(this.kind,
      {this.byte = 0, this.msg = '', this.refKind = '', this.refId = 0});
  final TwilicErrorKind kind;
  final int byte;
  final String msg;
  final String refKind;
  final int refId;

  @override
  String toString() {
    switch (kind) {
      case TwilicErrorKind.errUnexpectedEof:
        return 'unexpected end of input';
      case TwilicErrorKind.errInvalidKind:
        return 'invalid message kind: 0x${byte.toRadixString(16).padLeft(2, '0')}';
      case TwilicErrorKind.errInvalidTag:
        return 'invalid value tag: 0x${byte.toRadixString(16).padLeft(2, '0')}';
      case TwilicErrorKind.errInvalidData:
        return 'invalid data: $msg';
      case TwilicErrorKind.errUtf8:
        return 'utf8 decode error';
      case TwilicErrorKind.errUnknownReference:
        return 'unknown reference: $refKind=$refId';
      case TwilicErrorKind.errStatelessRetryRequired:
        return 'stateless retry required for reference: $refKind=$refId';
    }
  }
}

TwilicError unexpectedEof() => TwilicError(TwilicErrorKind.errUnexpectedEof);
TwilicError invalidKind(int b) =>
    TwilicError(TwilicErrorKind.errInvalidKind, byte: b);
TwilicError invalidTag(int b) =>
    TwilicError(TwilicErrorKind.errInvalidTag, byte: b);
TwilicError invalidData(String msg) =>
    TwilicError(TwilicErrorKind.errInvalidData, msg: msg);
TwilicError utf8Error() => TwilicError(TwilicErrorKind.errUtf8);
TwilicError unknownReference(String kind, int refId) =>
    TwilicError(TwilicErrorKind.errUnknownReference,
        refKind: kind, refId: refId);
TwilicError statelessRetryRequired(String kind, int refId) =>
    TwilicError(TwilicErrorKind.errStatelessRetryRequired,
        refKind: kind, refId: refId);
bool isStatelessRetry(Object err) =>
    err is TwilicError && err.kind == TwilicErrorKind.errStatelessRetryRequired;
bool isUnknownReference(Object err) =>
    err is TwilicError && err.kind == TwilicErrorKind.errUnknownReference;
