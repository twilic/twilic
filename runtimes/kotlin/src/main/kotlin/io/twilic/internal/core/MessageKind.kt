package io.twilic.internal.core

enum class MessageKind {
    SCALAR,
    ARRAY,
    MAP,
    SHAPED_OBJECT,
    SCHEMA_OBJECT,
    TYPED_VECTOR,
    ROW_BATCH,
    COLUMN_BATCH,
    CONTROL,
    EXT,
    STATE_PATCH,
    TEMPLATE_BATCH,
    CONTROL_STREAM,
    BASE_SNAPSHOT,
    ;

    companion object {
        @JvmStatic
        fun fromByte(b: Int): MessageKind {
            val idx = b and 0xFF
            val values = entries.toTypedArray()
            if (idx < 0 || idx >= values.size) throw Errors.invalidData("invalid message kind")
            return values[idx]
        }
    }
}
