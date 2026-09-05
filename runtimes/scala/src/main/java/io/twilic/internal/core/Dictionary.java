package io.twilic.internal.core;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

public final class Dictionary {
  private Dictionary() {}

  public record EncodedDictionaryBlock(byte[] block, boolean ok) {}

  public static List<String> decodeTrainedDictionaryPayload(byte[] payload) {
    Wire.Reader reader = Wire.newReader(payload);
    long n = reader.readCount();
    List<String> values = new ArrayList<>();
    for (long i = 0; i < n; i++) {
      values.add(reader.readString());
    }
    if (!reader.isEOF()) {
      throw Errors.invalidData("trained dictionary payload trailing bytes");
    }
    return values;
  }

  public static EncodedDictionaryBlock encodeTrainedDictionaryBlock(
      List<String> values, List<String> dictionary) {
    if (values.isEmpty()) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      out.write(0);
      Wire.encodeVaruint(0, out);
      return new EncodedDictionaryBlock(out.toByteArray(), true);
    }

    Map<String, Long> byValue = new HashMap<>();
    for (int i = 0; i < dictionary.size(); i++) {
      byValue.put(dictionary.get(i), (long) i);
    }

    List<Long> ids = new ArrayList<>(values.size());
    for (String value : values) {
      Long refId = byValue.get(value);
      if (refId == null) {
        return new EncodedDictionaryBlock(null, false);
      }
      ids.add(refId);
    }

    ByteArrayOutputStream raw = new ByteArrayOutputStream();
    raw.write(0);
    Wire.encodeVaruint(ids.size(), raw);
    for (long refId : ids) {
      Wire.encodeVaruint(refId, raw);
    }

    long maxId = 0L;
    for (long id : ids) {
      if (Long.compareUnsigned(id, maxId) > 0) {
        maxId = id;
      }
    }
    int bitWidth = maxId == 0L ? 0 : (64 - Long.numberOfLeadingZeros(maxId));
    ByteArrayOutputStream packed = new ByteArrayOutputStream();
    packFixedWidthU64(ids, bitWidth, packed);

    ByteArrayOutputStream bitpacked = new ByteArrayOutputStream();
    bitpacked.write(1);
    Wire.encodeVaruint(ids.size(), bitpacked);
    bitpacked.write(bitWidth);
    bitpacked.write(packed.toByteArray(), 0, packed.size());

    if (bitpacked.size() < raw.size()) {
      return new EncodedDictionaryBlock(bitpacked.toByteArray(), true);
    }
    return new EncodedDictionaryBlock(raw.toByteArray(), true);
  }

  public static List<String> decodeTrainedDictionaryBlock(byte[] block, List<String> dictionary) {
    Wire.Reader reader = Wire.newReader(block);
    int mode = Byte.toUnsignedInt(reader.readU8());
    long n = reader.readCount();
    List<Long> ids;
    if (mode == 0) {
      ids = new ArrayList<>();
      for (long i = 0; i < n; i++) {
        ids.add(reader.readVaruint());
      }
    } else if (mode == 1) {
      int bitWidth = Byte.toUnsignedInt(reader.readU8());
      int remaining = block.length - reader.position();
      byte[] packed = reader.readExact(remaining);
      ids = unpackFixedWidthU64(packed, n, bitWidth);
    } else {
      throw Errors.invalidData("trained dictionary block mode");
    }

    if (!reader.isEOF()) {
      throw Errors.invalidData("trained dictionary block trailing bytes");
    }

    List<String> out = new ArrayList<>();
    for (long refId : ids) {
      if (Long.compareUnsigned(refId, dictionary.size()) >= 0) {
        throw Errors.invalidData("trained dictionary block id");
      }
      out.add(dictionary.get((int) refId));
    }
    return out;
  }

  private static final class WideU128 {
    private final long lo;
    private final long hi;

    private WideU128() {
      this(0L, 0L);
    }

    private WideU128(long lo, long hi) {
      this.lo = lo;
      this.hi = hi;
    }

    private static WideU128 fromU64(long v) {
      return new WideU128(v, 0L);
    }

    private static WideU128 mask(int width) {
      if (width == 64) {
        return new WideU128(-1L, -1L);
      }
      if (width == 0) {
        return new WideU128();
      }
      if (width <= 64) {
        return new WideU128((1L << width) - 1L, 0L);
      }
      long lo = -1L;
      long hi = (1L << (width - 64)) - 1L;
      return new WideU128(lo, hi);
    }

    private boolean isZero() {
      return lo == 0L && hi == 0L;
    }

    private WideU128 and(WideU128 other) {
      return new WideU128(lo & other.lo, hi & other.hi);
    }

    private WideU128 or(WideU128 other) {
      return new WideU128(lo | other.lo, hi | other.hi);
    }

    private WideU128 shl(int n) {
      if (n == 0) {
        return new WideU128(lo, hi);
      }
      if (n >= 128) {
        return new WideU128();
      }
      if (n < 64) {
        long newHi = (hi << n) | (lo >>> (64 - n));
        long newLo = lo << n;
        return new WideU128(newLo, newHi);
      }
      int shift = n - 64;
      return new WideU128(0L, lo << shift);
    }

    private WideU128 shr(int n) {
      if (n == 0) {
        return new WideU128(lo, hi);
      }
      if (n >= 128) {
        return new WideU128();
      }
      if (n < 64) {
        long newLo = (lo >>> n) | (hi << (64 - n));
        long newHi = hi >>> n;
        return new WideU128(newLo, newHi);
      }
      int shift = n - 64;
      return new WideU128(hi >>> shift, 0L);
    }
  }

  private static void packFixedWidthU64(List<Long> values, int width, ByteArrayOutputStream out) {
    if (width > 64) {
      throw Errors.invalidData("fixed-width u64 bit width");
    }
    if (width == 0) {
      for (long value : values) {
        if (value != 0L) {
          throw Errors.invalidData("fixed-width u64 value overflow");
        }
      }
      return;
    }
    WideU128 acc = new WideU128();
    int accBits = 0;
    for (long value : values) {
      if (width < 64 && (value >>> width) != 0) {
        throw Errors.invalidData("fixed-width u64 value overflow");
      }
      acc = acc.or(WideU128.fromU64(value).shl(accBits));
      accBits += width;
      while (accBits >= 8) {
        out.write((int) (acc.lo & 0xFFL));
        acc = acc.shr(8);
        accBits -= 8;
      }
    }
    if (accBits > 0) {
      out.write((int) (acc.lo & 0xFFL));
    }
  }

  private static List<Long> unpackFixedWidthU64(byte[] data, long count, int width) {
    if (width > 64) {
      throw Errors.invalidData("fixed-width u64 bit width");
    }
    if (width == 0) {
      for (byte b : data) {
        if (b != 0) {
          throw Errors.invalidData("fixed-width u64 trailing bytes");
        }
      }
      List<Long> zeros = new ArrayList<>();
      for (long i = 0; i < count; i++) {
        zeros.add(0L);
      }
      return zeros;
    }

    List<Long> out = new ArrayList<>();
    WideU128 acc = new WideU128();
    int accBits = 0;
    int idx = 0;
    WideU128 mask = WideU128.mask(width);
    for (long i = 0; i < count; i++) {
      while (accBits < width) {
        if (idx >= data.length) {
          throw Errors.invalidData("fixed-width u64 underflow");
        }
        acc = acc.or(WideU128.fromU64(Byte.toUnsignedLong(data[idx])).shl(accBits));
        idx++;
        accBits += 8;
      }
      out.add(acc.and(mask).lo);
      acc = acc.shr(width);
      accBits -= width;
    }
    if (!acc.isZero()) {
      throw Errors.invalidData("fixed-width u64 trailing bytes");
    }
    for (int j = idx; j < data.length; j++) {
      if (data[j] != 0) {
        throw Errors.invalidData("fixed-width u64 trailing bytes");
      }
    }
    return out;
  }

  public static void applyDictionaryReferences(SessionState state, List<Column> columns) {
    for (Column column : columns) {
      if (column.values.kind != ElementType.STRING) {
        continue;
      }
      List<String> values = column.values.strings;
      if (values.size() < 16) {
        continue;
      }
      Set<String> unique = new HashSet<>(values);
      if ((double) unique.size() / values.size() > 0.5) {
        continue;
      }
      if (column.codec != VectorCodec.DICTIONARY && column.codec != VectorCodec.STRING_REF) {
        continue;
      }

      long dictId = state.nextDictionaryId;
      state.nextDictionaryId += 1;

      ByteArrayOutputStream payload = new ByteArrayOutputStream();
      List<String> keys = new ArrayList<>(new TreeSet<>(unique));
      Wire.encodeVaruint(keys.size(), payload);
      for (String item : keys) {
        Wire.encodeString(item, payload);
      }

      byte[] payloadBytes = payload.toByteArray();
      DictionaryFallback fallback = DictionaryFallback.FAIL_FAST;
      if (state.options.unknownReferencePolicy == UnknownReferencePolicy.STATELESS_RETRY) {
        fallback = DictionaryFallback.STATELESS_RETRY;
      }
      DictionaryProfile profile =
          new DictionaryProfile(1L, dictionaryPayloadHash(payloadBytes), 0L, fallback);
      state.dictionaries.put(dictId, payloadBytes);
      state.dictionaryProfiles.put(dictId, profile);
      column.dictionaryId = dictId;
    }
  }

  public static long dictionaryPayloadHash(byte[] payload) {
    return fnv1a64(payload);
  }

  public static long fnv1a64(byte[] payload) {
    long hash = 0xcbf29ce484222325L;
    for (byte b : payload) {
      hash ^= (b & 0xFFL);
      hash *= 0x100000001b3L;
    }
    return hash;
  }
}
