package io.twilic.internal.core;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class Value {
  public ValueKind kind;
  public boolean bool;
  public long i64;
  public long u64;
  public double f64;
  public String str;
  public byte[] bin;
  public List<Value> arr = new ArrayList<>();
  public List<MapEntry> map = new ArrayList<>();

  public static Value ofNull() {
    Value v = new Value();
    v.kind = ValueKind.NULL;
    return v;
  }

  public static Value ofBool(boolean b) {
    Value v = new Value();
    v.kind = ValueKind.BOOL;
    v.bool = b;
    return v;
  }

  public static Value ofI64(long n) {
    Value v = new Value();
    v.kind = ValueKind.I64;
    v.i64 = n;
    return v;
  }

  public static Value ofU64(long n) {
    Value v = new Value();
    v.kind = ValueKind.U64;
    v.u64 = n;
    return v;
  }

  public static Value ofF64(double n) {
    Value v = new Value();
    v.kind = ValueKind.F64;
    v.f64 = n;
    return v;
  }

  public static Value ofString(String s) {
    Value v = new Value();
    v.kind = ValueKind.STRING;
    v.str = s == null ? "" : s;
    return v;
  }

  public static Value ofBinary(byte[] b) {
    Value v = new Value();
    v.kind = ValueKind.BINARY;
    v.bin = b == null ? new byte[0] : Arrays.copyOf(b, b.length);
    return v;
  }

  public static Value ofArray(List<Value> items) {
    Value v = new Value();
    v.kind = ValueKind.ARRAY;
    if (items != null) {
      for (Value item : items) {
        v.arr.add(item == null ? ofNull() : item.cloneValue());
      }
    }
    return v;
  }

  public static Value ofMap(List<MapEntry> entries) {
    Value v = new Value();
    v.kind = ValueKind.MAP;
    if (entries != null) {
      for (MapEntry entry : entries) {
        v.map.add(
            new MapEntry(entry.key, entry.value == null ? ofNull() : entry.value.cloneValue()));
      }
    }
    return v;
  }

  public Value cloneValue() {
    Value out = new Value();
    out.kind = kind;
    out.bool = bool;
    out.i64 = i64;
    out.u64 = u64;
    out.f64 = f64;
    out.str = str;
    out.bin = bin == null ? null : Arrays.copyOf(bin, bin.length);
    for (Value item : arr) {
      out.arr.add(item == null ? ofNull() : item.cloneValue());
    }
    for (MapEntry entry : map) {
      out.map.add(
          new MapEntry(entry.key, entry.value == null ? ofNull() : entry.value.cloneValue()));
    }
    return out;
  }
}
