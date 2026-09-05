package io.twilic

import io.twilic.internal.core.*

object Twilic {
    @JvmStatic fun encode(value: Value): ByteArray = Api.encode(value)
    @JvmStatic fun decode(bytes: ByteArray): Value = Api.decode(bytes)
    @JvmStatic fun encodeWithSchema(schema: Schema, value: Value): ByteArray = Api.encodeWithSchema(schema, value)
    @JvmStatic fun encodeBatch(values: List<Value>): ByteArray = Api.encodeBatch(values)

    @JvmStatic fun newNull(): Value = Value.ofNull()
    @JvmStatic fun newBool(b: Boolean): Value = Value.ofBool(b)
    @JvmStatic fun newI64(n: Long): Value = Value.ofI64(n)
    @JvmStatic fun newU64(n: Long): Value = Value.ofU64(n)
    @JvmStatic fun newF64(n: Double): Value = Value.ofF64(n)
    @JvmStatic fun newString(s: String): Value = Value.ofString(s)
    @JvmStatic fun newBinary(b: ByteArray): Value = Value.ofBinary(b)
    @JvmStatic fun newArray(items: List<Value>): Value = Value.ofArray(items)
    @JvmStatic fun entry(key: String, value: Value): MapEntry = MapEntry(key, value)
    @JvmStatic fun newMap(vararg entries: MapEntry): Value = Value.ofMap(entries.toList())

    @JvmStatic fun equal(a: Value, b: Value): Boolean {
        if (a.kind != b.kind) return false
        return when (a.kind) {
            ValueKind.NULL -> true
            ValueKind.BOOL -> a.bool == b.bool
            ValueKind.I64 -> a.i64 == b.i64
            ValueKind.U64 -> a.u64 == b.u64
            ValueKind.F64 -> java.lang.Double.compare(a.f64, b.f64) == 0
            ValueKind.STRING -> a.str == b.str
            ValueKind.BINARY -> a.bin.contentEquals(b.bin)
            ValueKind.ARRAY ->
                a.arr.size == b.arr.size && a.arr.indices.all { equal(a.arr[it], b.arr[it]) }
            ValueKind.MAP ->
                a.map.size == b.map.size && a.map.indices.all { i ->
                    a.map[i].key == b.map[i].key && equal(a.map[i].value, b.map[i].value)
                }
        }
    }

    @JvmStatic fun keyRefLiteral(s: String): KeyRef = KeyRef.literal(s)
    @JvmStatic fun keyRefID(id: Long): KeyRef = KeyRef.id(id)
    @JvmStatic fun baseRefPrevious(): BaseRef = BaseRef.previous()
    @JvmStatic fun baseRefID(id: Long): BaseRef = BaseRef.id(id)
    @JvmStatic fun newSessionEncoder(): SessionEncoder = SessionEncoder()
}
