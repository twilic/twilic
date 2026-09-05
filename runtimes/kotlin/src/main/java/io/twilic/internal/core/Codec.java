package io.twilic.internal.core;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

public final class Codec {
  private static final int[][] SIMPLE8B_SLOTS = {
    {60, 1},
    {30, 2},
    {20, 3},
    {15, 4},
    {12, 5},
    {10, 6},
    {8, 7},
    {7, 8},
    {6, 10},
    {5, 12},
    {4, 15},
    {3, 20},
    {2, 30},
    {1, 60}
  };

  private static final long U64_MAX = -1L;
  private static final long MASK_60 = (1L << 60) - 1L;

  private Codec() {}

  public static void encodeI64Vector(List<Long> values, VectorCodec codec, List<Byte> out) {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    switch (codec) {
      case RLE -> encodeI64Rle(values, bos);
      case DIRECT_BITPACK -> encodeI64DirectBitpack(values, bos);
      case DELTA_BITPACK -> encodeI64DirectBitpack(delta(values), bos);
      case FOR_BITPACK -> {
        if (values.isEmpty()) {
          Wire.encodeVaruint(0, bos);
        } else {
          long minValue = minSigned(values);
          Wire.encodeVaruint(Wire.encodeZigzag(minValue), bos);
          List<Long> shifted = new ArrayList<>(values.size());
          for (long v : values) shifted.add(v - minValue);
          encodeI64DirectBitpack(shifted, bos);
        }
      }
      case DELTA_FOR_BITPACK -> {
        List<Long> deltas = delta(values);
        if (deltas.isEmpty()) {
          Wire.encodeVaruint(0, bos);
        } else {
          long minValue = minSigned(deltas);
          Wire.encodeVaruint(Wire.encodeZigzag(minValue), bos);
          List<Long> shifted = new ArrayList<>(deltas.size());
          for (long v : deltas) shifted.add(v - minValue);
          encodeI64DirectBitpack(shifted, bos);
        }
      }
      case DELTA_DELTA_BITPACK -> encodeI64DeltaDelta(values, bos);
      case PATCHED_FOR -> encodeI64PatchedFor(values, bos);
      case SIMPLE8B -> encodeI64Simple8b(values, bos);
      case PLAIN, DICTIONARY, STRING_REF, PREFIX_DELTA, XOR_FLOAT -> encodeI64Plain(values, bos);
      default -> throw Errors.invalidData("unsupported vector codec");
    }
    appendBytes(out, bos);
  }

  public static List<Long> decodeI64Vector(Wire.Reader reader, VectorCodec codec) {
    return switch (codec) {
      case RLE -> decodeI64Rle(reader);
      case DIRECT_BITPACK -> decodeI64DirectBitpack(reader);
      case DELTA_BITPACK -> undelta(decodeI64DirectBitpack(reader));
      case FOR_BITPACK -> {
        long encodedMin = reader.readVaruint();
        long minValue = Wire.decodeZigzag(encodedMin);
        if (reader.isEOF()) {
          yield new ArrayList<>();
        }
        List<Long> shifted = decodeI64DirectBitpack(reader);
        List<Long> out = new ArrayList<>(shifted.size());
        for (long v : shifted) out.add(v + minValue);
        yield out;
      }
      case DELTA_FOR_BITPACK -> {
        long encodedMin = reader.readVaruint();
        long minValue = Wire.decodeZigzag(encodedMin);
        if (reader.isEOF()) {
          yield new ArrayList<>();
        }
        List<Long> shifted = decodeI64DirectBitpack(reader);
        List<Long> deltas = new ArrayList<>(shifted.size());
        for (long v : shifted) deltas.add(v + minValue);
        yield undelta(deltas);
      }
      case DELTA_DELTA_BITPACK -> decodeI64DeltaDelta(reader);
      case PATCHED_FOR -> decodeI64PatchedFor(reader);
      case SIMPLE8B -> decodeI64Simple8b(reader);
      case PLAIN, DICTIONARY, STRING_REF, PREFIX_DELTA, XOR_FLOAT -> decodeI64Plain(reader);
      default -> throw Errors.invalidData("unsupported vector codec");
    };
  }

  public static void encodeU64Vector(List<Long> values, VectorCodec codec, List<Byte> out) {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    switch (codec) {
      case RLE -> encodeU64Rle(values, bos);
      case DIRECT_BITPACK -> encodeU64DirectBitpack(values, bos);
      case FOR_BITPACK -> {
        if (values.isEmpty()) {
          Wire.encodeVaruint(0, bos);
        } else {
          long minValue = minUnsigned(values);
          Wire.encodeVaruint(minValue, bos);
          List<Long> shifted = new ArrayList<>(values.size());
          for (long v : values) shifted.add(v - minValue);
          encodeU64DirectBitpack(shifted, bos);
        }
      }
      case PLAIN -> encodeU64Plain(values, bos);
      case SIMPLE8B -> encodeU64Simple8b(values, bos);
      case DICTIONARY,
          STRING_REF,
          PREFIX_DELTA,
          XOR_FLOAT,
          DELTA_BITPACK,
          DELTA_FOR_BITPACK,
          DELTA_DELTA_BITPACK,
          PATCHED_FOR ->
          encodeU64Plain(values, bos);
      default -> throw Errors.invalidData("unsupported vector codec");
    }
    appendBytes(out, bos);
  }

  public static List<Long> decodeU64Vector(Wire.Reader reader, VectorCodec codec) {
    return switch (codec) {
      case RLE -> decodeU64Rle(reader);
      case DIRECT_BITPACK -> decodeU64DirectBitpack(reader);
      case FOR_BITPACK -> {
        long minValue = reader.readVaruint();
        if (reader.isEOF()) {
          yield new ArrayList<>();
        }
        List<Long> shifted = decodeU64DirectBitpack(reader);
        List<Long> out = new ArrayList<>(shifted.size());
        for (long v : shifted) {
          AddResult sum = checkedAddU64(v, minValue);
          if (!sum.ok) {
            throw Errors.invalidData("u64 FOR overflow");
          }
          out.add(sum.value);
        }
        yield out;
      }
      case PLAIN -> decodeU64Plain(reader);
      case SIMPLE8B -> decodeU64Simple8b(reader);
      case DICTIONARY,
          STRING_REF,
          PREFIX_DELTA,
          XOR_FLOAT,
          DELTA_BITPACK,
          DELTA_FOR_BITPACK,
          DELTA_DELTA_BITPACK,
          PATCHED_FOR ->
          decodeU64Plain(reader);
      default -> throw Errors.invalidData("unsupported vector codec");
    };
  }

  public static void encodeF64Vector(List<Double> values, VectorCodec codec, List<Byte> out) {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    if (codec == VectorCodec.XOR_FLOAT) {
      encodeXorFloat(values, bos);
    } else {
      Wire.encodeVaruint(values.size(), bos);
      for (double v : values) {
        Wire.appendF64LE(bos, v);
      }
    }
    appendBytes(out, bos);
  }

  public static List<Double> decodeF64Vector(Wire.Reader reader, VectorCodec codec) {
    if (codec == VectorCodec.XOR_FLOAT) {
      return decodeXorFloat(reader);
    }
    long length = reader.readCount();
    List<Double> out = new ArrayList<>();
    for (long i = 0; i < length; i++) {
      out.add(Wire.readF64LE(reader));
    }
    return out;
  }

  private static void encodeU64Plain(List<Long> values, ByteArrayOutputStream out) {
    Wire.encodeVaruint(values.size(), out);
    for (long value : values) {
      Wire.encodeVaruint(value, out);
    }
  }

  private static List<Long> decodeU64Plain(Wire.Reader reader) {
    long length = reader.readCount();
    List<Long> out = new ArrayList<>();
    for (long i = 0; i < length; i++) {
      out.add(reader.readVaruint());
    }
    return out;
  }

  private static void encodeU64Rle(List<Long> values, ByteArrayOutputStream out) {
    List<Run> runs = new ArrayList<>();
    for (long value : values) {
      if (!runs.isEmpty() && runs.getLast().value == value) {
        Run last = runs.getLast();
        runs.set(runs.size() - 1, new Run(value, last.count + 1L));
      } else {
        runs.add(new Run(value, 1L));
      }
    }
    Wire.encodeVaruint(runs.size(), out);
    for (Run run : runs) {
      Wire.encodeVaruint(run.value, out);
      Wire.encodeVaruint(run.count, out);
    }
  }

  private static List<Long> decodeU64Rle(Wire.Reader reader) {
    long runsLen = reader.readCount();
    List<Long> out = new ArrayList<>();
    for (long i = 0; i < runsLen; i++) {
      long value = reader.readVaruint();
      long count = reader.readCount();
      for (long j = 0; j < count; j++) {
        out.add(value);
      }
    }
    return out;
  }

  private static void encodeU64DirectBitpack(List<Long> values, ByteArrayOutputStream out) {
    Wire.encodeVaruint(values.size(), out);
    if (values.isEmpty()) {
      out.write(0);
      return;
    }
    int width = 1;
    for (long v : values) {
      int bw = bitWidth(v);
      if (bw > width) {
        width = bw;
      }
    }
    out.write(width);
    packU64Values(values, width, out);
  }

  private static List<Long> decodeU64DirectBitpack(Wire.Reader reader) {
    long length = reader.readCount();
    int width = Byte.toUnsignedInt(reader.readU8());
    if (length == 0) {
      return new ArrayList<>();
    }
    if (width == 0 || width > 64) {
      throw Errors.invalidData("bitpack width");
    }
    return unpackU64Values(reader, length, width);
  }

  private static void encodeI64Plain(List<Long> values, ByteArrayOutputStream out) {
    Wire.encodeVaruint(values.size(), out);
    for (long value : values) {
      Wire.encodeVaruint(Wire.encodeZigzag(value), out);
    }
  }

  private static List<Long> decodeI64Plain(Wire.Reader reader) {
    long length = reader.readCount();
    List<Long> out = new ArrayList<>();
    for (long i = 0; i < length; i++) {
      out.add(Wire.decodeZigzag(reader.readVaruint()));
    }
    return out;
  }

  private static void encodeI64Simple8b(List<Long> values, ByteArrayOutputStream out) {
    List<Long> encoded = new ArrayList<>(values.size());
    for (long v : values) {
      encoded.add(Wire.encodeZigzag(v));
    }
    encodeU64Simple8bInner(encoded, out);
  }

  private static List<Long> decodeI64Simple8b(Wire.Reader reader) {
    List<Long> encoded = decodeU64Simple8bInner(reader);
    List<Long> out = new ArrayList<>(encoded.size());
    for (long v : encoded) {
      out.add(Wire.decodeZigzag(v));
    }
    return out;
  }

  private static void encodeU64Simple8b(List<Long> values, ByteArrayOutputStream out) {
    encodeU64Simple8bInner(values, out);
  }

  private static List<Long> decodeU64Simple8b(Wire.Reader reader) {
    return decodeU64Simple8bInner(reader);
  }

  private static void encodeU64Simple8bInner(List<Long> values, ByteArrayOutputStream out) {
    Wire.encodeVaruint(values.size(), out);
    if (values.isEmpty()) {
      return;
    }

    long maxValue = values.getFirst();
    for (int i = 1; i < values.size(); i++) {
      long v = values.get(i);
      if (Long.compareUnsigned(v, maxValue) > 0) {
        maxValue = v;
      }
    }

    if (Long.compareUnsigned(maxValue, MASK_60) > 0) {
      out.write(0);
      for (long value : values) {
        Wire.encodeVaruint(value, out);
      }
      return;
    }

    out.write(1);
    int idx = 0;
    while (idx < values.size()) {
      int zeroRun = 0;
      while (idx + zeroRun < values.size() && values.get(idx + zeroRun) == 0L && zeroRun < 240) {
        zeroRun++;
      }
      if (zeroRun >= 120) {
        int take = zeroRun >= 240 ? 240 : 120;
        long word = take == 240 ? 0L : (1L << 60);
        Wire.appendU64LE(out, word);
        idx += take;
        continue;
      }

      boolean packed = false;
      for (int selectorIdx = 0; selectorIdx < SIMPLE8B_SLOTS.length; selectorIdx++) {
        int count = SIMPLE8B_SLOTS[selectorIdx][0];
        int slotWidth = SIMPLE8B_SLOTS[selectorIdx][1];
        if (idx + count > values.size()) {
          continue;
        }

        long maxEncodable = slotWidth == 64 ? U64_MAX : ((1L << slotWidth) - 1L);
        boolean ok = true;
        for (int j = 0; j < count; j++) {
          long v = values.get(idx + j);
          if (Long.compareUnsigned(v, maxEncodable) > 0) {
            ok = false;
            break;
          }
        }
        if (!ok) {
          continue;
        }

        long selector = selectorIdx + 2L;
        long payload = 0L;
        int shift = 0;
        for (int j = 0; j < count; j++) {
          long value = values.get(idx + j);
          payload |= value << shift;
          shift += slotWidth;
        }
        long word = (selector << 60) | payload;
        Wire.appendU64LE(out, word);
        idx += count;
        packed = true;
        break;
      }
      if (!packed) {
        long selector = 15L;
        long word = (selector << 60) | (values.get(idx) & MASK_60);
        Wire.appendU64LE(out, word);
        idx++;
      }
    }
  }

  private static List<Long> decodeU64Simple8bInner(Wire.Reader reader) {
    long length = reader.readCount();
    if (length == 0) {
      return new ArrayList<>();
    }
    int mode = Byte.toUnsignedInt(reader.readU8());
    if (mode == 0) {
      List<Long> out = new ArrayList<>();
      for (long i = 0; i < length; i++) {
        out.add(reader.readVaruint());
      }
      return out;
    }
    if (mode != 1) {
      throw Errors.invalidData("simple8b mode");
    }

    List<Long> out = new ArrayList<>();
    while (Long.compareUnsigned(out.size(), length) < 0) {
      long packed = Wire.readU64LE(reader);
      long selector = packed >>> 60;
      long payload = packed & MASK_60;
      if (selector == 0 || selector == 1) {
        int count = selector == 0 ? 240 : 120;
        long remain = length - out.size();
        long limit = Math.min(count, remain);
        for (long i = 0; i < limit; i++) {
          out.add(0L);
        }
      } else if (selector >= 2 && selector <= 15) {
        int count;
        int width;
        if (selector == 15) {
          count = 1;
          width = 60;
        } else {
          int[] slot = SIMPLE8B_SLOTS[(int) selector - 2];
          count = slot[0];
          width = slot[1];
        }
        long mask = width == 64 ? U64_MAX : ((1L << width) - 1L);
        int shift = 0;
        long remain = length - out.size();
        long limit = Math.min(count, remain);
        for (long i = 0; i < limit; i++) {
          out.add((payload >>> shift) & mask);
          shift += width;
        }
      } else {
        throw Errors.invalidData("simple8b selector");
      }
    }
    return out;
  }

  private static List<Long> delta(List<Long> values) {
    List<Long> out = new ArrayList<>(values.size());
    long prev = 0;
    for (int i = 0; i < values.size(); i++) {
      long value = values.get(i);
      if (i == 0) {
        out.add(value);
      } else {
        out.add(value - prev);
      }
      prev = value;
    }
    return out;
  }

  private static List<Long> undelta(List<Long> values) {
    List<Long> out = new ArrayList<>(values.size());
    long prev = 0;
    for (int i = 0; i < values.size(); i++) {
      long value = values.get(i);
      if (i == 0) {
        out.add(value);
        prev = value;
        continue;
      }
      AddResult nxt = checkedAddI64(prev, value);
      if (!nxt.ok) {
        throw Errors.invalidData("delta overflow");
      }
      out.add(nxt.value);
      prev = nxt.value;
    }
    return out;
  }

  private static void encodeI64Rle(List<Long> values, ByteArrayOutputStream out) {
    List<Run> runs = new ArrayList<>();
    for (long value : values) {
      if (!runs.isEmpty() && runs.getLast().value == value) {
        Run last = runs.getLast();
        runs.set(runs.size() - 1, new Run(value, last.count + 1L));
      } else {
        runs.add(new Run(value, 1L));
      }
    }
    Wire.encodeVaruint(runs.size(), out);
    for (Run run : runs) {
      Wire.encodeVaruint(Wire.encodeZigzag(run.value), out);
      Wire.encodeVaruint(run.count, out);
    }
  }

  private static List<Long> decodeI64Rle(Wire.Reader reader) {
    long runsLen = reader.readCount();
    List<Long> out = new ArrayList<>();
    for (long i = 0; i < runsLen; i++) {
      long value = Wire.decodeZigzag(reader.readVaruint());
      long count = reader.readCount();
      for (long j = 0; j < count; j++) {
        out.add(value);
      }
    }
    return out;
  }

  private static void encodeI64PatchedFor(List<Long> values, ByteArrayOutputStream out) {
    if (values.isEmpty()) {
      Wire.encodeVaruint(0, out);
      return;
    }
    long base = minSigned(values);
    List<Long> shifted = new ArrayList<>(values.size());
    for (long v : values) shifted.add(v - base);
    Wire.encodeVaruint(shifted.size(), out);
    Wire.encodeVaruint(Wire.encodeZigzag(base), out);

    long maxValue = shifted.getFirst();
    for (int i = 1; i < shifted.size(); i++) {
      if (Long.compareUnsigned(shifted.get(i), maxValue) > 0) {
        maxValue = shifted.get(i);
      }
    }
    int bw = bitWidth(maxValue);
    int baseWidth = bw > 2 ? bw - 2 : 0;
    out.write(baseWidth);

    List<Patch> patchPositions = new ArrayList<>();
    List<Long> mainValues = new ArrayList<>(shifted.size());
    for (int idx = 0; idx < shifted.size(); idx++) {
      long value = shifted.get(idx);
      if (bitWidth(value) > baseWidth) {
        patchPositions.add(new Patch(idx, value));
        long main = 0L;
        if (baseWidth > 0) {
          long mask = (1L << baseWidth) - 1L;
          main = value & mask;
          if (main < 0) {
            main = 0;
          }
        }
        mainValues.add(main);
      } else {
        mainValues.add(value);
      }
    }

    for (long value : mainValues) {
      Wire.encodeVaruint(value, out);
    }
    Wire.encodeVaruint(patchPositions.size(), out);
    for (Patch patch : patchPositions) {
      Wire.encodeVaruint(patch.position, out);
      Wire.encodeVaruint(patch.value, out);
    }
  }

  private static List<Long> decodeI64PatchedFor(Wire.Reader reader) {
    long length = reader.readCount();
    if (length == 0) {
      return new ArrayList<>();
    }
    long base = Wire.decodeZigzag(reader.readVaruint());
    reader.readU8();
    List<Long> values = new ArrayList<>();
    for (long i = 0; i < length; i++) {
      values.add(reader.readVaruint());
    }
    long patchCount = reader.readCount();
    for (long i = 0; i < patchCount; i++) {
      long pos = reader.readVaruint();
      long patch = reader.readVaruint();
      if (Long.compareUnsigned(pos, values.size()) < 0) {
        values.set((int) pos, patch);
      }
    }
    List<Long> out = new ArrayList<>(values.size());
    for (long v : values) out.add(v + base);
    return out;
  }

  private static int leadingZeros64(long x) {
    return x == 0 ? 64 : Long.numberOfLeadingZeros(x);
  }

  private static int trailingZeros64(long x) {
    return x == 0 ? 64 : Long.numberOfTrailingZeros(x);
  }

  private static void encodeXorFloat(List<Double> values, ByteArrayOutputStream out) {
    Wire.encodeVaruint(values.size(), out);
    if (values.isEmpty()) {
      return;
    }
    long firstBits = Double.doubleToRawLongBits(values.getFirst());
    Wire.appendU64LE(out, firstBits);
    long prev = firstBits;

    for (int i = 1; i < values.size(); i++) {
      long bitsValue = Double.doubleToRawLongBits(values.get(i));
      long x = prev ^ bitsValue;
      if (x == 0) {
        out.write(0);
      } else {
        out.write(1);
        int leading = leadingZeros64(x);
        int trailing = trailingZeros64(x);
        int width = 64 - (leading + trailing);
        Wire.encodeVaruint(leading, out);
        Wire.encodeVaruint(trailing, out);
        Wire.encodeVaruint(width, out);
        long payload = width == 64 ? x : ((x >>> trailing) & ((1L << width) - 1L));
        Wire.encodeVaruint(payload, out);
      }
      prev = bitsValue;
    }
  }

  private static List<Double> decodeXorFloat(Wire.Reader reader) {
    long length = reader.readCount();
    if (length == 0) {
      return new ArrayList<>();
    }
    long firstBits = Wire.readU64LE(reader);
    List<Double> out = new ArrayList<>();
    out.add(Double.longBitsToDouble(firstBits));
    long prev = firstBits;

    for (long i = 1; i < length; i++) {
      int flag = Byte.toUnsignedInt(reader.readU8());
      long bitsValue = prev;
      if (flag != 0) {
        long leading = reader.readVaruint();
        long trailing = reader.readVaruint();
        long width = reader.readVaruint();
        long payload = reader.readVaruint();
        if (leading + trailing + width > 64) {
          throw Errors.invalidData("xor-float bit widths");
        }
        long x = width == 64 ? payload : (payload << trailing);
        bitsValue = prev ^ x;
      }
      out.add(Double.longBitsToDouble(bitsValue));
      prev = bitsValue;
    }
    return out;
  }

  private static void encodeI64DirectBitpack(List<Long> values, ByteArrayOutputStream out) {
    Wire.encodeVaruint(values.size(), out);
    if (values.isEmpty()) {
      out.write(0);
      return;
    }
    List<Long> encoded = new ArrayList<>(values.size());
    for (long v : values) encoded.add(Wire.encodeZigzag(v));
    int width = 1;
    for (long v : encoded) {
      int bw = bitWidth(v);
      if (bw > width) {
        width = bw;
      }
    }
    out.write(width);
    packU64Values(encoded, width, out);
  }

  private static List<Long> decodeI64DirectBitpack(Wire.Reader reader) {
    long length = reader.readCount();
    int width = Byte.toUnsignedInt(reader.readU8());
    if (length == 0) {
      return new ArrayList<>();
    }
    if (width == 0 || width > 64) {
      throw Errors.invalidData("bitpack width");
    }
    List<Long> encoded = unpackU64Values(reader, length, width);
    List<Long> out = new ArrayList<>(encoded.size());
    for (long v : encoded) {
      out.add(Wire.decodeZigzag(v));
    }
    return out;
  }

  private static void encodeI64DeltaDelta(List<Long> values, ByteArrayOutputStream out) {
    Wire.encodeVaruint(values.size(), out);
    if (values.isEmpty()) {
      return;
    }
    Wire.encodeVaruint(Wire.encodeZigzag(values.getFirst()), out);
    if (values.size() == 1) {
      return;
    }
    long d1 = values.get(1) - values.getFirst();
    Wire.encodeVaruint(Wire.encodeZigzag(d1), out);

    List<Long> dd = new ArrayList<>();
    long prevDelta = d1;
    for (int i = 1; i < values.size() - 1; i++) {
      long d = values.get(i + 1) - values.get(i);
      dd.add(d - prevDelta);
      prevDelta = d;
    }
    encodeI64DirectBitpack(dd, out);
  }

  private static List<Long> decodeI64DeltaDelta(Wire.Reader reader) {
    long length = reader.readCount();
    if (length == 0) {
      return new ArrayList<>();
    }
    long first = Wire.decodeZigzag(reader.readVaruint());
    if (length == 1) {
      List<Long> only = new ArrayList<>();
      only.add(first);
      return only;
    }
    long firstDelta = Wire.decodeZigzag(reader.readVaruint());
    List<Long> dd = decodeI64DirectBitpack(reader);
    if (dd.size() != length - 2) {
      throw Errors.invalidData("delta-delta length");
    }

    List<Long> out = new ArrayList<>();
    out.add(first);
    long prev = first;
    AddResult second = checkedAddI64(prev, firstDelta);
    if (!second.ok) {
      throw Errors.invalidData("delta-delta overflow");
    }
    out.add(second.value);
    prev = second.value;
    long prevDelta = firstDelta;

    for (long ddv : dd) {
      AddResult d = checkedAddI64(prevDelta, ddv);
      if (!d.ok) {
        throw Errors.invalidData("delta-delta overflow");
      }
      AddResult next = checkedAddI64(prev, d.value);
      if (!next.ok) {
        throw Errors.invalidData("delta-delta overflow");
      }
      out.add(next.value);
      prev = next.value;
      prevDelta = d.value;
    }
    return out;
  }

  private static void packU64Values(List<Long> values, int width, ByteArrayOutputStream out) {
    long totalBits = (long) values.size() * width;
    int byteLen = (int) ((totalBits + 7L) / 8L);
    byte[] bytesArr = new byte[byteLen];
    long bitPos = 0;
    for (long value : values) {
      int written = 0;
      while (written < width) {
        int byteIdx = (int) (bitPos / 8L);
        int bitOff = (int) (bitPos % 8L);
        int room = 8 - bitOff;
        int take = Math.min(width - written, room);
        long mask = (1L << take) - 1L;
        long part = (value >>> written) & mask;
        bytesArr[byteIdx] = (byte) (Byte.toUnsignedInt(bytesArr[byteIdx]) | ((int) part << bitOff));
        bitPos += take;
        written += take;
      }
    }
    out.write(bytesArr, 0, bytesArr.length);
  }

  private static List<Long> unpackU64Values(Wire.Reader reader, long length, int width) {
    long totalBits = length * width;
    int byteLen = (int) ((totalBits + 7L) / 8L);
    byte[] raw = reader.readExact(byteLen);
    List<Long> out = new ArrayList<>();
    long bitPos = 0;
    for (long i = 0; i < length; i++) {
      long value = 0L;
      int written = 0;
      while (written < width) {
        int byteIdx = (int) (bitPos / 8L);
        if (byteIdx >= raw.length) {
          throw Errors.invalidData("bitpack underflow");
        }
        int bitOff = (int) (bitPos % 8L);
        int room = 8 - bitOff;
        int take = Math.min(width - written, room);
        long mask = (1L << take) - 1L;
        long part = (Byte.toUnsignedInt(raw[byteIdx]) >>> bitOff) & mask;
        value |= part << written;
        bitPos += take;
        written += take;
      }
      out.add(value);
    }
    return out;
  }

  private static int bitWidth(long v) {
    if (v == 0L) {
      return 1;
    }
    return 64 - Long.numberOfLeadingZeros(v);
  }

  private static AddResult checkedAddU64(long a, long b) {
    long total = a + b;
    if (Long.compareUnsigned(total, a) < 0) {
      return new AddResult(0L, false);
    }
    return new AddResult(total, true);
  }

  private static AddResult checkedAddI64(long a, long b) {
    long total = a + b;
    if ((b > 0 && total < a) || (b < 0 && total > a)) {
      return new AddResult(0L, false);
    }
    return new AddResult(total, true);
  }

  private static long minSigned(List<Long> values) {
    long min = values.getFirst();
    for (int i = 1; i < values.size(); i++) {
      min = Math.min(min, values.get(i));
    }
    return min;
  }

  private static long minUnsigned(List<Long> values) {
    long min = values.getFirst();
    for (int i = 1; i < values.size(); i++) {
      long v = values.get(i);
      if (Long.compareUnsigned(v, min) < 0) {
        min = v;
      }
    }
    return min;
  }

  private static void appendBytes(List<Byte> out, ByteArrayOutputStream bytes) {
    for (byte b : bytes.toByteArray()) {
      out.add(b);
    }
  }

  private record AddResult(long value, boolean ok) {}

  private record Run(long value, long count) {}

  private record Patch(long position, long value) {}
}
