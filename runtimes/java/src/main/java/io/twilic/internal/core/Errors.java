package io.twilic.internal.core;

public final class Errors {
  private Errors() {}

  public enum TwilicErrorKind {
    ERR_UNEXPECTED_EOF,
    ERR_INVALID_KIND,
    ERR_INVALID_TAG,
    ERR_INVALID_DATA,
    ERR_UTF8,
    ERR_UNKNOWN_REFERENCE,
    ERR_STATELESS_RETRY_REQUIRED
  }

  public static final class TwilicException extends RuntimeException {
    private final TwilicErrorKind kind;
    private final byte valueByte;
    private final String msg;
    private final String refKind;
    private final long refID;

    public TwilicException(TwilicErrorKind kind) {
      this(kind, (byte) 0, null, null, 0L);
    }

    public TwilicException(TwilicErrorKind kind, byte valueByte) {
      this(kind, valueByte, null, null, 0L);
    }

    public TwilicException(TwilicErrorKind kind, String msg) {
      this(kind, (byte) 0, msg, null, 0L);
    }

    public TwilicException(TwilicErrorKind kind, String refKind, long refID) {
      this(kind, (byte) 0, null, refKind, refID);
    }

    public TwilicException(
        TwilicErrorKind kind, byte valueByte, String msg, String refKind, long refID) {
      super(buildMessage(kind, valueByte, msg, refKind, refID));
      this.kind = kind;
      this.valueByte = valueByte;
      this.msg = msg;
      this.refKind = refKind;
      this.refID = refID;
    }

    public TwilicErrorKind kind() {
      return kind;
    }

    public byte valueByte() {
      return valueByte;
    }

    public String msg() {
      return msg;
    }

    public String refKind() {
      return refKind;
    }

    public long refID() {
      return refID;
    }

    private static String buildMessage(
        TwilicErrorKind kind, byte valueByte, String msg, String refKind, long refID) {
      return switch (kind) {
        case ERR_UNEXPECTED_EOF -> "unexpected end of input";
        case ERR_INVALID_KIND -> String.format("invalid message kind: %#04x", valueByte & 0xFF);
        case ERR_INVALID_TAG -> String.format("invalid value tag: %#04x", valueByte & 0xFF);
        case ERR_INVALID_DATA -> "invalid data: " + msg;
        case ERR_UTF8 -> "utf8 decode error";
        case ERR_UNKNOWN_REFERENCE ->
            "unknown reference: " + refKind + "=" + Long.toUnsignedString(refID);
        case ERR_STATELESS_RETRY_REQUIRED ->
            "stateless retry required for reference: "
                + refKind
                + "="
                + Long.toUnsignedString(refID);
      };
    }
  }

  static TwilicException unexpectedEOF() {
    return new TwilicException(TwilicErrorKind.ERR_UNEXPECTED_EOF);
  }

  static TwilicException invalidKind(byte b) {
    return new TwilicException(TwilicErrorKind.ERR_INVALID_KIND, b);
  }

  static TwilicException invalidTag(byte b) {
    return new TwilicException(TwilicErrorKind.ERR_INVALID_TAG, b);
  }

  static TwilicException invalidData(String msg) {
    return new TwilicException(TwilicErrorKind.ERR_INVALID_DATA, msg);
  }

  static TwilicException utf8Error() {
    return new TwilicException(TwilicErrorKind.ERR_UTF8);
  }

  static TwilicException unknownReference(String kind, long id) {
    return new TwilicException(TwilicErrorKind.ERR_UNKNOWN_REFERENCE, kind, id);
  }

  static TwilicException statelessRetryRequired(String kind, long id) {
    return new TwilicException(TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED, kind, id);
  }

  static boolean isStatelessRetry(Throwable err) {
    return err instanceof TwilicException te
        && te.kind() == TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED;
  }

  static boolean isUnknownReference(Throwable err) {
    return err instanceof TwilicException te && te.kind() == TwilicErrorKind.ERR_UNKNOWN_REFERENCE;
  }
}
