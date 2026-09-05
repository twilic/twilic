package io.twilic.internal.core;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;

final class V2 {
  private V2() {}

  static byte[] encodeV2(Value value) {
    try {
      ByteArrayOutputStream bos = new ByteArrayOutputStream();
      DataOutputStream out = new DataOutputStream(bos);
      writeValue(value, out);
      out.flush();
      return bos.toByteArray();
    } catch (IOException e) {
      throw Errors.invalidData("encode failed");
    }
  }

  static Value decodeV2(byte[] bytes) {
    try {
      DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
      Value value = readValue(in, new Wire.Reader(bytes));
      if (in.available() != 0) throw Errors.invalidData("trailing bytes");
      return value;
    } catch (IOException e) {
      throw Errors.invalidData("decode failed");
    }
  }

  private static void writeValue(Value v, DataOutputStream out) throws IOException {
    out.writeByte(v.kind.ordinal());
    switch (v.kind) {
      case NULL -> {}
      case BOOL -> out.writeBoolean(v.bool);
      case I64 -> out.writeLong(v.i64);
      case U64 -> out.writeLong(v.u64);
      case F64 -> out.writeDouble(v.f64);
      case STRING -> out.writeUTF(v.str == null ? "" : v.str);
      case BINARY -> {
        byte[] b = v.bin == null ? new byte[0] : v.bin;
        out.writeInt(b.length);
        out.write(b);
      }
      case ARRAY -> {
        out.writeInt(v.arr.size());
        for (Value item : v.arr) writeValue(item, out);
      }
      case MAP -> {
        out.writeInt(v.map.size());
        for (MapEntry entry : v.map) {
          out.writeUTF(entry.key == null ? "" : entry.key);
          writeValue(entry.value, out);
        }
      }
    }
  }

  private static Value readValue(DataInputStream in, Wire.Reader budget) throws IOException {
    budget.enterDepth();
    try { return readValueInner(in, budget); } finally { budget.leaveDepth(); }
  }

  private static Value readValueInner(DataInputStream in, Wire.Reader budget) throws IOException {
    int tag = in.readUnsignedByte();
    if (tag >= ValueKind.values().length) throw Errors.invalidData("invalid value kind");
    ValueKind kind = ValueKind.values()[tag];
    return switch (kind) {
      case NULL -> Value.ofNull();
      case BOOL -> Value.ofBool(in.readBoolean());
      case I64 -> Value.ofI64(in.readLong());
      case U64 -> Value.ofU64(in.readLong());
      case F64 -> Value.ofF64(in.readDouble());
      case STRING -> Value.ofString(in.readUTF());
      case BINARY -> {
        int n = in.readInt();
        budget.claimOutput(n);
        if (n > in.available()) throw Errors.unexpectedEOF();
        byte[] b = in.readNBytes(n);
        yield Value.ofBinary(b);
      }
      case ARRAY -> {
        int n = in.readInt();
        budget.claimOutput(n);
        java.util.List<Value> arr = new java.util.ArrayList<>();
        for (int i = 0; i < n; i++) arr.add(readValue(in, budget));
        yield Value.ofArray(arr);
      }
      case MAP -> {
        int n = in.readInt();
        budget.claimOutput(n);
        java.util.List<MapEntry> map = new java.util.ArrayList<>();
        for (int i = 0; i < n; i++) {
          String key = in.readUTF();
          map.add(new MapEntry(key, readValue(in, budget)));
        }
        yield Value.ofMap(map);
      }
    };
  }
}
