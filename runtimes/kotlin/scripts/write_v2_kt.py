#!/usr/bin/env python3
"""Write native Kotlin V2 wire codec (ported from twilic-python v2.py)."""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "src/main/kotlin/io/twilic/internal/core/V2.kt"

# Kotlin port of twilic-python/src/twilic/v2.py (session shape_key via Session.shapeKey)
CONTENT = r'''package io.twilic.internal.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.text.Charsets

internal object V2 {
    private const val NULL_TAG = 0xC0
    private const val FALSE_TAG = 0xC1
    private const val TRUE_TAG = 0xC2
    private const val F64_TAG = 0xC3
    private const val U8_TAG = 0xC4
    private const val U16_TAG = 0xC5
    private const val U32_TAG = 0xC6
    private const val U64_TAG = 0xC7
    private const val I8_TAG = 0xC8
    private const val I16_TAG = 0xC9
    private const val I32_TAG = 0xCA
    private const val I64_TAG = 0xCB
    private const val BIN8_TAG = 0xCC
    private const val BIN16_TAG = 0xCD
    private const val BIN32_TAG = 0xCE
    private const val STR8_TAG = 0xCF
    private const val STR16_TAG = 0xD0
    private const val STR32_TAG = 0xD1
    private const val ARRAY16_TAG = 0xD2
    private const val ARRAY32_TAG = 0xD3
    private const val MAP16_TAG = 0xD4
    private const val MAP32_TAG = 0xD5
    private const val SHAPE_DEF_TAG = 0xD6
    private const val KEY_REF_TAG = 0xD8
    private const val STR_REF_TAG = 0xD9

    private class EncodeState {
        val keyIds = HashMap<String, Long>()
        val strIds = HashMap<String, Long>()
        val shapeIds = HashMap<String, Long>()
        var nextKeyId = 0L
        var nextStrId = 0L
        var nextShapeId = 0L
    }

    private class DecodeState {
        val keys = mutableListOf<String>()
        val strings = mutableListOf<String>()
        val shapes = mutableListOf<List<String>?>()
    }

    fun encodeV2(value: Value): ByteArray {
        val out = ByteArrayOutputStream()
        encodeV2Value(value, out, EncodeState())
        return out.toByteArray()
    }

    fun decodeV2(data: ByteArray): Value {
        val reader = Wire.newReader(data)
        val state = DecodeState()
        val value = decodeV2Value(reader, state)
        if (!reader.isEOF()) {
            throw Errors.invalidData("trailing bytes in v2 decode")
        }
        return value
    }

    private fun encodeV2Value(value: Value, out: ByteArrayOutputStream, state: EncodeState) {
        when (value.kind) {
            ValueKind.NULL -> out.write(NULL_TAG)
            ValueKind.BOOL -> out.write(if (value.bool) TRUE_TAG else FALSE_TAG)
            ValueKind.I64 -> encodeV2I64(value.i64, out)
            ValueKind.U64 -> encodeV2U64(value.u64, out)
            ValueKind.F64 -> {
                out.write(F64_TAG)
                Wire.appendF64LE(out, value.f64)
            }
            ValueKind.STRING -> {
                val refId = state.strIds[value.str]
                if (refId != null) {
                    out.write(STR_REF_TAG)
                    Wire.encodeVaruint(refId, out)
                } else {
                    encodeV2StringLiteral(value.str, out)
                    state.strIds[value.str] = state.nextStrId++
                }
            }
            ValueKind.BINARY -> encodeV2Binary(value.bin, out)
            ValueKind.ARRAY -> encodeV2Array(value.arr, out, state)
            ValueKind.MAP -> encodeV2Map(value.map, out, state)
        }
    }

    private fun encodeV2Array(values: List<Value>, out: ByteArrayOutputStream, state: EncodeState) {
        val shapeKeys = detectShapeKeys(values)
        if (shapeKeys != null) {
            val sk = Session.shapeKey(shapeKeys)
            var shapeId = state.shapeIds[sk]
            if (shapeId == null) {
                shapeId = state.nextShapeId++
                state.shapeIds[sk] = shapeId
            }
            writeV2ArrayHeader(values.size, out)
            out.write(SHAPE_DEF_TAG)
            Wire.encodeVaruint(shapeId, out)
            Wire.encodeVaruint(shapeKeys.size.toLong(), out)
            for (key in shapeKeys) {
                encodeV2Key(key, out, state)
            }
            for (value in values) {
                if (value.kind != ValueKind.MAP) {
                    throw Errors.invalidData("shape array row must be map")
                }
                for (field in value.map) {
                    encodeV2Value(field.value, out, state)
                }
            }
            return
        }
        writeV2ArrayHeader(values.size, out)
        for (value in values) {
            encodeV2Value(value, out, state)
        }
    }

    private fun encodeV2Map(entries: List<MapEntry>, out: ByteArrayOutputStream, state: EncodeState) {
        writeV2MapHeader(entries.size, out)
        for (entry in entries) {
            encodeV2Key(entry.key, out, state)
            encodeV2Value(entry.value, out, state)
        }
    }

    private fun encodeV2Key(key: String, out: ByteArrayOutputStream, state: EncodeState) {
        val refId = state.keyIds[key]
        if (refId != null) {
            out.write(KEY_REF_TAG)
            Wire.encodeVaruint(refId, out)
            return
        }
        encodeV2StringLiteral(key, out)
        state.keyIds[key] = state.nextKeyId++
    }

    private fun encodeV2StringLiteral(value: String, out: ByteArrayOutputStream) {
        val raw = value.toByteArray(Charsets.UTF_8)
        val length = raw.size
        when {
            length <= 31 -> out.write(0x80 or length)
            length <= 0xFF -> {
                out.write(STR8_TAG)
                out.write(length)
            }
            length <= 0xFFFF -> {
                out.write(STR16_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
            }
            else -> {
                out.write(STR32_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
                out.write((length shr 16) and 0xFF)
                out.write((length shr 24) and 0xFF)
            }
        }
        out.write(raw)
    }

    private fun encodeV2Binary(value: ByteArray, out: ByteArrayOutputStream) {
        val length = value.size
        when {
            length <= 0xFF -> {
                out.write(BIN8_TAG)
                out.write(length)
            }
            length <= 0xFFFF -> {
                out.write(BIN16_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
            }
            else -> {
                out.write(BIN32_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
                out.write((length shr 16) and 0xFF)
                out.write((length shr 24) and 0xFF)
            }
        }
        out.write(value)
    }

    private fun encodeV2U64(value: Long, out: ByteArrayOutputStream) {
        if (java.lang.Long.compareUnsigned(value, 127L) <= 0) {
            out.write(value.toInt())
        } else if (java.lang.Long.compareUnsigned(value, 0xFFL) <= 0) {
            out.write(U8_TAG)
            out.write(value.toInt())
        } else if (java.lang.Long.compareUnsigned(value, 0xFFFFL) <= 0) {
            out.write(U16_TAG)
            out.write((value and 0xFF).toInt())
            out.write(((value shr 8) and 0xFF).toInt())
        } else if (java.lang.Long.compareUnsigned(value, 0xFFFFFFFFL) <= 0) {
            out.write(U32_TAG)
            out.write((value and 0xFF).toInt())
            out.write(((value shr 8) and 0xFF).toInt())
            out.write(((value shr 16) and 0xFF).toInt())
            out.write(((value shr 24) and 0xFF).toInt())
        } else {
            out.write(U64_TAG)
            Wire.appendU64LE(out, value)
        }
    }

    private fun encodeV2I64(value: Long, out: ByteArrayOutputStream) {
        when {
            value in -32..-1 -> out.write((value and 0xFF).toInt())
            value in 0..127 -> out.write(value.toInt())
            value in -128..127 -> {
                out.write(I8_TAG)
                out.write((value and 0xFF).toInt())
            }
            value in -32768..32767 -> {
                out.write(I16_TAG)
                out.write((value and 0xFF).toInt())
                out.write(((value shr 8) and 0xFF).toInt())
            }
            value in -2147483648..2147483647 -> {
                out.write(I32_TAG)
                out.write((value and 0xFF).toInt())
                out.write(((value shr 8) and 0xFF).toInt())
                out.write(((value shr 16) and 0xFF).toInt())
                out.write(((value shr 24) and 0xFF).toInt())
            }
            else -> {
                out.write(I64_TAG)
                Wire.appendU64LE(out, value)
            }
        }
    }

    private fun writeV2ArrayHeader(length: Int, out: ByteArrayOutputStream) {
        when {
            length <= 15 -> out.write(0xA0 or length)
            length <= 0xFFFF -> {
                out.write(ARRAY16_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
            }
            else -> {
                out.write(ARRAY32_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
                out.write((length shr 16) and 0xFF)
                out.write((length shr 24) and 0xFF)
            }
        }
    }

    private fun writeV2MapHeader(length: Int, out: ByteArrayOutputStream) {
        when {
            length <= 15 -> out.write(0xB0 or length)
            length <= 0xFFFF -> {
                out.write(MAP16_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
            }
            else -> {
                out.write(MAP32_TAG)
                out.write(length and 0xFF)
                out.write((length shr 8) and 0xFF)
                out.write((length shr 16) and 0xFF)
                out.write((length shr 24) and 0xFF)
            }
        }
    }

    private fun detectShapeKeys(values: List<Value>): List<String>? {
        if (values.size < 2) return null
        if (values[0].kind != ValueKind.MAP || values[0].map.isEmpty()) return null
        val keys = values[0].map.map { it.key }
        for (value in values.subList(1, values.size)) {
            if (value.kind != ValueKind.MAP || value.map.size != keys.size) return null
            for (i in keys.indices) {
                if (value.map[i].key != keys[i]) return null
            }
        }
        return keys
    }

    private fun decodeV2Value(reader: Wire.Reader, state: DecodeState): Value {
        val tag = reader.readU8().toInt() and 0xFF
        return decodeV2ValueFromTag(reader, state, tag)
    }

    private fun decodeV2ValueFromTag(reader: Wire.Reader, state: DecodeState, tag: Int): Value {
        when {
            tag <= 0x7F -> return Value.ofU64(tag.toLong())
            tag in 0x80..0x9F -> {
                val length = tag and 0x1F
                val raw = reader.readExact(length)
                val s = String(raw, Charsets.UTF_8)
                state.strings.add(s)
                return Value.ofString(s)
            }
            tag in 0xA0..0xAF -> return decodeV2ArrayBody(reader, state, tag and 0x0F)
            tag in 0xB0..0xBF -> return decodeV2MapBody(reader, state, tag and 0x0F)
            tag >= 0xE0 -> return Value.ofI64(if (tag < 128) tag.toLong() else (tag - 256).toLong())
            tag == NULL_TAG -> return Value.ofNull()
            tag == FALSE_TAG -> return Value.ofBool(false)
            tag == TRUE_TAG -> return Value.ofBool(true)
            tag == F64_TAG -> return Value.ofF64(Wire.readF64LE(reader))
            tag == U8_TAG -> return Value.ofU64((reader.readU8().toInt() and 0xFF).toLong())
            tag == U16_TAG -> {
                val b = reader.readExact(2)
                return Value.ofU64(((b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8)).toLong())
            }
            tag == U32_TAG -> {
                val b = reader.readExact(4)
                return Value.ofU64(
                    ((b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8) or
                        ((b[2].toInt() and 0xFF) shl 16) or ((b[3].toInt() and 0xFF) shl 24)).toLong() and 0xFFFFFFFFL
                )
            }
            tag == U64_TAG -> return Value.ofU64(Wire.readU64LE(reader))
            tag == I8_TAG -> {
                val b = reader.readU8().toInt() and 0xFF
                return Value.ofI64(if (b < 128) b.toLong() else (b - 256).toLong())
            }
            tag == I16_TAG -> {
                val b = reader.readExact(2)
                val v = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8)
                return Value.ofI64(v.toShort().toLong())
            }
            tag == I32_TAG -> {
                val b = reader.readExact(4)
                val v = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8) or
                    ((b[2].toInt() and 0xFF) shl 16) or ((b[3].toInt() and 0xFF) shl 24)
                return Value.ofI64(v.toLong())
            }
            tag == I64_TAG -> {
                val b = reader.readExact(8)
                return Value.ofI64(ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).long)
            }
            tag == BIN8_TAG -> {
                val n = reader.readU8().toInt() and 0xFF
                return Value.ofBinary(reader.readExact(n))
            }
            tag == BIN16_TAG -> {
                val b = reader.readExact(2)
                val n = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8)
                return Value.ofBinary(reader.readExact(n))
            }
            tag == BIN32_TAG -> {
                val b = reader.readExact(4)
                val n = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8) or
                    ((b[2].toInt() and 0xFF) shl 16) or ((b[3].toInt() and 0xFF) shl 24)
                return Value.ofBinary(reader.readExact(n))
            }
            tag == STR8_TAG || tag == STR16_TAG || tag == STR32_TAG -> return decodeV2StringTag(reader, state, tag)
            tag == ARRAY16_TAG -> {
                val b = reader.readExact(2)
                val n = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8)
                return decodeV2ArrayBody(reader, state, n)
            }
            tag == ARRAY32_TAG -> {
                val b = reader.readExact(4)
                val n = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8) or
                    ((b[2].toInt() and 0xFF) shl 16) or ((b[3].toInt() and 0xFF) shl 24)
                return decodeV2ArrayBody(reader, state, n)
            }
            tag == MAP16_TAG -> {
                val b = reader.readExact(2)
                val n = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8)
                return decodeV2MapBody(reader, state, n)
            }
            tag == MAP32_TAG -> {
                val b = reader.readExact(4)
                val n = (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8) or
                    ((b[2].toInt() and 0xFF) shl 16) or ((b[3].toInt() and 0xFF) shl 24)
                return decodeV2MapBody(reader, state, n)
            }
            tag == STR_REF_TAG -> {
                val refId = reader.readVaruint()
                if (refId >= state.strings.size) {
                    throw Errors.invalidData("unknown str_ref id")
                }
                return Value.ofString(state.strings[refId.toInt()])
            }
            else -> throw Errors.invalidTag(tag.toByte())
        }
    }

    private fun decodeV2StringTag(reader: Wire.Reader, state: DecodeState, tag: Int): Value {
        val length = when (tag) {
            STR8_TAG -> reader.readU8().toInt() and 0xFF
            STR16_TAG -> {
                val b = reader.readExact(2)
                (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8)
            }
            STR32_TAG -> {
                val b = reader.readExact(4)
                (b[0].toInt() and 0xFF) or ((b[1].toInt() and 0xFF) shl 8) or
                    ((b[2].toInt() and 0xFF) shl 16) or ((b[3].toInt() and 0xFF) shl 24)
            }
            else -> throw Errors.invalidData("invalid string tag")
        }
        val raw = reader.readExact(length)
        val s = String(raw, Charsets.UTF_8)
        state.strings.add(s)
        return Value.ofString(s)
    }

    private fun decodeV2ArrayBody(reader: Wire.Reader, state: DecodeState, length: Int): Value {
        if (length == 0) {
            return Value.ofArray(emptyList())
        }
        val firstTag = reader.readU8().toInt() and 0xFF
        if (firstTag == SHAPE_DEF_TAG) {
            val shapeId = reader.readVaruint()
            val keyCount = reader.readVaruint().toInt()
            val keys = mutableListOf<String>()
            repeat(keyCount) {
                keys.add(decodeV2Key(reader, state))
            }
            while (shapeId >= state.shapes.size) {
                state.shapes.add(null)
            }
            state.shapes[shapeId.toInt()] = keys
            val values = mutableListOf<Value>()
            repeat(length) {
                val row = keys.map { key -> MapEntry(key, decodeV2Value(reader, state)) }
                values.add(Value.ofMap(row))
            }
            return Value.ofArray(values)
        }
        val values = mutableListOf<Value>()
        values.add(decodeV2ValueFromTag(reader, state, firstTag))
        for (i in 1 until length) {
            values.add(decodeV2Value(reader, state))
        }
        return Value.ofArray(values)
    }

    private fun decodeV2MapBody(reader: Wire.Reader, state: DecodeState, length: Int): Value {
        val entries = mutableListOf<MapEntry>()
        repeat(length) {
            val key = decodeV2Key(reader, state)
            val value = decodeV2Value(reader, state)
            entries.add(MapEntry(key, value))
        }
        return Value.ofMap(entries)
    }

    private fun decodeV2Key(reader: Wire.Reader, state: DecodeState): String {
        val tag = reader.readU8().toInt() and 0xFF
        when {
            tag == KEY_REF_TAG -> {
                val refId = reader.readVaruint()
                if (refId >= state.keys.size) {
                    throw Errors.invalidData("unknown key_ref id")
                }
                return state.keys[refId.toInt()]
            }
            tag in 0x80..0x9F -> {
                val length = tag and 0x1F
                val key = String(reader.readExact(length), Charsets.UTF_8)
                state.keys.add(key)
                return key
            }
            tag == STR8_TAG || tag == STR16_TAG || tag == STR32_TAG -> {
                val v = decodeV2ValueFromTag(reader, state, tag)
                if (v.kind != ValueKind.STRING) {
                    throw Errors.invalidData("expected string key")
                }
                state.keys.add(v.str)
                return v.str
            }
            else -> throw Errors.invalidData("map key must be key_ref or string")
        }
    }
}
'''

def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(CONTENT, encoding="utf-8")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
