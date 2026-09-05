package io.twilic.internal.core;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

enum StringMode {
  EMPTY,
  LITERAL,
  REF,
  PREFIX_DELTA,
  INLINE_ENUM,
}

enum ElementType {
  BOOL,
  I64,
  U64,
  F64,
  STRING,
  BINARY,
  VALUE,
}

enum VectorCodec {
  PLAIN,
  DIRECT_BITPACK,
  DELTA_BITPACK,
  FOR_BITPACK,
  DELTA_FOR_BITPACK,
  DELTA_DELTA_BITPACK,
  RLE,
  PATCHED_FOR,
  SIMPLE8B,
  XOR_FLOAT,
  DICTIONARY,
  STRING_REF,
  PREFIX_DELTA,
}

enum NullStrategy {
  NONE,
  PRESENCE_BITMAP,
  INVERTED_PRESENCE_BITMAP,
  ALL_PRESENT_ELIDED,
}

enum ControlOpcode {
  REGISTER_KEYS,
  REGISTER_SHAPE,
  REGISTER_STRINGS,
  PROMOTE_STRING_FIELD_TO_ENUM,
  RESET_TABLES,
  RESET_STATE,
}

enum PatchOpcode {
  KEEP,
  REPLACE_SCALAR,
  REPLACE_VECTOR,
  APPEND_VECTOR,
  TRUNCATE_VECTOR,
  DELETE_FIELD,
  INSERT_FIELD,
  STRING_REF,
  PREFIX_DELTA,
}

enum ControlStreamCodec {
  PLAIN,
  RLE,
  BITPACK,
  HUFFMAN,
  FSE,
}

enum DictionaryFallback {
  FAIL_FAST,
  STATELESS_RETRY,
}

final class MessageMapEntry {
  KeyRef key;
  Value value;

  MessageMapEntry() {}

  MessageMapEntry(KeyRef key, Value value) {
    this.key = key;
    this.value = value;
  }
}

final class TypedVectorData {
  List<Boolean> bools = new ArrayList<>();
  List<Long> i64s = new ArrayList<>();
  List<Long> u64s = new ArrayList<>();
  List<Double> f64s = new ArrayList<>();
  List<String> strings = new ArrayList<>();
  List<byte[]> binary = new ArrayList<>();
  List<Value> values = new ArrayList<>();
  ElementType kind = ElementType.VALUE;
}

final class TypedVector {
  ElementType elementType = ElementType.VALUE;
  VectorCodec codec = VectorCodec.PLAIN;
  TypedVectorData data = new TypedVectorData();
}

final class Column {
  long fieldId;
  NullStrategy nullStrategy = NullStrategy.NONE;
  List<Boolean> presence = new ArrayList<>();
  boolean hasPresence;
  VectorCodec codec = VectorCodec.PLAIN;
  Long dictionaryId;
  TypedVectorData values = new TypedVectorData();
}

final class RegisterShapeControl {
  long shapeId;
  List<KeyRef> keys = new ArrayList<>();
}

final class PromoteEnumControl {
  String fieldIdentity;
  List<String> values = new ArrayList<>();
}

final class ControlMessage {
  List<String> registerKeys = new ArrayList<>();
  RegisterShapeControl registerShape;
  List<String> registerStrings = new ArrayList<>();
  PromoteEnumControl promoteStringFieldToEnum;
  boolean resetTables;
  boolean resetState;
  ControlOpcode opcode = ControlOpcode.RESET_TABLES;
}

final class PatchOperation {
  long fieldId;
  PatchOpcode opcode = PatchOpcode.KEEP;
  Value value;
}

final class ShapedObjectMessage {
  long shapeId;
  List<Boolean> presence = new ArrayList<>();
  boolean hasPresence;
  List<Value> values = new ArrayList<>();
}

final class SchemaObjectMessage {
  Long schemaId;
  List<Boolean> presence = new ArrayList<>();
  boolean hasPresence;
  List<Value> fields = new ArrayList<>();
}

final class RowBatchMessage {
  List<List<Value>> rows = new ArrayList<>();
}

final class ColumnBatchMessage {
  long count;
  List<Column> columns = new ArrayList<>();
}

final class ExtMessage {
  long extType;
  byte[] payload = new byte[0];
}

final class StatePatchMessage {
  BaseRef baseRef = BaseRef.previous();
  List<PatchOperation> operations = new ArrayList<>();
  List<Value> literals = new ArrayList<>();
}

final class TemplateBatchMessage {
  long templateId;
  long count;
  List<Boolean> changedColumnMask = new ArrayList<>();
  List<Column> columns = new ArrayList<>();
}

final class ControlStreamMessage {
  ControlStreamCodec codec = ControlStreamCodec.PLAIN;
  byte[] payload = new byte[0];
}

final class BaseSnapshotMessage {
  long baseId;
  long schemaOrShapeRef;
  Message payload;
}

final class TemplateDescriptor {
  long templateId;
  List<Long> fieldIds = new ArrayList<>();
  List<NullStrategy> nullStrategies = new ArrayList<>();
  List<VectorCodec> codecs = new ArrayList<>();
}

final class Message {
  MessageKind kind = MessageKind.SCALAR;
  Value scalar;
  List<Value> array = new ArrayList<>();
  List<MessageMapEntry> map = new ArrayList<>();
  ShapedObjectMessage shapedObject;
  SchemaObjectMessage schemaObject;
  TypedVector typedVector;
  RowBatchMessage rowBatch;
  ColumnBatchMessage columnBatch;
  ControlMessage control;
  ExtMessage ext;
  StatePatchMessage statePatch;
  TemplateBatchMessage templateBatch;
  ControlStreamMessage controlStream;
  BaseSnapshotMessage baseSnapshot;
}

final class DictionaryProfile {
  long version;
  long hash;
  long expiresAt;
  DictionaryFallback fallback;

  DictionaryProfile(long version, long hash, long expiresAt, DictionaryFallback fallback) {
    this.version = version;
    this.hash = hash;
    this.expiresAt = expiresAt;
    this.fallback = fallback;
  }
}

final class InternTable {
  final Map<String, Long> byValue = new HashMap<>();
  final List<String> byId = new ArrayList<>();

  Long getId(String value) {
    return byValue.get(value);
  }

  String getValue(long id) {
    if (id < 0 || id >= byId.size()) {
      return null;
    }
    return byId.get((int) id);
  }

  long register(String value) {
    Long existing = byValue.get(value);
    if (existing != null) {
      return existing;
    }
    long id = byId.size();
    byId.add(value);
    byValue.put(value, id);
    return id;
  }

  void clear() {
    byValue.clear();
    byId.clear();
  }
}

final class ShapeTable {
  final Map<String, Long> byKeys = new HashMap<>();
  final Map<Long, List<String>> byId = new HashMap<>();
  final Map<String, Long> observations = new HashMap<>();
  long nextId;
}

final class BaseSnapshotEntry {
  long id;
  Message message;
}

final class SessionState {
  SessionOptions options = new SessionOptions();
  InternTable keyTable = new InternTable();
  InternTable stringTable = new InternTable();
  ShapeTable shapeTable = new ShapeTable();
  Map<String, Long> encodeShapeObservations = new HashMap<>();
  List<BaseSnapshotEntry> baseSnapshots = new ArrayList<>();
  Map<Long, TemplateDescriptor> templates = new HashMap<>();
  Map<Long, List<Column>> templateColumns = new HashMap<>();
  Map<String, List<String>> fieldEnums = new HashMap<>();
  Map<Long, byte[]> dictionaries = new HashMap<>();
  Map<Long, DictionaryProfile> dictionaryProfiles = new HashMap<>();
  Map<Long, Schema> schemas = new HashMap<>();
  Long lastSchemaId;
  Message previousMessage;
  Integer previousMessageSize;
  long nextBaseId;
  long nextTemplateId;
  long nextDictionaryId;
}
