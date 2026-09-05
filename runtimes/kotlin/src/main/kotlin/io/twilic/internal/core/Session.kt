package io.twilic.internal.core

object Session {
    @JvmStatic fun defaultSessionOptions(): SessionOptions = SessionOptions()

    @JvmStatic fun shapeKey(keys: List<String>): String = keys.joinToString("\u0000")
}
