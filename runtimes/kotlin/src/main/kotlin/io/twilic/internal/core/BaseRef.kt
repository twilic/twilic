package io.twilic.internal.core
class BaseRef {
    @JvmField var previous: Boolean = false
    @JvmField var baseId: Long = 0
    companion object {
        @JvmStatic fun previous() = BaseRef().apply { previous = true }
        @JvmStatic fun id(id: Long) = BaseRef().apply { baseId = id }
    }
}
