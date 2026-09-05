package io.twilic.internal.core;

import io.twilic.internal.core.Errors.TwilicException;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class Wire {
  private Wire() {}

  static void encodeVaruint(long value, ByteArrayOutputStream out) {
    if (Long.compareUnsigned(value, 0x80L) < 0) {
      out.write((byte) value);
      return;
    }
    for (; ; ) {
      byte b = (byte) (value & 0x7FL);
      value >>>= 7;
      if (value != 0L) {
        b |= (byte) 0x80;
      }
      out.write(b);
      if (value == 0L) {
        break;
      }
    }
  }

  static long encodeZigzag(long value) {
    return (value << 1) ^ (value >> 63);
  }

  static long decodeZigzag(long value) {
    return (value >>> 1) ^ -(value & 1L);
  }

  static void encodeBytes(byte[] bytes, ByteArrayOutputStream out) {
    encodeVaruint(bytes.length, out);
    out.write(bytes, 0, bytes.length);
  }

  static void encodeString(String value, ByteArrayOutputStream out) {
    encodeBytes(value.getBytes(StandardCharsets.UTF_8), out);
  }

  static void encodeBitmap(boolean[] bits, ByteArrayOutputStream out) {
    encodeVaruint(bits.length, out);
    byte current = 0;
    for (int i = 0; i < bits.length; i++) {
      if (bits[i]) {
        current |= (byte) (1 << (i % 8));
      }
      if (i % 8 == 7) {
        out.write(current);
        current = 0;
      }
    }
    if (bits.length % 8 != 0) {
      out.write(current);
    }
  }

  static final class Reader {
    private final byte[] input;
    private int offset;
    private int depth;
    private long budget;

    Reader(byte[] input) {
      this.input = input;
      this.budget = Math.min(input.length, 1024) * 1024L;
    }

    void claimOutput(long count) {
      if (count < 0 || count > (1 << 20)) throw Errors.invalidData("decode count limit exceeded");
      if (count > budget / 8) throw Errors.invalidData("decode output ratio exceeded");
      budget -= count * 8;
    }

    long readCount() {
      return readCount(1 << 20);
    }

    long readCount(long maximum) {
      long count = readVaruint();
      if (count < 0 || count > maximum) throw Errors.invalidData("decode count limit exceeded");
      claimOutput(count);
      return count;
    }

    void enterDepth() {
      if (depth >= 64) throw Errors.invalidData("decode depth limit exceeded");
      depth++;
    }

    void leaveDepth() {
      depth--;
    }

    int position() {
      return offset;
    }

    boolean isEOF() {
      return offset >= input.length;
    }

    byte readU8() throws TwilicException {
      if (offset >= input.length) {
        throw Errors.unexpectedEOF();
      }
      byte b = input[offset];
      offset++;
      return b;
    }

    byte[] readExact(int n) throws TwilicException {
      int end = offset + n;
      if (n < 0 || n > input.length - offset) {
        throw Errors.unexpectedEOF();
      }
      byte[] slice = Arrays.copyOfRange(input, offset, end);
      offset = end;
      return slice;
    }

    long readVaruint() throws TwilicException {
      int shift = 0;
      long result = 0L;
      for (; ; ) {
        if (shift >= 64) {
          throw Errors.invalidData("varuint too large");
        }
        byte b = readU8();
        if (shift == 63 && (b & 0x7E) != 0) throw Errors.invalidData("varuint too large");
        result |= (long) (b & 0x7F) << shift;
        if ((b & 0x80) == 0) {
          return result;
        }
        shift += 7;
      }
    }

    long readI64Zigzag() throws TwilicException {
      long encoded = readVaruint();
      return decodeZigzag(encoded);
    }

    byte[] readBytes() throws TwilicException {
      long n = readVaruint();
      if (n < 0 || n > input.length - offset) throw Errors.unexpectedEOF();
      return readExact((int) n);
    }

    String readString() throws TwilicException {
      long n = readVaruint();
      if (n < 0 || n > input.length - offset) throw Errors.unexpectedEOF();
      byte[] bytes = readExact((int) n);
      try {
        StandardCharsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes));
      } catch (CharacterCodingException ex) {
        throw Errors.utf8Error();
      }
      return new String(bytes, StandardCharsets.UTF_8);
    }

    boolean[] readBitmap() throws TwilicException {
      long bitCount = readCount();
      int byteCount = (int) ((bitCount + 7L) / 8L);
      byte[] bytes = readExact(byteCount);
      boolean[] bits = new boolean[(int) bitCount];
      for (int i = 0; i < (int) bitCount; i++) {
        bits[i] = (((bytes[i / 8] & 0xFF) >> (i % 8)) & 1) == 1;
      }
      return bits;
    }
  }

  static Reader newReader(byte[] input) {
    return new Reader(input);
  }

  static long readU64LE(Reader r) throws TwilicException {
    byte[] b = r.readExact(8);
    return ((long) b[0] & 0xFF)
        | (((long) b[1] & 0xFF) << 8)
        | (((long) b[2] & 0xFF) << 16)
        | (((long) b[3] & 0xFF) << 24)
        | (((long) b[4] & 0xFF) << 32)
        | (((long) b[5] & 0xFF) << 40)
        | (((long) b[6] & 0xFF) << 48)
        | (((long) b[7] & 0xFF) << 56);
  }

  static double readF64LE(Reader r) throws TwilicException {
    long u = readU64LE(r);
    return Double.longBitsToDouble(u);
  }

  static void appendU64LE(ByteArrayOutputStream out, long v) {
    out.write((byte) v);
    out.write((byte) (v >>> 8));
    out.write((byte) (v >>> 16));
    out.write((byte) (v >>> 24));
    out.write((byte) (v >>> 32));
    out.write((byte) (v >>> 40));
    out.write((byte) (v >>> 48));
    out.write((byte) (v >>> 56));
  }

  static void appendF64LE(ByteArrayOutputStream out, double v) {
    appendU64LE(out, Double.doubleToRawLongBits(v));
  }
}
