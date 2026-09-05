package io.twilic.internal.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import kotlin.text.Charsets

object Wire {
    @JvmStatic fun encodeVaruint(value: Long, out: ByteArrayOutputStream) {
        if (java.lang.Long.compareUnsigned(value, 0x80L) < 0) {
            out.write(value.toInt())
            return
        }
        var v = value
        while (true) {
            var b = (v and 0x7F).toInt()
            v = v ushr 7
            if (v != 0L) {
                b = b or 0x80
            }
            out.write(b)
            if (v == 0L) {
                break
            }
        }
    }

    @JvmStatic fun encodeZigzag(value: Long): Long = (value shl 1) xor (value shr 63)

    @JvmStatic fun decodeZigzag(value: Long): Long = (value ushr 1) xor -(value and 1L)

    @JvmStatic fun encodeBytes(bytes: ByteArray, out: ByteArrayOutputStream) {
        encodeVaruint(bytes.size.toLong(), out)
        out.write(bytes, 0, bytes.size)
    }

    @JvmStatic fun encodeString(value: String, out: ByteArrayOutputStream) {
        encodeBytes(value.toByteArray(Charsets.UTF_8), out)
    }

    @JvmStatic fun encodeBitmap(bits: BooleanArray, out: ByteArrayOutputStream) {
        encodeVaruint(bits.size.toLong(), out)
        var current = 0
        for (i in bits.indices) {
            if (bits[i]) {
                current = current or (1 shl (i % 8))
            }
            if (i % 8 == 7) {
                out.write(current)
                current = 0
            }
        }
        if (bits.size % 8 != 0) {
            out.write(current)
        }
    }

    class Reader(private val input: ByteArray) {
        private var offset = 0
        private var depth = 0
        private var budget = minOf(input.size, 1024).toLong() * 1024

        fun claimOutput(count: Long) {
            if (count < 0 || count > (1 shl 20)) throw Errors.invalidData("decode count limit exceeded")
            if (count > budget / 8) throw Errors.invalidData("decode output ratio exceeded")
            budget -= count * 8
        }
        fun readCount(): Long = readCount((1 shl 20).toLong())
        fun readCount(maximum: Long): Long {
            val count = readVaruint()
            if (count < 0 || count > maximum) throw Errors.invalidData("decode count limit exceeded")
            claimOutput(count)
            return count
        }
        fun enterDepth() {
            if (depth >= 64) throw Errors.invalidData("decode depth limit exceeded")
            depth++
        }
        fun leaveDepth() { depth-- }

        fun position(): Int = offset

        fun isEOF(): Boolean = offset >= input.size

        fun readU8(): Byte {
            if (offset >= input.size) {
                throw Errors.unexpectedEOF()
            }
            return input[offset++]
        }

        fun readExact(n: Int): ByteArray {
            val end = offset + n
            if (n < 0 || n > input.size - offset) {
                throw Errors.unexpectedEOF()
            }
            return input.copyOfRange(offset, end).also { offset = end }
        }

        fun readVaruint(): Long {
            var shift = 0
            var result = 0L
            while (true) {
                if (shift >= 64) {
                    throw Errors.invalidData("varuint too large")
                }
                val b = readU8()
                if (shift == 63 && (b.toInt() and 0x7E) != 0) throw Errors.invalidData("varuint too large")
                result = result or ((b.toLong() and 0x7F) shl shift)
                if (b.toInt() and 0x80 == 0) {
                    return result
                }
                shift += 7
            }
        }

        fun readI64Zigzag(): Long = decodeZigzag(readVaruint())

        fun readBytes(): ByteArray {
            val n = readVaruint()
            if (n < 0 || n > input.size - offset) throw Errors.unexpectedEOF()
            return readExact(n.toInt())
        }

        fun readString(): String {
            val bytes = readBytes()
            try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
            } catch (_: Exception) {
                throw Errors.utf8Error()
            }
            return String(bytes, Charsets.UTF_8)
        }

        fun readBitmap(): BooleanArray {
            val bitCount = readCount()
            val byteCount = ((bitCount + 7L) / 8L).toInt()
            val raw = readExact(byteCount)
            return BooleanArray(bitCount.toInt()) { i ->
                ((raw[i / 8].toInt() and 0xFF) shr (i % 8)) and 1 == 1
            }
        }
    }

    @JvmStatic fun newReader(input: ByteArray): Reader = Reader(input)

    @JvmStatic fun readU64LE(r: Reader): Long {
        val b = r.readExact(8)
        return (b[0].toLong() and 0xFF) or
            ((b[1].toLong() and 0xFF) shl 8) or
            ((b[2].toLong() and 0xFF) shl 16) or
            ((b[3].toLong() and 0xFF) shl 24) or
            ((b[4].toLong() and 0xFF) shl 32) or
            ((b[5].toLong() and 0xFF) shl 40) or
            ((b[6].toLong() and 0xFF) shl 48) or
            ((b[7].toLong() and 0xFF) shl 56)
    }

    @JvmStatic fun readF64LE(r: Reader): Double = java.lang.Double.longBitsToDouble(readU64LE(r))

    @JvmStatic fun appendU64LE(out: ByteArrayOutputStream, v: Long) {
        out.write((v and 0xFF).toInt())
        out.write(((v ushr 8) and 0xFF).toInt())
        out.write(((v ushr 16) and 0xFF).toInt())
        out.write(((v ushr 24) and 0xFF).toInt())
        out.write(((v ushr 32) and 0xFF).toInt())
        out.write(((v ushr 40) and 0xFF).toInt())
        out.write(((v ushr 48) and 0xFF).toInt())
        out.write(((v ushr 56) and 0xFF).toInt())
    }

    @JvmStatic fun appendF64LE(out: ByteArrayOutputStream, v: Double) {
        appendU64LE(out, java.lang.Double.doubleToRawLongBits(v))
    }
}
