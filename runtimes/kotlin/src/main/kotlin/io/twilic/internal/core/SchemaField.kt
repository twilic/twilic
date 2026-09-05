package io.twilic.internal.core

class SchemaField {
    @JvmField var number: Long = 0
    @JvmField var name: String = ""
    @JvmField var logicalType: String = ""
    @JvmField var required: Boolean = false
    @JvmField var defaultValue: Value = Value.ofNull()
    @JvmField var min: Long? = null
    @JvmField var max: Long? = null
    @JvmField var enumValues: MutableList<String> = mutableListOf()
}
