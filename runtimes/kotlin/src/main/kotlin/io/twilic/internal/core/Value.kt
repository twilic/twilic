package io.twilic.internal.core
class Value {
    @JvmField var kind: ValueKind = ValueKind.NULL
    @JvmField var bool: Boolean = false
    @JvmField var i64: Long = 0
    @JvmField var u64: Long = 0
    @JvmField var f64: Double = 0.0
    @JvmField var str: String = ""
    @JvmField var bin: ByteArray = ByteArray(0)
    @JvmField var arr: MutableList<Value> = mutableListOf()
    @JvmField var map: MutableList<MapEntry> = mutableListOf()

    fun cloneValue(): Value {
        val out = Value()
        out.kind = kind
        out.bool = bool
        out.i64 = i64
        out.u64 = u64
        out.f64 = f64
        out.str = str
        out.bin = bin.copyOf()
        for (item in arr) out.arr.add(item?.cloneValue() ?: ofNull())
        for (entry in map) {
            out.map.add(MapEntry(entry.key, entry.value?.cloneValue() ?: ofNull()))
        }
        return out
    }

    companion object {
        @JvmStatic fun ofNull() = Value().apply { kind = ValueKind.NULL }
        @JvmStatic fun ofBool(b: Boolean) = Value().apply { kind = ValueKind.BOOL; bool = b }
        @JvmStatic fun ofI64(n: Long) = Value().apply { kind = ValueKind.I64; i64 = n }
        @JvmStatic fun ofU64(n: Long) = Value().apply { kind = ValueKind.U64; u64 = n }
        @JvmStatic fun ofF64(n: Double) = Value().apply { kind = ValueKind.F64; f64 = n }
        @JvmStatic fun ofString(s: String?) = Value().apply { kind = ValueKind.STRING; str = s ?: "" }
        @JvmStatic fun ofBinary(b: ByteArray?) = Value().apply {
            kind = ValueKind.BINARY
            bin = b?.copyOf() ?: ByteArray(0)
        }
        @JvmStatic fun ofArray(items: List<Value>?) = Value().apply {
            kind = ValueKind.ARRAY
            items?.forEach { arr.add(it?.cloneValue() ?: ofNull()) }
        }
        @JvmStatic fun ofMap(entries: List<MapEntry>?) = Value().apply {
            kind = ValueKind.MAP
            entries?.forEach { map.add(MapEntry(it.key, it.value?.cloneValue() ?: ofNull())) }
        }
    }
}
