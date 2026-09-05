package io.twilic;

import io.twilic.internal.core.Api;
import io.twilic.internal.core.BaseRef;
import io.twilic.internal.core.KeyRef;
import io.twilic.internal.core.MapEntry;
import io.twilic.internal.core.Schema;
import io.twilic.internal.core.SessionEncoder;
import io.twilic.internal.core.Value;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class Twilic {
  private Twilic() {}

  public static byte[] encode(Value value) {
    return Api.Encode(value);
  }

  public static Value decode(byte[] bytes) {
    return Api.Decode(bytes);
  }

  public static byte[] encodeWithSchema(Schema schema, Value value) {
    return Api.EncodeWithSchema(schema, value);
  }

  public static byte[] encodeBatch(List<Value> values) {
    return Api.EncodeBatch(values);
  }

  public static Value newNull() {
    return Value.ofNull();
  }

  public static Value newBool(boolean b) {
    return Value.ofBool(b);
  }

  public static Value newI64(long n) {
    return Value.ofI64(n);
  }

  public static Value newU64(long n) {
    return Value.ofU64(n);
  }

  public static Value newF64(double n) {
    return Value.ofF64(n);
  }

  public static Value newString(String s) {
    return Value.ofString(s);
  }

  public static Value newBinary(byte[] b) {
    return Value.ofBinary(b);
  }

  public static Value newArray(List<Value> items) {
    return Value.ofArray(items);
  }

  public static MapEntry entry(String key, Value value) {
    return new MapEntry(key, value);
  }

  public static Value newMap(MapEntry... entries) {
    return Value.ofMap(new ArrayList<>(Arrays.asList(entries)));
  }

  public static boolean equal(Value a, Value b) {
    if (a.kind != b.kind) {
      return false;
    }
    return switch (a.kind) {
      case NULL -> true;
      case BOOL -> a.bool == b.bool;
      case I64 -> a.i64 == b.i64;
      case U64 -> a.u64 == b.u64;
      case F64 -> Double.compare(a.f64, b.f64) == 0;
      case STRING -> a.str.equals(b.str);
      case BINARY -> Arrays.equals(a.bin, b.bin);
      case ARRAY -> {
        if (a.arr.size() != b.arr.size()) {
          yield false;
        }
        boolean same = true;
        for (int i = 0; i < a.arr.size(); i++) {
          if (!equal(a.arr.get(i), b.arr.get(i))) {
            same = false;
            break;
          }
        }
        yield same;
      }
      case MAP -> {
        if (a.map.size() != b.map.size()) {
          yield false;
        }
        boolean same = true;
        for (int i = 0; i < a.map.size(); i++) {
          MapEntry ea = a.map.get(i);
          MapEntry eb = b.map.get(i);
          if (!ea.key.equals(eb.key) || !equal(ea.value, eb.value)) {
            same = false;
            break;
          }
        }
        yield same;
      }
    };
  }

  public static KeyRef keyRefLiteral(String s) {
    return KeyRef.literal(s);
  }

  public static KeyRef keyRefID(long id) {
    return KeyRef.id(id);
  }

  public static BaseRef baseRefPrevious() {
    return BaseRef.previous();
  }

  public static BaseRef baseRefID(long id) {
    return BaseRef.id(id);
  }

  public static SessionEncoder newSessionEncoder() {
    return new SessionEncoder();
  }
}
