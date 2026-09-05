package io.twilic.internal.core
class KeyRef {
    @JvmField var literal: String = ""
    @JvmField var id: Long = 0
    @JvmField var isId: Boolean = false
    companion object {
        @JvmStatic fun literal(value: String) = KeyRef().apply { literal = value; isId = false }
        @JvmStatic fun id(keyId: Long) = KeyRef().apply { id = keyId; isId = true }
    }
}
