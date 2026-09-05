#nullable enable

namespace Twilic.Core;

public static class Errors
{
    public enum TwilicErrorKind
    {
        ErrUnexpectedEof,
        ErrInvalidKind,
        ErrInvalidTag,
        ErrInvalidData,
        ErrUtf8,
        ErrUnknownReference,
        ErrStatelessRetryRequired,
    }

    public sealed class TwilicException : Exception
    {
        public TwilicErrorKind Kind { get; }
        public byte ValueByte { get; }
        public string? Msg { get; }
        public string? RefKind { get; }
        public long RefId { get; }

        public TwilicException(TwilicErrorKind kind)
            : this(kind, 0, null, null, 0) { }

        public TwilicException(TwilicErrorKind kind, byte valueByte)
            : this(kind, valueByte, null, null, 0) { }

        public TwilicException(TwilicErrorKind kind, string msg)
            : this(kind, 0, msg, null, 0) { }

        public TwilicException(TwilicErrorKind kind, string refKind, long refId)
            : this(kind, 0, null, refKind, refId) { }

        public TwilicException(
            TwilicErrorKind kind,
            byte valueByte,
            string? msg,
            string? refKind,
            long refId)
            : base(BuildMessage(kind, valueByte, msg, refKind, refId))
        {
            Kind = kind;
            ValueByte = valueByte;
            Msg = msg;
            RefKind = refKind;
            RefId = refId;
        }

        static string BuildMessage(
            TwilicErrorKind kind,
            byte valueByte,
            string? msg,
            string? refKind,
            long refId) =>
            kind switch
            {
                TwilicErrorKind.ErrUnexpectedEof => "unexpected end of input",
                TwilicErrorKind.ErrInvalidKind =>
                    string.Format("invalid message kind: {0:x4}", valueByte & 0xFF),
                TwilicErrorKind.ErrInvalidTag =>
                    string.Format("invalid value tag: {0:x4}", valueByte & 0xFF),
                TwilicErrorKind.ErrInvalidData => "invalid data: " + msg,
                TwilicErrorKind.ErrUtf8 => "utf8 decode error",
                TwilicErrorKind.ErrUnknownReference =>
                    "unknown reference: " + refKind + "=" + unchecked((ulong)refId),
                TwilicErrorKind.ErrStatelessRetryRequired =>
                    "stateless retry required for reference: "
                    + refKind
                    + "="
                    + unchecked((ulong)refId),
                _ => "unknown twilic error",
            };
    }

    internal static TwilicException UnexpectedEof() =>
        new(TwilicErrorKind.ErrUnexpectedEof);

    internal static TwilicException InvalidKind(byte b) =>
        new(TwilicErrorKind.ErrInvalidKind, b);

    internal static TwilicException InvalidTag(byte b) =>
        new(TwilicErrorKind.ErrInvalidTag, b);

    internal static TwilicException InvalidData(string msg) =>
        new(TwilicErrorKind.ErrInvalidData, msg);

    internal static TwilicException Utf8Error() => new(TwilicErrorKind.ErrUtf8);

    internal static TwilicException UnknownReference(string kind, long id) =>
        new(TwilicErrorKind.ErrUnknownReference, kind, id);

    internal static TwilicException StatelessRetryRequired(string kind, long id) =>
        new(TwilicErrorKind.ErrStatelessRetryRequired, kind, id);

    internal static bool IsStatelessRetry(Exception err) =>
        err is TwilicException te && te.Kind == TwilicErrorKind.ErrStatelessRetryRequired;

    internal static bool IsUnknownReference(Exception err) =>
        err is TwilicException te && te.Kind == TwilicErrorKind.ErrUnknownReference;
}
