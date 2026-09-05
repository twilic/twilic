package io.twilic.internal.core
class MapEntry {
    @JvmField var key: String = ""
    @JvmField var value: Value = Value.ofNull()
    constructor()
    constructor(key: String, value: Value) {
        this.key = key
        this.value = value
    }
}
