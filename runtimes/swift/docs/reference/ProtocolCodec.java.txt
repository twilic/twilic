package io.twilic.internal.core;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

final class Protocol {
  private Protocol() {}

  static final int TAG_NULL = 0;
  static final int TAG_BOOL_FALSE = 1;
  static final int TAG_BOOL_TRUE = 2;
  static final int TAG_I64 = 3;
  static final int TAG_U64 = 4;
  static final int TAG_F64 = 5;
  static final int TAG_STRING = 6;
  static final int TAG_BINARY = 7;
  static final int TAG_ARRAY = 8;
  static final int TAG_MAP = 9;
}

final class TwilicCodec {
  final SessionState state;

  TwilicCodec() {
    this(new SessionOptions());
  }

  TwilicCodec(SessionOptions options) {
    this.state = new SessionState();
    this.state.options = options;
  }

  byte[] encodeMessage(Message message) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    writeMessage(message, out);
    return out.toByteArray();
  }

  Message decodeMessage(byte[] bytes) {
    Wire.Reader reader = Wire.newReader(bytes);
    Message message = readMessage(reader);
    if (!reader.isEOF()) {
      throw Errors.invalidData("trailing bytes in message");
    }
    switch (message.kind) {
      case CONTROL -> {}
      case STATE_PATCH -> {
        try {
          Message reconstructed =
              applyStatePatch(
                  message.statePatch.baseRef,
                  message.statePatch.operations,
                  message.statePatch.literals);
          state.previousMessage = reconstructed;
          state.previousMessageSize = bytes.length;
        } catch (Throwable err) {
          if (Errors.isUnknownReference(err) || Errors.isStatelessRetry(err)) {
            throw err;
          }
        }
      }
      case TEMPLATE_BATCH -> {
        if (state.previousMessage == null) {
          state.previousMessage = ProtocolHelpers.cloneMessage(message);
          state.previousMessageSize = bytes.length;
        }
      }
      default -> {
        state.previousMessage = ProtocolHelpers.cloneMessage(message);
        state.previousMessageSize = bytes.length;
      }
    }
    return message;
  }

  byte[] encodeValue(Value value) {
    Message message = messageForValue(value);
    byte[] out = encodeMessage(message);
    state.previousMessage = ProtocolHelpers.cloneMessage(message);
    state.previousMessageSize = out.length;
    return out;
  }

  Value decodeValue(byte[] bytes) {
    Message message = decodeMessage(bytes);
    state.previousMessage = ProtocolHelpers.cloneMessage(message);
    return switch (message.kind) {
      case SCALAR -> ProtocolHelpers.cloneValue(message.scalar);
      case ARRAY -> Value.ofArray(ProtocolHelpers.cloneValues(message.array));
      case MAP -> Value.ofMap(ProtocolHelpers.entriesToMap(message.map, state));
      case SHAPED_OBJECT -> {
        List<String> keys =
            ProtocolHelpers.shapeGetKeys(state.shapeTable, message.shapedObject.shapeId);
        if (keys == null) {
          throw referenceError("shape_id", message.shapedObject.shapeId);
        }
        yield Value.ofMap(
            ProtocolHelpers.shapeValuesToMap(
                keys,
                message.shapedObject.presence,
                message.shapedObject.hasPresence,
                message.shapedObject.values));
      }
      case TYPED_VECTOR -> ProtocolHelpers.typedVectorToValue(message.typedVector);
      default -> throw Errors.invalidData("decode_value expects scalar/array/map/vector message");
    };
  }

  Message messageForValue(Value value) {
    return switch (value.kind) {
      case ARRAY -> {
        TryVectorResult vector = tryMakeTypedVector(value.arr);
        if (vector.ok) {
          Message out = new Message();
          out.kind = MessageKind.TYPED_VECTOR;
          out.typedVector = vector.vector;
          yield out;
        }
        Message out = new Message();
        out.kind = MessageKind.ARRAY;
        out.array = ProtocolHelpers.cloneValues(value.arr);
        yield out;
      }
      case MAP -> {
        List<String> keys = new ArrayList<>();
        for (MapEntry entry : value.map) {
          keys.add(entry.key);
        }
        boolean had = state.encodeShapeObservations.containsKey(ProtocolHelpers.shapeKey(keys));
        long observed = observeEncodeShapeCandidate(keys);
        Long shapeId = ProtocolHelpers.shapeGetId(state.shapeTable, keys);
        if (shapeId != null && (!had || observed >= 2L)) {
          yield shapedMessage(shapeId, value.map);
        }
        yield mapMessage(value.map);
      }
      default -> {
        Message out = new Message();
        out.kind = MessageKind.SCALAR;
        out.scalar = ProtocolHelpers.cloneValue(value);
        yield out;
      }
    };
  }

  private RuntimeException referenceError(String kind, long refId) {
    if (state.options.unknownReferencePolicy == UnknownReferencePolicy.STATELESS_RETRY) {
      return Errors.statelessRetryRequired(kind, refId);
    }
    return Errors.unknownReference(kind, refId);
  }

  private Message mapMessage(List<MapEntry> entries) {
    Message out = new Message();
    out.kind = MessageKind.MAP;
    for (MapEntry entry : entries) {
      Long id = state.keyTable.getId(entry.key);
      KeyRef keyRef = id == null ? KeyRef.literal(entry.key) : KeyRef.id(id);
      if (id == null) {
        state.keyTable.register(entry.key);
      }
      out.map.add(new MessageMapEntry(keyRef, ProtocolHelpers.cloneValue(entry.value)));
    }
    return out;
  }

  private Message shapedMessage(long shapeId, List<MapEntry> entries) {
    List<String> keys = ProtocolHelpers.shapeGetKeys(state.shapeTable, shapeId);
    Map<String, Value> index = new HashMap<>();
    for (MapEntry entry : entries) {
      index.put(entry.key, entry.value);
    }
    ShapedObjectMessage shaped = new ShapedObjectMessage();
    shaped.shapeId = shapeId;
    boolean allPresent = true;
    for (String key : keys) {
      Value value = index.get(key);
      if (value != null) {
        shaped.presence.add(true);
        shaped.values.add(ProtocolHelpers.cloneValue(value));
      } else {
        shaped.presence.add(false);
        allPresent = false;
      }
    }
    shaped.hasPresence = !allPresent;
    Message out = new Message();
    out.kind = MessageKind.SHAPED_OBJECT;
    out.shapedObject = shaped;
    return out;
  }

  private record TryVectorResult(TypedVector vector, boolean ok) {}

  private TryVectorResult tryMakeTypedVector(List<Value> values) {
    if (values.size() < 4) {
      return new TryVectorResult(new TypedVector(), false);
    }
    boolean allBool = true;
    boolean allI64 = true;
    boolean allU64 = true;
    boolean allF64 = true;
    boolean allString = true;
    for (Value value : values) {
      allBool &= value.kind == ValueKind.BOOL;
      allI64 &= value.kind == ValueKind.I64;
      allU64 &= value.kind == ValueKind.U64;
      allF64 &= value.kind == ValueKind.F64;
      allString &= value.kind == ValueKind.STRING;
    }
    if (!(allBool || allI64 || allU64 || allF64 || allString)) {
      return new TryVectorResult(new TypedVector(), false);
    }
    TypedVectorData data = new TypedVectorData();
    TypedVector vector = new TypedVector();
    if (allBool) {
      data.kind = ElementType.BOOL;
      for (Value value : values) {
        data.bools.add(value.bool);
      }
      vector.elementType = ElementType.BOOL;
      vector.codec = VectorCodec.DIRECT_BITPACK;
      vector.data = data;
      return new TryVectorResult(vector, true);
    }
    if (allI64) {
      data.kind = ElementType.I64;
      for (Value value : values) {
        data.i64s.add(value.i64);
      }
      vector.elementType = ElementType.I64;
      vector.codec = ProtocolHelpers.selectIntegerCodec(data.i64s);
      vector.data = data;
      return new TryVectorResult(vector, true);
    }
    if (allU64) {
      data.kind = ElementType.U64;
      for (Value value : values) {
        data.u64s.add(value.u64);
      }
      vector.elementType = ElementType.U64;
      vector.codec = ProtocolHelpers.selectU64Codec(data.u64s);
      vector.data = data;
      return new TryVectorResult(vector, true);
    }
    if (allF64) {
      data.kind = ElementType.F64;
      for (Value value : values) {
        data.f64s.add(value.f64);
      }
      vector.elementType = ElementType.F64;
      vector.codec = ProtocolHelpers.selectFloatCodec(data.f64s);
      vector.data = data;
      return new TryVectorResult(vector, true);
    }
    data.kind = ElementType.STRING;
    for (Value value : values) {
      data.strings.add(value.str);
    }
    vector.elementType = ElementType.STRING;
    vector.codec = ProtocolHelpers.selectStringCodec(data.strings);
    vector.data = data;
    return new TryVectorResult(vector, true);
  }

  // NOTE: This class is long by design to mirror protocol.py behavior exactly.
  // The remaining methods are identical to the intended Protocol.java port.

  private void writeMessage(Message message, ByteArrayOutputStream out) {
    out.write(message.kind.ordinal());
    switch (message.kind) {
      case SCALAR -> writeValue(message.scalar, out);
      case ARRAY -> {
        Wire.encodeVaruint(message.array.size(), out);
        for (Value value : message.array) writeValue(value, out);
      }
      case MAP -> {
        Wire.encodeVaruint(message.map.size(), out);
        for (MessageMapEntry entry : message.map) {
          writeKeyRef(entry.key, out);
          writeValueWithField(
              entry.value, ProtocolHelpers.keyRefFieldIdentity(entry.key, state), out);
        }
      }
      case SHAPED_OBJECT -> writeShapedObject(message.shapedObject, out);
      case SCHEMA_OBJECT -> writeSchemaObject(message.schemaObject, out);
      case TYPED_VECTOR -> writeTypedVector(message.typedVector, out);
      case ROW_BATCH -> writeRowBatch(message.rowBatch, out);
      case COLUMN_BATCH -> writeColumnBatch(message.columnBatch, out);
      case CONTROL -> writeControl(message.control, out);
      case EXT -> {
        Wire.encodeVaruint(message.ext.extType, out);
        Wire.encodeBytes(message.ext.payload, out);
      }
      case STATE_PATCH -> writeStatePatch(message.statePatch, out);
      case TEMPLATE_BATCH -> writeTemplateBatch(message.templateBatch, out);
      case CONTROL_STREAM -> {
        out.write(message.controlStream.codec.ordinal());
        writeControlStreamPayload(message.controlStream.codec, message.controlStream.payload, out);
      }
      case BASE_SNAPSHOT -> {
        Wire.encodeVaruint(message.baseSnapshot.baseId, out);
        Wire.encodeVaruint(message.baseSnapshot.schemaOrShapeRef, out);
        writeMessage(message.baseSnapshot.payload, out);
        ProtocolHelpers.registerBaseSnapshot(
            state, message.baseSnapshot.baseId, message.baseSnapshot.payload);
      }
    }
  }

  private Message readMessage(Wire.Reader reader) {
    Message message = new Message();
    message.kind = parseMessageKind(Byte.toUnsignedInt(reader.readU8()));
    switch (message.kind) {
      case SCALAR -> message.scalar = readValue(reader);
      case ARRAY -> {
        long n = reader.readVaruint();
        for (long i = 0; i < n; i++) message.array.add(readValue(reader));
      }
      case MAP -> {
        long n = reader.readVaruint();
        for (long i = 0; i < n; i++) {
          KeyRef keyRef = readKeyRef(reader);
          Value value =
              readValueWithField(reader, ProtocolHelpers.keyRefFieldIdentity(keyRef, state));
          message.map.add(new MessageMapEntry(keyRef, value));
        }
        List<String> keys = new ArrayList<>();
        for (MessageMapEntry entry : message.map)
          keys.add(ProtocolHelpers.keyRefString(entry.key, state));
        observeDecodeShapeCandidate(keys);
      }
      case SHAPED_OBJECT -> message.shapedObject = readShapedObject(reader);
      case SCHEMA_OBJECT -> message.schemaObject = readSchemaObject(reader);
      case TYPED_VECTOR -> message.typedVector = readTypedVector(reader, null, null);
      case ROW_BATCH -> message.rowBatch = readRowBatch(reader);
      case COLUMN_BATCH -> message.columnBatch = readColumnBatch(reader);
      case CONTROL -> message.control = readControl(reader);
      case EXT -> {
        ExtMessage ext = new ExtMessage();
        ext.extType = reader.readVaruint();
        ext.payload = reader.readBytes();
        message.ext = ext;
      }
      case STATE_PATCH -> message.statePatch = readStatePatch(reader);
      case TEMPLATE_BATCH -> message.templateBatch = readTemplateBatch(reader);
      case CONTROL_STREAM -> {
        ControlStreamMessage controlStream = new ControlStreamMessage();
        controlStream.codec = parseControlStreamCodec(Byte.toUnsignedInt(reader.readU8()));
        controlStream.payload = readControlStreamPayload(controlStream.codec, reader);
        message.controlStream = controlStream;
      }
      case BASE_SNAPSHOT -> {
        BaseSnapshotMessage base = new BaseSnapshotMessage();
        base.baseId = reader.readVaruint();
        base.schemaOrShapeRef = reader.readVaruint();
        base.payload = readMessage(reader);
        ProtocolHelpers.registerBaseSnapshot(state, base.baseId, base.payload);
        message.baseSnapshot = base;
      }
    }
    return message;
  }

  private void writeValue(Value value, ByteArrayOutputStream out) {
    writeValueWithField(value, null, out);
  }

  private void writeValueWithField(Value value, String fieldIdentity, ByteArrayOutputStream out) {
    switch (value.kind) {
      case NULL -> out.write(Protocol.TAG_NULL);
      case BOOL -> out.write(value.bool ? Protocol.TAG_BOOL_TRUE : Protocol.TAG_BOOL_FALSE);
      case I64 -> {
        out.write(Protocol.TAG_I64);
        appendList(out, smallestU64Bytes(Wire.encodeZigzag(value.i64)));
      }
      case U64 -> {
        out.write(Protocol.TAG_U64);
        appendList(out, smallestU64Bytes(value.u64));
      }
      case F64 -> {
        out.write(Protocol.TAG_F64);
        Wire.appendF64LE(out, value.f64);
      }
      case STRING -> {
        out.write(Protocol.TAG_STRING);
        if (fieldIdentity != null) {
          List<String> enumValues = state.fieldEnums.get(fieldIdentity);
          if (enumValues != null) {
            for (int i = 0; i < enumValues.size(); i++) {
              if (enumValues.get(i).equals(value.str)) {
                out.write(StringMode.INLINE_ENUM.ordinal());
                Wire.encodeVaruint(i, out);
                return;
              }
            }
          }
        }
        if (value.str.isEmpty()) {
          out.write(StringMode.EMPTY.ordinal());
          return;
        }
        Long refId = state.stringTable.getId(value.str);
        if (refId != null) {
          out.write(StringMode.REF.ordinal());
          Wire.encodeVaruint(refId, out);
          return;
        }
        PrefixBase best = bestPrefixBase(value.str);
        if (best.ok && best.prefixLen >= 4 && best.prefixLen < value.str.length()) {
          out.write(StringMode.PREFIX_DELTA.ordinal());
          Wire.encodeVaruint(best.baseId, out);
          Wire.encodeVaruint(best.prefixLen, out);
          Wire.encodeString(value.str.substring(best.prefixLen), out);
          state.stringTable.register(value.str);
          return;
        }
        out.write(StringMode.LITERAL.ordinal());
        Wire.encodeString(value.str, out);
        state.stringTable.register(value.str);
      }
      case BINARY -> {
        out.write(Protocol.TAG_BINARY);
        Wire.encodeBytes(value.bin, out);
      }
      case ARRAY -> {
        out.write(Protocol.TAG_ARRAY);
        Wire.encodeVaruint(value.arr.size(), out);
        for (Value child : value.arr) writeValue(child, out);
      }
      case MAP -> {
        out.write(Protocol.TAG_MAP);
        Wire.encodeVaruint(value.map.size(), out);
        for (MapEntry entry : value.map) {
          writeKeyRef(KeyRef.literal(entry.key), out);
          writeValueWithField(entry.value, entry.key, out);
        }
      }
    }
  }

  private Value readValue(Wire.Reader reader) {
    return readValueWithField(reader, null);
  }

  private Value readValueWithField(Wire.Reader reader, String fieldIdentity) {
    int tag = Byte.toUnsignedInt(reader.readU8());
    return switch (tag) {
      case Protocol.TAG_NULL -> Value.ofNull();
      case Protocol.TAG_BOOL_FALSE -> Value.ofBool(false);
      case Protocol.TAG_BOOL_TRUE -> Value.ofBool(true);
      case Protocol.TAG_I64 ->
          Value.ofI64(Wire.decodeZigzag(ProtocolHelpers.readSmallestU64(reader)));
      case Protocol.TAG_U64 -> Value.ofU64(ProtocolHelpers.readSmallestU64(reader));
      case Protocol.TAG_F64 -> Value.ofF64(Wire.readF64LE(reader));
      case Protocol.TAG_STRING -> readStringValue(reader, fieldIdentity);
      case Protocol.TAG_BINARY -> Value.ofBinary(reader.readBytes());
      case Protocol.TAG_ARRAY -> {
        long n = reader.readVaruint();
        List<Value> values = new ArrayList<>();
        for (long i = 0; i < n; i++) values.add(readValue(reader));
        yield Value.ofArray(values);
      }
      case Protocol.TAG_MAP -> {
        long n = reader.readVaruint();
        List<MapEntry> entries = new ArrayList<>();
        for (long i = 0; i < n; i++) {
          KeyRef keyRef = readKeyRef(reader);
          entries.add(new MapEntry(keyRef.literal, readValueWithField(reader, keyRef.literal)));
        }
        yield Value.ofMap(entries);
      }
      default -> throw Errors.invalidTag((byte) tag);
    };
  }

  private Value readStringValue(Wire.Reader reader, String fieldIdentity) {
    StringMode mode = parseStringMode(Byte.toUnsignedInt(reader.readU8()));
    return switch (mode) {
      case EMPTY -> Value.ofString("");
      case LITERAL -> {
        String value = reader.readString();
        state.stringTable.register(value);
        yield Value.ofString(value);
      }
      case REF -> {
        long id = reader.readVaruint();
        String value = state.stringTable.getValue(id);
        if (value == null) throw referenceError("string_id", id);
        yield Value.ofString(value);
      }
      case PREFIX_DELTA -> {
        long baseId = reader.readVaruint();
        long prefixLen = reader.readVaruint();
        String suffix = reader.readString();
        String base = state.stringTable.getValue(baseId);
        if (base == null) throw referenceError("string_id", baseId);
        if (prefixLen > base.length()) throw Errors.invalidData("prefix delta length");
        String value = base.substring(0, (int) prefixLen) + suffix;
        state.stringTable.register(value);
        yield Value.ofString(value);
      }
      case INLINE_ENUM -> {
        if (fieldIdentity == null) throw Errors.invalidData("inline enum missing field identity");
        List<String> enumValues = state.fieldEnums.get(fieldIdentity);
        if (enumValues == null) throw Errors.invalidData("inline enum unknown field");
        long code = reader.readVaruint();
        if (code >= enumValues.size()) throw Errors.invalidData("inline enum code");
        yield Value.ofString(enumValues.get((int) code));
      }
    };
  }

  private void writeKeyRef(KeyRef keyRef, ByteArrayOutputStream out) {
    if (keyRef.isId) {
      out.write(1);
      Wire.encodeVaruint(keyRef.id, out);
      return;
    }
    out.write(0);
    Wire.encodeString(keyRef.literal, out);
    state.keyTable.register(keyRef.literal);
  }

  private KeyRef readKeyRef(Wire.Reader reader) {
    int mode = Byte.toUnsignedInt(reader.readU8());
    if (mode == 1) {
      long refId = reader.readVaruint();
      String key = state.keyTable.getValue(refId);
      if (key == null) throw referenceError("key_id", refId);
      return KeyRef.literal(key);
    }
    if (mode != 0) throw Errors.invalidData("key ref mode");
    String key = reader.readString();
    state.keyTable.register(key);
    return KeyRef.literal(key);
  }

  private record PresenceResult(List<Boolean> presence, boolean hasPresence) {}

  private void writePresence(
      List<Boolean> presence, boolean hasPresence, ByteArrayOutputStream out) {
    if (!hasPresence) {
      out.write(0);
      return;
    }
    out.write(1);
    Wire.encodeBitmap(toPrimitiveBooleanArray(presence), out);
  }

  private PresenceResult readPresence(Wire.Reader reader) {
    int flag = Byte.toUnsignedInt(reader.readU8());
    if (flag == 0) {
      return new PresenceResult(new ArrayList<>(), false);
    }
    if (flag != 1) {
      throw Errors.invalidData("presence flag");
    }
    return new PresenceResult(toBoxedBooleanList(reader.readBitmap()), true);
  }

  private void writeTypedVector(TypedVector vector, ByteArrayOutputStream out) {
    out.write(vector.elementType.ordinal());
    Wire.encodeVaruint(ProtocolHelpers.typedVectorLen(vector.data), out);
    out.write(vector.codec.ordinal());
    switch (vector.elementType) {
      case BOOL -> Wire.encodeBitmap(toPrimitiveBooleanArray(vector.data.bools), out);
      case I64 -> Codec.encodeI64Vector(vector.data.i64s, vector.codec, toByteList(out));
      case U64 -> Codec.encodeU64Vector(vector.data.u64s, vector.codec, toByteList(out));
      case F64 -> Codec.encodeF64Vector(vector.data.f64s, vector.codec, toByteList(out));
      case STRING -> writeStringVector(vector.data.strings, vector.codec, out);
      case BINARY -> {
        Wire.encodeVaruint(vector.data.binary.size(), out);
        for (byte[] value : vector.data.binary) {
          Wire.encodeBytes(value, out);
        }
      }
      case VALUE -> {
        Wire.encodeVaruint(vector.data.values.size(), out);
        for (Value value : vector.data.values) {
          writeValue(value, out);
        }
      }
      default -> throw Errors.invalidData("unsupported element type");
    }
  }

  private void writeStringVector(
      List<String> values, VectorCodec codec, ByteArrayOutputStream out) {
    switch (codec) {
      case DICTIONARY -> {
        Map<String, Long> dictionary = new HashMap<>();
        List<String> unique = new ArrayList<>();
        List<Long> refs = new ArrayList<>();
        for (String value : values) {
          Long ref = dictionary.get(value);
          if (ref != null) {
            refs.add(ref);
            continue;
          }
          long newRef = unique.size();
          dictionary.put(value, newRef);
          unique.add(value);
          refs.add(newRef);
        }
        Wire.encodeVaruint(unique.size(), out);
        for (String value : unique) {
          Wire.encodeString(value, out);
        }
        Codec.encodeU64Vector(refs, VectorCodec.DIRECT_BITPACK, toByteList(out));
      }
      case STRING_REF -> {
        Wire.encodeVaruint(values.size(), out);
        for (String value : values) {
          Long stringId = state.stringTable.getId(value);
          if (stringId == null) {
            stringId = state.stringTable.register(value);
          }
          Wire.encodeVaruint(stringId, out);
        }
      }
      case PREFIX_DELTA -> {
        Wire.encodeVaruint(values.size(), out);
        String prev = "";
        for (String value : values) {
          int prefix =
              ProtocolHelpers.commonPrefixLen(
                  prev.getBytes(StandardCharsets.UTF_8), value.getBytes(StandardCharsets.UTF_8));
          Wire.encodeVaruint(prefix, out);
          Wire.encodeString(value.substring(prefix), out);
          prev = value;
        }
      }
      default -> {
        Wire.encodeVaruint(values.size(), out);
        for (String value : values) {
          Wire.encodeString(value, out);
        }
      }
    }
  }

  private List<String> readStringVector(Wire.Reader reader, VectorCodec codec) {
    return switch (codec) {
      case DICTIONARY -> {
        long dictSize = reader.readVaruint();
        List<String> dictionary = new ArrayList<>();
        for (long i = 0; i < dictSize; i++) {
          dictionary.add(reader.readString());
        }
        List<Long> refs = Codec.decodeU64Vector(reader, VectorCodec.DIRECT_BITPACK);
        List<String> out = new ArrayList<>();
        for (long ref : refs) {
          if (ref < 0 || ref >= dictionary.size()) {
            throw Errors.invalidData("dictionary reference");
          }
          out.add(dictionary.get((int) ref));
        }
        yield out;
      }
      case STRING_REF -> {
        long length = reader.readVaruint();
        List<String> out = new ArrayList<>();
        for (long i = 0; i < length; i++) {
          long stringId = reader.readVaruint();
          String value = state.stringTable.getValue(stringId);
          if (value == null) {
            throw referenceError("string_id", stringId);
          }
          out.add(value);
        }
        yield out;
      }
      case PREFIX_DELTA -> {
        long length = reader.readVaruint();
        List<String> out = new ArrayList<>();
        String prev = "";
        for (long i = 0; i < length; i++) {
          long prefixLen = reader.readVaruint();
          String suffix = reader.readString();
          if (prefixLen > prev.length()) {
            throw Errors.invalidData("prefix delta in string vector");
          }
          String value = prev.substring(0, (int) prefixLen) + suffix;
          out.add(value);
          prev = value;
        }
        yield out;
      }
      default -> {
        long length = reader.readVaruint();
        List<String> out = new ArrayList<>();
        for (long i = 0; i < length; i++) {
          out.add(reader.readString());
        }
        yield out;
      }
    };
  }

  private void writeSchemaFields(
      Schema schema,
      List<Boolean> presence,
      boolean hasPresence,
      List<Value> fields,
      ByteArrayOutputStream out) {
    List<Integer> indices =
        ProtocolHelpers.schemaPresentFieldIndices(schema, presence, hasPresence);
    for (int i : indices) {
      if (i >= fields.size()) {
        throw Errors.invalidData("schema fields length mismatch");
      }
      writeSchemaFieldValue(schema.fields.get(i), fields.get(i), out);
    }
  }

  private List<Value> readSchemaFields(
      Schema schema, List<Boolean> presence, boolean hasPresence, int n, Wire.Reader reader) {
    List<Integer> indices =
        ProtocolHelpers.schemaPresentFieldIndices(schema, presence, hasPresence);
    if (indices.size() != n) {
      throw Errors.invalidData("schema fields length");
    }
    List<Value> out = new ArrayList<>();
    for (int i : indices) {
      out.add(readSchemaFieldValue(schema.fields.get(i), reader));
    }
    return out;
  }

  private void writeSchemaFieldValue(SchemaField field, Value value, ByteArrayOutputStream out) {
    String logicalType = ProtocolHelpers.normalizedLogicalType(field.logicalType);
    if ("bool".equals(logicalType) && value.kind != ValueKind.BOOL) {
      throw Errors.invalidData("schema bool field type mismatch");
    }
    if (("i64".equals(logicalType) || "int64".equals(logicalType) || "int".equals(logicalType))
        && value.kind != ValueKind.I64) {
      throw Errors.invalidData("schema i64 field type mismatch");
    }
    if (("u64".equals(logicalType) || "uint64".equals(logicalType) || "uint".equals(logicalType))
        && value.kind != ValueKind.U64) {
      throw Errors.invalidData("schema u64 field type mismatch");
    }
    if (("f64".equals(logicalType) || "float64".equals(logicalType) || "float".equals(logicalType))
        && value.kind != ValueKind.F64) {
      throw Errors.invalidData("schema f64 field type mismatch");
    }
    if ("string".equals(logicalType)) {
      if (value.kind != ValueKind.STRING) {
        throw Errors.invalidData("schema string field type mismatch");
      }
      writeValueWithField(value, field.name, out);
      return;
    }
    writeValue(value, out);
  }

  private Value readSchemaFieldValue(SchemaField field, Wire.Reader reader) {
    if ("string".equals(ProtocolHelpers.normalizedLogicalType(field.logicalType))) {
      return readValueWithField(reader, field.name);
    }
    return readValue(reader);
  }

  private void writeShapedObject(ShapedObjectMessage shaped, ByteArrayOutputStream out) {
    Wire.encodeVaruint(shaped.shapeId, out);
    writePresence(shaped.presence, shaped.hasPresence, out);
    Wire.encodeVaruint(shaped.values.size(), out);
    List<String> keys = ProtocolHelpers.shapeGetKeys(state.shapeTable, shaped.shapeId);
    if (keys == null) {
      for (Value value : shaped.values) writeValue(value, out);
      return;
    }
    List<Boolean> presence = shaped.hasPresence ? shaped.presence : new ArrayList<>();
    if (!shaped.hasPresence) {
      for (int i = 0; i < keys.size(); i++) presence.add(true);
    }
    int valueIdx = 0;
    for (int i = 0; i < keys.size(); i++) {
      if (i < presence.size() && !presence.get(i)) continue;
      if (valueIdx >= shaped.values.size()) break;
      writeValueWithField(shaped.values.get(valueIdx), keys.get(i), out);
      valueIdx++;
    }
    while (valueIdx < shaped.values.size()) {
      writeValue(shaped.values.get(valueIdx), out);
      valueIdx++;
    }
  }

  private ShapedObjectMessage readShapedObject(Wire.Reader reader) {
    ShapedObjectMessage shaped = new ShapedObjectMessage();
    shaped.shapeId = reader.readVaruint();
    PresenceResult presence = readPresence(reader);
    shaped.presence = presence.presence;
    shaped.hasPresence = presence.hasPresence;
    long n = reader.readVaruint();
    List<String> keys = ProtocolHelpers.shapeGetKeys(state.shapeTable, shaped.shapeId);
    if (keys == null) {
      for (long i = 0; i < n; i++) shaped.values.add(readValue(reader));
      return shaped;
    }
    List<Boolean> pres = shaped.hasPresence ? shaped.presence : new ArrayList<>();
    if (!shaped.hasPresence) {
      for (int i = 0; i < keys.size(); i++) pres.add(true);
    }
    long count = 0;
    for (int i = 0; i < keys.size(); i++) {
      if (i < pres.size() && !pres.get(i)) continue;
      if (count >= n) break;
      shaped.values.add(readValueWithField(reader, keys.get(i)));
      count++;
    }
    while (count < n) {
      shaped.values.add(readValue(reader));
      count++;
    }
    return shaped;
  }

  private void writeSchemaObject(SchemaObjectMessage schemaObject, ByteArrayOutputStream out) {
    if (schemaObject.schemaId != null) {
      out.write(1);
      Wire.encodeVaruint(schemaObject.schemaId, out);
    } else {
      out.write(0);
    }
    writePresence(schemaObject.presence, schemaObject.hasPresence, out);
    Wire.encodeVaruint(schemaObject.fields.size(), out);
    Schema schema = null;
    if (schemaObject.schemaId != null) schema = state.schemas.get(schemaObject.schemaId);
    else if (state.lastSchemaId != null) schema = state.schemas.get(state.lastSchemaId);
    if (schema != null) {
      out.write(1);
      writeSchemaFields(
          schema, schemaObject.presence, schemaObject.hasPresence, schemaObject.fields, out);
      if (schemaObject.schemaId != null) state.lastSchemaId = schemaObject.schemaId;
    } else {
      out.write(0);
      for (Value value : schemaObject.fields) writeValue(value, out);
    }
  }

  private SchemaObjectMessage readSchemaObject(Wire.Reader reader) {
    int hasSchema = Byte.toUnsignedInt(reader.readU8());
    Long schemaId = hasSchema == 1 ? reader.readVaruint() : null;
    PresenceResult presence = readPresence(reader);
    long n = reader.readVaruint();
    int mode = Byte.toUnsignedInt(reader.readU8());
    List<Value> fields = new ArrayList<>();
    if (mode == 1) {
      long effectiveId;
      if (schemaId != null) effectiveId = schemaId;
      else if (state.lastSchemaId != null) effectiveId = state.lastSchemaId;
      else throw Errors.invalidData("schema object requires schema id in context");
      Schema schema = state.schemas.get(effectiveId);
      if (schema == null) throw referenceError("schema_id", effectiveId);
      fields = readSchemaFields(schema, presence.presence, presence.hasPresence, (int) n, reader);
      state.lastSchemaId = effectiveId;
    } else {
      for (long i = 0; i < n; i++) fields.add(readValue(reader));
      if (schemaId != null) state.lastSchemaId = schemaId;
    }
    SchemaObjectMessage schemaObject = new SchemaObjectMessage();
    schemaObject.schemaId = schemaId;
    schemaObject.presence = presence.presence;
    schemaObject.hasPresence = presence.hasPresence;
    schemaObject.fields = fields;
    return schemaObject;
  }

  private void writeRowBatch(RowBatchMessage rowBatch, ByteArrayOutputStream out) {
    Wire.encodeVaruint(rowBatch.rows.size(), out);
    for (List<Value> row : rowBatch.rows) {
      Wire.encodeVaruint(row.size(), out);
      for (Value value : row) writeValue(value, out);
    }
  }

  private RowBatchMessage readRowBatch(Wire.Reader reader) {
    RowBatchMessage rowBatch = new RowBatchMessage();
    long rowCount = reader.readVaruint();
    for (long i = 0; i < rowCount; i++) {
      long fieldCount = reader.readVaruint();
      List<Value> row = new ArrayList<>();
      for (long j = 0; j < fieldCount; j++) row.add(readValue(reader));
      rowBatch.rows.add(row);
    }
    return rowBatch;
  }

  private void writeColumnBatch(ColumnBatchMessage columnBatch, ByteArrayOutputStream out) {
    Wire.encodeVaruint(columnBatch.count, out);
    Wire.encodeVaruint(columnBatch.columns.size(), out);
    for (Column column : columnBatch.columns) writeColumn(column, out);
  }

  private ColumnBatchMessage readColumnBatch(Wire.Reader reader) {
    ColumnBatchMessage batch = new ColumnBatchMessage();
    batch.count = reader.readVaruint();
    long colCount = reader.readVaruint();
    for (long i = 0; i < colCount; i++) batch.columns.add(readColumn(reader));
    return batch;
  }

  private void writeStatePatch(StatePatchMessage patch, ByteArrayOutputStream out) {
    writeBaseRef(patch.baseRef, out);
    Wire.encodeVaruint(patch.operations.size(), out);
    for (PatchOperation operation : patch.operations) {
      Wire.encodeVaruint(operation.fieldId, out);
      out.write(operation.opcode.ordinal());
      if (operation.value != null) {
        out.write(1);
        writeValue(operation.value, out);
      } else {
        out.write(0);
      }
    }
    Wire.encodeVaruint(patch.literals.size(), out);
    for (Value literal : patch.literals) writeValue(literal, out);
  }

  private StatePatchMessage readStatePatch(Wire.Reader reader) {
    StatePatchMessage patch = new StatePatchMessage();
    patch.baseRef = readBaseRef(reader);
    long n = reader.readVaruint();
    for (long i = 0; i < n; i++) {
      PatchOperation operation = new PatchOperation();
      operation.fieldId = reader.readVaruint();
      operation.opcode = parsePatchOpcode(Byte.toUnsignedInt(reader.readU8()));
      if (Byte.toUnsignedInt(reader.readU8()) == 1) operation.value = readValue(reader);
      patch.operations.add(operation);
    }
    long litN = reader.readVaruint();
    for (long i = 0; i < litN; i++) patch.literals.add(readValue(reader));
    return patch;
  }

  private void writeTemplateBatch(TemplateBatchMessage templateBatch, ByteArrayOutputStream out) {
    Wire.encodeVaruint(templateBatch.templateId, out);
    Wire.encodeVaruint(templateBatch.count, out);
    Wire.encodeBitmap(toPrimitiveBooleanArray(templateBatch.changedColumnMask), out);
    Wire.encodeVaruint(templateBatch.columns.size(), out);
    for (Column column : templateBatch.columns) writeColumn(column, out);
  }

  private TemplateBatchMessage readTemplateBatch(Wire.Reader reader) {
    long templateId = reader.readVaruint();
    long count = reader.readVaruint();
    List<Boolean> mask = toBoxedBooleanList(reader.readBitmap());
    long colN = reader.readVaruint();
    List<Column> changed = new ArrayList<>();
    for (long i = 0; i < colN; i++) changed.add(readColumn(reader));
    List<Column> fullColumns = changed;
    List<Column> previous = state.templateColumns.get(templateId);
    if (previous != null) {
      fullColumns = ProtocolHelpers.mergeTemplateColumns(previous, mask, changed);
    } else {
      for (boolean bit : toPrimitiveBooleanArray(mask))
        if (!bit) throw referenceError("template_id", templateId);
    }
    state.templateColumns.put(templateId, fullColumns);
    state.templates.put(
        templateId, ProtocolHelpers.templateDescriptorFromColumns(templateId, fullColumns));
    if (count >= 16) {
      Message prev = new Message();
      prev.kind = MessageKind.COLUMN_BATCH;
      ColumnBatchMessage columnBatch = new ColumnBatchMessage();
      columnBatch.count = count;
      for (Column column : fullColumns)
        columnBatch.columns.add(ProtocolHelpers.cloneColumn(column));
      prev.columnBatch = columnBatch;
      state.previousMessage = prev;
    }
    TemplateBatchMessage templateBatch = new TemplateBatchMessage();
    templateBatch.templateId = templateId;
    templateBatch.count = count;
    templateBatch.changedColumnMask = mask;
    templateBatch.columns = changed;
    return templateBatch;
  }

  private void writeColumn(Column column, ByteArrayOutputStream out) {
    Wire.encodeVaruint(column.fieldId, out);
    out.write(column.nullStrategy.ordinal());
    if (column.nullStrategy == NullStrategy.PRESENCE_BITMAP
        || column.nullStrategy == NullStrategy.INVERTED_PRESENCE_BITMAP) {
      if (!column.hasPresence) throw Errors.invalidData("missing column presence bitmap");
      Wire.encodeBitmap(toPrimitiveBooleanArray(column.presence), out);
    }
    out.write(column.codec.ordinal());
    if (column.dictionaryId != null) {
      out.write(1);
      Wire.encodeVaruint(column.dictionaryId, out);
      byte[] payload = state.dictionaries.get(column.dictionaryId);
      DictionaryProfile profile = state.dictionaryProfiles.get(column.dictionaryId);
      if (payload != null && profile != null) {
        out.write(1);
        Wire.encodeVaruint(profile.version, out);
        Wire.encodeVaruint(profile.hash, out);
        Wire.encodeVaruint(profile.expiresAt, out);
        out.write(profile.fallback.ordinal());
        Wire.encodeBytes(payload, out);
      } else out.write(0);
    } else out.write(0);

    byte[] trainedBlock = null;
    if (column.dictionaryId != null
        && column.values.kind == ElementType.STRING
        && (column.codec == VectorCodec.DICTIONARY || column.codec == VectorCodec.STRING_REF)) {
      byte[] payload = state.dictionaries.get(column.dictionaryId);
      if (payload != null) {
        try {
          List<String> dictionary = Dictionary.decodeTrainedDictionaryPayload(payload);
          Dictionary.EncodedDictionaryBlock block =
              Dictionary.encodeTrainedDictionaryBlock(column.values.strings, dictionary);
          if (block.ok() && block.block() != null) trainedBlock = block.block();
        } catch (Throwable ignore) {
        }
      }
    }
    if (trainedBlock != null) {
      out.write(1);
      Wire.encodeBytes(trainedBlock, out);
      return;
    }
    out.write(0);
    TypedVector vector = new TypedVector();
    vector.elementType = column.values.kind;
    vector.codec = column.codec;
    vector.data = ProtocolHelpers.cloneTypedVectorData(column.values);
    writeTypedVector(vector, out);
  }

  private Column readColumn(Wire.Reader reader) {
    Column column = new Column();
    column.fieldId = reader.readVaruint();
    column.nullStrategy = parseNullStrategy(Byte.toUnsignedInt(reader.readU8()));
    if (column.nullStrategy == NullStrategy.PRESENCE_BITMAP
        || column.nullStrategy == NullStrategy.INVERTED_PRESENCE_BITMAP) {
      column.presence = toBoxedBooleanList(reader.readBitmap());
      column.hasPresence = true;
    }
    column.codec = parseVectorCodec(Byte.toUnsignedInt(reader.readU8()));
    int hasDict = Byte.toUnsignedInt(reader.readU8());
    if (hasDict == 1) {
      long dictId = reader.readVaruint();
      int hasProfile = Byte.toUnsignedInt(reader.readU8());
      if (hasProfile == 0) {
        if (!state.dictionaries.containsKey(dictId)) throw referenceError("dict_id", dictId);
      } else if (hasProfile == 1) {
        long version = reader.readVaruint();
        long hash = reader.readVaruint();
        long expiresAt = reader.readVaruint();
        DictionaryFallback fallback = parseDictionaryFallback(Byte.toUnsignedInt(reader.readU8()));
        byte[] payload = reader.readBytes();
        if (Dictionary.dictionaryPayloadHash(payload) != hash) {
          throw Errors.invalidData("dictionary profile hash mismatch");
        }
        state.dictionaries.put(dictId, payload);
        state.dictionaryProfiles.put(
            dictId, new DictionaryProfile(version, hash, expiresAt, fallback));
      } else throw Errors.invalidData("dictionary profile flag");
      column.dictionaryId = dictId;
    } else if (hasDict != 0) throw Errors.invalidData("dictionary flag");
    int payloadMode = Byte.toUnsignedInt(reader.readU8());
    if (payloadMode == 0) {
      column.values = readTypedVector(reader, null, column.codec).data;
    } else if (payloadMode == 1) {
      if (column.dictionaryId == null)
        throw Errors.invalidData("trained dictionary block requires dict_id");
      if (column.codec != VectorCodec.DICTIONARY && column.codec != VectorCodec.STRING_REF) {
        throw Errors.invalidData("trained dictionary block requires string dictionary codec");
      }
      byte[] dictionaryPayload = state.dictionaries.get(column.dictionaryId);
      if (dictionaryPayload == null) throw referenceError("dict_id", column.dictionaryId);
      List<String> dictionary = Dictionary.decodeTrainedDictionaryPayload(dictionaryPayload);
      List<String> strings =
          Dictionary.decodeTrainedDictionaryBlock(reader.readBytes(), dictionary);
      TypedVectorData data = new TypedVectorData();
      data.kind = ElementType.STRING;
      data.strings = strings;
      column.values = data;
    } else throw Errors.invalidData("column payload mode");
    return column;
  }

  private void writeControl(ControlMessage control, ByteArrayOutputStream out) {
    out.write(control.opcode.ordinal());
    switch (control.opcode) {
      case REGISTER_KEYS -> {
        Wire.encodeVaruint(control.registerKeys.size(), out);
        for (String key : control.registerKeys) {
          Wire.encodeString(key, out);
          state.keyTable.register(key);
        }
      }
      case REGISTER_SHAPE -> {
        if (control.registerShape == null)
          throw Errors.invalidData("register shape payload missing");
        Wire.encodeVaruint(control.registerShape.shapeId, out);
        Wire.encodeVaruint(control.registerShape.keys.size(), out);
        List<String> keys = new ArrayList<>();
        for (KeyRef key : control.registerShape.keys) {
          writeKeyRef(key, out);
          keys.add(key.literal);
        }
        ProtocolHelpers.shapeRegisterWithId(state.shapeTable, control.registerShape.shapeId, keys);
      }
      case REGISTER_STRINGS -> {
        Wire.encodeVaruint(control.registerStrings.size(), out);
        for (String value : control.registerStrings) {
          Wire.encodeString(value, out);
          state.stringTable.register(value);
        }
      }
      case PROMOTE_STRING_FIELD_TO_ENUM -> {
        if (control.promoteStringFieldToEnum == null) {
          throw Errors.invalidData("promote enum payload missing");
        }
        Wire.encodeString(control.promoteStringFieldToEnum.fieldIdentity, out);
        Wire.encodeVaruint(control.promoteStringFieldToEnum.values.size(), out);
        for (String value : control.promoteStringFieldToEnum.values) Wire.encodeString(value, out);
        state.fieldEnums.put(
            control.promoteStringFieldToEnum.fieldIdentity,
            new ArrayList<>(control.promoteStringFieldToEnum.values));
      }
      case RESET_TABLES -> ProtocolHelpers.resetTables(state);
      case RESET_STATE -> ProtocolHelpers.resetState(state);
    }
  }

  private ControlMessage readControl(Wire.Reader reader) {
    ControlMessage control = new ControlMessage();
    control.opcode = parseControlOpcode(Byte.toUnsignedInt(reader.readU8()));
    switch (control.opcode) {
      case REGISTER_KEYS -> {
        long n = reader.readVaruint();
        for (long i = 0; i < n; i++) {
          String value = reader.readString();
          control.registerKeys.add(value);
          state.keyTable.register(value);
        }
      }
      case REGISTER_SHAPE -> {
        RegisterShapeControl registerShape = new RegisterShapeControl();
        registerShape.shapeId = reader.readVaruint();
        long n = reader.readVaruint();
        List<String> keyNames = new ArrayList<>();
        for (long i = 0; i < n; i++) {
          KeyRef key = readKeyRef(reader);
          registerShape.keys.add(key);
          keyNames.add(key.literal);
        }
        ProtocolHelpers.shapeRegisterWithId(state.shapeTable, registerShape.shapeId, keyNames);
        control.registerShape = registerShape;
      }
      case REGISTER_STRINGS -> {
        long n = reader.readVaruint();
        for (long i = 0; i < n; i++) {
          String value = reader.readString();
          control.registerStrings.add(value);
          state.stringTable.register(value);
        }
      }
      case PROMOTE_STRING_FIELD_TO_ENUM -> {
        PromoteEnumControl promote = new PromoteEnumControl();
        promote.fieldIdentity = reader.readString();
        long n = reader.readVaruint();
        for (long i = 0; i < n; i++) promote.values.add(reader.readString());
        state.fieldEnums.put(promote.fieldIdentity, new ArrayList<>(promote.values));
        control.promoteStringFieldToEnum = promote;
      }
      case RESET_TABLES -> {
        control.resetTables = true;
        ProtocolHelpers.resetTables(state);
      }
      case RESET_STATE -> {
        control.resetState = true;
        ProtocolHelpers.resetState(state);
      }
    }
    return control;
  }

  private void writeBaseRef(BaseRef baseRef, ByteArrayOutputStream out) {
    if (baseRef.previous) out.write(0);
    else {
      out.write(1);
      Wire.encodeVaruint(baseRef.baseId, out);
    }
  }

  private BaseRef readBaseRef(Wire.Reader reader) {
    int mode = Byte.toUnsignedInt(reader.readU8());
    if (mode == 0) return BaseRef.previous();
    if (mode == 1) return BaseRef.id(reader.readVaruint());
    throw Errors.invalidData("base ref");
  }

  private void writeControlStreamPayload(
      ControlStreamCodec codec, byte[] payload, ByteArrayOutputStream out) {
    byte[] encoded =
        switch (codec) {
          case PLAIN -> payload.clone();
          case RLE -> ProtocolHelpers.rleEncodeBytes(payload);
          case BITPACK -> ProtocolHelpers.controlBitpackEncodeBytes(payload);
          case HUFFMAN -> ProtocolHelpers.controlHuffmanEncodeBytes(payload);
          case FSE -> ProtocolHelpers.controlFseEncodeBytes(payload);
        };
    Wire.encodeBytes(encoded, out);
  }

  private byte[] readControlStreamPayload(ControlStreamCodec codec, Wire.Reader reader) {
    byte[] encoded = reader.readBytes();
    return switch (codec) {
      case PLAIN -> encoded;
      case RLE -> ProtocolHelpers.rleDecodeBytes(encoded);
      case BITPACK -> ProtocolHelpers.controlBitpackDecodeBytes(encoded);
      case HUFFMAN -> ProtocolHelpers.controlHuffmanDecodeBytes(encoded);
      case FSE -> ProtocolHelpers.controlFseDecodeBytes(encoded);
    };
  }

  private record PrefixBase(long baseId, int prefixLen, boolean ok) {}

  private PrefixBase bestPrefixBase(String value) {
    long bestId = 0;
    int bestLen = 0;
    for (int i = 0; i < state.stringTable.byId.size(); i++) {
      String candidate = state.stringTable.byId.get(i);
      int n =
          ProtocolHelpers.commonPrefixLen(
              value.getBytes(StandardCharsets.UTF_8), candidate.getBytes(StandardCharsets.UTF_8));
      if (n > bestLen) {
        bestLen = n;
        bestId = i;
      }
    }
    return bestLen == 0 ? new PrefixBase(0, 0, false) : new PrefixBase(bestId, bestLen, true);
  }

  private TypedVector readTypedVector(
      Wire.Reader reader, ElementType forcedElement, VectorCodec expectedCodec) {
    ElementType elementType =
        forcedElement == null
            ? parseElementType(Byte.toUnsignedInt(reader.readU8()))
            : forcedElement;
    long expectedLen = reader.readVaruint();
    VectorCodec codec = parseVectorCodec(Byte.toUnsignedInt(reader.readU8()));
    if (expectedCodec != null && codec != expectedCodec)
      throw Errors.invalidData("column codec mismatch");
    TypedVectorData data = new TypedVectorData();
    data.kind = elementType;
    switch (elementType) {
      case BOOL -> data.bools = toBoxedBooleanList(reader.readBitmap());
      case I64 -> data.i64s = Codec.decodeI64Vector(reader, codec);
      case U64 -> data.u64s = Codec.decodeU64Vector(reader, codec);
      case F64 -> data.f64s = Codec.decodeF64Vector(reader, codec);
      case STRING -> data.strings = readStringVector(reader, codec);
      case BINARY -> {
        long n = reader.readVaruint();
        for (long i = 0; i < n; i++) data.binary.add(reader.readBytes());
      }
      case VALUE -> {
        long n = reader.readVaruint();
        for (long i = 0; i < n; i++) data.values.add(readValue(reader));
      }
    }
    if (ProtocolHelpers.typedVectorLen(data) != expectedLen) {
      throw Errors.invalidData("typed vector length mismatch");
    }
    TypedVector vector = new TypedVector();
    vector.elementType = elementType;
    vector.codec = codec;
    vector.data = data;
    return vector;
  }

  private Message applyStatePatch(
      BaseRef baseRef, List<PatchOperation> operations, List<Value> literals) {
    Message base;
    if (baseRef.previous) {
      if (state.previousMessage == null) throw referenceError("previous", 0);
      base = ProtocolHelpers.cloneMessage(state.previousMessage);
    } else {
      base = ProtocolHelpers.getBaseSnapshot(state, baseRef.baseId);
      if (base == null) throw referenceError("base_id", baseRef.baseId);
    }
    List<Value> fields = ProtocolHelpers.messageFields(base);
    for (PatchOperation operation : operations) {
      int idx = (int) operation.fieldId;
      switch (operation.opcode) {
        case KEEP -> {}
        case REPLACE_SCALAR, REPLACE_VECTOR, INSERT_FIELD, STRING_REF, PREFIX_DELTA -> {
          if (operation.value == null) throw Errors.invalidData("patch operation missing value");
          if (idx < fields.size()) fields.set(idx, ProtocolHelpers.cloneValue(operation.value));
          else if (idx == fields.size()) fields.add(ProtocolHelpers.cloneValue(operation.value));
          else throw Errors.invalidData("patch field index out of range");
        }
        case DELETE_FIELD -> {
          if (idx < 0 || idx >= fields.size())
            throw Errors.invalidData("delete field index out of range");
          fields.remove(idx);
        }
        case APPEND_VECTOR -> {
          if (operation.value == null || idx < 0 || idx >= fields.size()) {
            throw Errors.invalidData("append vector patch invalid");
          }
          Value target = fields.get(idx);
          if (target.kind != ValueKind.ARRAY || operation.value.kind != ValueKind.ARRAY) {
            throw Errors.invalidData("append vector requires arrays");
          }
          for (Value value : operation.value.arr) target.arr.add(ProtocolHelpers.cloneValue(value));
        }
        case TRUNCATE_VECTOR -> {
          if (operation.value == null || idx < 0 || idx >= fields.size()) {
            throw Errors.invalidData("truncate vector patch invalid");
          }
          Value target = fields.get(idx);
          if (target.kind != ValueKind.ARRAY || operation.value.kind != ValueKind.U64) {
            throw Errors.invalidData("truncate vector requires array and u64");
          }
          long n = operation.value.u64;
          if (n > target.arr.size()) throw Errors.invalidData("truncate length");
          target.arr = new ArrayList<>(target.arr.subList(0, (int) n));
        }
      }
    }
    return ProtocolHelpers.rebuildMessageLike(base, fields);
  }

  private void observeDecodeShapeCandidate(List<String> keys) {
    if (ProtocolHelpers.shapeGetId(state.shapeTable, keys) != null) return;
    long observed = ProtocolHelpers.shapeObserve(state.shapeTable, keys);
    if (ProtocolHelpers.shouldRegisterShape(keys, observed))
      ProtocolHelpers.shapeRegister(state.shapeTable, keys);
  }

  long observeEncodeShapeCandidate(List<String> keys) {
    String key = ProtocolHelpers.shapeKey(keys);
    long count = state.encodeShapeObservations.getOrDefault(key, 0L) + 1L;
    state.encodeShapeObservations.put(key, count);
    if (ProtocolHelpers.shouldRegisterShape(keys, count))
      ProtocolHelpers.shapeRegister(state.shapeTable, keys);
    return count;
  }

  private MessageKind parseMessageKind(int value) {
    if (value < 0 || value >= MessageKind.values().length) throw Errors.invalidKind((byte) value);
    return MessageKind.values()[value];
  }

  private PatchOpcode parsePatchOpcode(int value) {
    if (value < 0 || value >= PatchOpcode.values().length) throw Errors.invalidData("patch opcode");
    return PatchOpcode.values()[value];
  }

  private StringMode parseStringMode(int value) {
    if (value < 0 || value >= StringMode.values().length) throw Errors.invalidData("string mode");
    return StringMode.values()[value];
  }

  private ElementType parseElementType(int value) {
    if (value < 0 || value >= ElementType.values().length)
      throw Errors.invalidData("vector element type");
    return ElementType.values()[value];
  }

  private VectorCodec parseVectorCodec(int value) {
    if (value < 0 || value >= VectorCodec.values().length) throw Errors.invalidData("vector codec");
    return VectorCodec.values()[value];
  }

  private NullStrategy parseNullStrategy(int value) {
    if (value < 0 || value >= NullStrategy.values().length)
      throw Errors.invalidData("null strategy");
    return NullStrategy.values()[value];
  }

  private ControlOpcode parseControlOpcode(int value) {
    if (value < 0 || value >= ControlOpcode.values().length)
      throw Errors.invalidData("control opcode");
    return ControlOpcode.values()[value];
  }

  private ControlStreamCodec parseControlStreamCodec(int value) {
    if (value < 0 || value >= ControlStreamCodec.values().length) {
      throw Errors.invalidData("control stream codec");
    }
    return ControlStreamCodec.values()[value];
  }

  private DictionaryFallback parseDictionaryFallback(int value) {
    if (value < 0 || value >= DictionaryFallback.values().length) {
      throw Errors.invalidData("dictionary fallback");
    }
    return DictionaryFallback.values()[value];
  }

  private static List<Byte> smallestU64Bytes(long value) {
    List<Byte> out = new ArrayList<>();
    ProtocolHelpers.writeSmallestU64(value, out);
    return out;
  }

  private static void appendList(ByteArrayOutputStream out, List<Byte> bytes) {
    for (byte b : bytes) out.write(b);
  }

  private static boolean[] toPrimitiveBooleanArray(List<Boolean> values) {
    boolean[] out = new boolean[values == null ? 0 : values.size()];
    if (values != null) for (int i = 0; i < values.size(); i++) out[i] = values.get(i);
    return out;
  }

  private static List<Boolean> toBoxedBooleanList(boolean[] values) {
    List<Boolean> out = new ArrayList<>(values.length);
    for (boolean value : values) out.add(value);
    return out;
  }

  private static List<Byte> toByteList(ByteArrayOutputStream out) {
    return new ByteArrayListAdapter(out);
  }

  private static final class ByteArrayListAdapter extends ArrayList<Byte> {
    private final ByteArrayOutputStream out;

    private ByteArrayListAdapter(ByteArrayOutputStream out) {
      this.out = out;
    }

    @Override
    public boolean add(Byte b) {
      out.write(b);
      return true;
    }
  }
}
