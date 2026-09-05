package io.twilic.internal.core

object Errors {
    enum class TwilicErrorKind {
        ERR_UNEXPECTED_EOF,
        ERR_INVALID_KIND,
        ERR_INVALID_TAG,
        ERR_INVALID_DATA,
        ERR_UTF8,
        ERR_UNKNOWN_REFERENCE,
        ERR_STATELESS_RETRY_REQUIRED,
    }

    class TwilicException : RuntimeException {
        private val errorKind: TwilicErrorKind
        private val valueByte: Byte
        private val errorMsg: String?
        private val errorRefKind: String?
        private val errorRefID: Long

        constructor(kind: TwilicErrorKind) : this(kind, 0, null, null, 0L)

        constructor(kind: TwilicErrorKind, valueByte: Byte) : this(kind, valueByte, null, null, 0L)

        constructor(kind: TwilicErrorKind, msg: String) : this(kind, 0, msg, null, 0L)

        constructor(kind: TwilicErrorKind, refKind: String, refID: Long) : this(kind, 0, null, refKind, refID)

        constructor(
            kind: TwilicErrorKind,
            valueByte: Byte,
            msg: String?,
            refKind: String?,
            refID: Long,
        ) : super(buildMessage(kind, valueByte, msg, refKind, refID)) {
            this.errorKind = kind
            this.valueByte = valueByte
            this.errorMsg = msg
            this.errorRefKind = refKind
            this.errorRefID = refID
        }

        fun kind(): TwilicErrorKind = errorKind

        fun valueByte(): Byte = valueByte

        fun msg(): String? = errorMsg

        fun refKind(): String? = errorRefKind

        fun refID(): Long = errorRefID

        private companion object {
            private fun buildMessage(
                kind: TwilicErrorKind,
                valueByte: Byte,
                msg: String?,
                refKind: String?,
                refID: Long,
            ): String =
                when (kind) {
                    TwilicErrorKind.ERR_UNEXPECTED_EOF -> "unexpected end of input"
                    TwilicErrorKind.ERR_INVALID_KIND ->
                        String.format("invalid message kind: %#04x", valueByte.toInt() and 0xFF)
                    TwilicErrorKind.ERR_INVALID_TAG ->
                        String.format("invalid value tag: %#04x", valueByte.toInt() and 0xFF)
                    TwilicErrorKind.ERR_INVALID_DATA -> "invalid data: $msg"
                    TwilicErrorKind.ERR_UTF8 -> "utf8 decode error"
                    TwilicErrorKind.ERR_UNKNOWN_REFERENCE ->
                        "unknown reference: $refKind=${java.lang.Long.toUnsignedString(refID)}"
                    TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED ->
                        "stateless retry required for reference: " +
                            "$refKind=${java.lang.Long.toUnsignedString(refID)}"
                }
        }
    }

    @JvmStatic fun unexpectedEOF(): TwilicException = TwilicException(TwilicErrorKind.ERR_UNEXPECTED_EOF)

    @JvmStatic fun invalidKind(b: Byte): TwilicException = TwilicException(TwilicErrorKind.ERR_INVALID_KIND, b)

    @JvmStatic fun invalidTag(b: Byte): TwilicException = TwilicException(TwilicErrorKind.ERR_INVALID_TAG, b)

    @JvmStatic fun invalidData(msg: String): TwilicException = TwilicException(TwilicErrorKind.ERR_INVALID_DATA, msg)

    @JvmStatic fun utf8Error(): TwilicException = TwilicException(TwilicErrorKind.ERR_UTF8)

    @JvmStatic fun unknownReference(kind: String, id: Long): TwilicException =
        TwilicException(TwilicErrorKind.ERR_UNKNOWN_REFERENCE, kind, id)

    @JvmStatic fun statelessRetryRequired(kind: String, id: Long): TwilicException =
        TwilicException(TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED, kind, id)

    @JvmStatic fun isStatelessRetry(err: Throwable): Boolean =
        err is TwilicException && err.kind() == TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED

    @JvmStatic fun isUnknownReference(err: Throwable): Boolean =
        err is TwilicException && err.kind() == TwilicErrorKind.ERR_UNKNOWN_REFERENCE
}
