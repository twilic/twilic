package io.twilic.internal.core

object Api {
    fun encode(value: Value): ByteArray = V2.encodeV2(value)
    fun decode(bytes: ByteArray): Value = V2.decodeV2(bytes)
    fun encodeWithSchema(schema: Schema, value: Value): ByteArray =
        SessionEncoder(SessionOptions()).encodeWithSchema(schema, value)
    fun encodeBatch(values: List<Value>): ByteArray =
        SessionEncoder(SessionOptions()).encodeBatch(values)
}
