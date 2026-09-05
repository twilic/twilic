package io.twilic.internal.core

class Schema {
    @JvmField var schemaId: Long = 0
    @JvmField var name: String = ""
    @JvmField var fields: MutableList<SchemaField> = mutableListOf()
}
