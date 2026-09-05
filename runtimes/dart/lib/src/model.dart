import 'dart:typed_data';

enum MessageKind {
  scalar(0x00),
  array(0x01),
  map(0x02),
  shapedObject(0x03),
  schemaObject(0x04),
  typedVector(0x05),
  rowBatch(0x06),
  columnBatch(0x07),
  control(0x08),
  ext(0x09),
  statePatch(0x0a),
  templateBatch(0x0b),
  controlStream(0x0c),
  baseSnapshot(0x0d);

  const MessageKind(this.value);
  final int value;
  static (MessageKind, bool) fromByte(int b) {
    for (final k in values) {
      if (k.value == b) return (k, true);
    }
    return (scalar, false);
  }
}

enum ValueKind { nullKind, boolKind, i64, u64, f64, string, binary, array, map }

class MapEntry {
  MapEntry(this.key, this.value);
  final String key;
  final Value value;
}

class MessageMapEntry {
  MessageMapEntry({required this.key, required this.value});
  KeyRef key;
  Value value;
}

class KeyRef {
  KeyRef({this.literal = '', this.id = 0, this.isId = false});
  String literal;
  int id;
  bool isId;
  static KeyRef literalRef(String s) => KeyRef(literal: s);
  static KeyRef idRef(int id) => KeyRef(id: id, isId: true);
}

enum StringMode { empty, literal, ref, prefixDelta, inlineEnum }

class StringValue {
  StringValue(this.mode, {this.value = '', this.refId, this.prefixLen});
  final StringMode mode;
  final String value;
  final int? refId;
  final int? prefixLen;
  static (StringMode, bool) fromByte(int b) {
    if (b >= 0 && b <= 4) return (StringMode.values[b], true);
    return (StringMode.empty, false);
  }
}

enum ElementType {
  boolType(0),
  i64(1),
  u64(2),
  f64(3),
  string(4),
  binary(5),
  anyValue(6);

  const ElementType(this.wireValue);
  final int wireValue;
  int get value => wireValue;
  static (ElementType, bool) fromByte(int b) {
    for (final e in values) {
      if (e.wireValue == b) return (e, true);
    }
    return (ElementType.boolType, false);
  }
}

enum VectorCodec {
  plain(0),
  directBitpack(1),
  deltaBitpack(2),
  forBitpack(3),
  deltaForBitpack(4),
  deltaDeltaBitpack(5),
  rle(6),
  patchedFor(7),
  simple8b(8),
  xorFloat(9),
  dictionary(10),
  stringRef(11),
  prefixDelta(12);

  const VectorCodec(this.value);
  final int value;
  static (VectorCodec, bool) fromByte(int b) {
    if (b <= 12) return (values[b], true);
    return (VectorCodec.plain, false);
  }
}

enum NullStrategy {
  none(0),
  presenceBitmap(1),
  invertedPresenceBitmap(2),
  allPresentElided(3);

  const NullStrategy(this.value);
  final int value;
  static (NullStrategy, bool) fromByte(int b) {
    if (b <= 3) return (values[b], true);
    return (NullStrategy.none, false);
  }
}

enum ControlOpcode {
  registerKeys,
  registerShape,
  registerStrings,
  promoteStringFieldToEnum,
  resetTables,
  resetState,
}

enum PatchOpcode {
  keep(0),
  replaceScalar(1),
  replaceVector(2),
  appendVector(3),
  truncateVector(4),
  deleteField(5),
  insertField(6),
  stringRef(7),
  prefixDelta(8);

  const PatchOpcode(this.value);
  final int value;
  static (PatchOpcode, bool) fromByte(int b) {
    if (b <= 8) return (values[b], true);
    return (PatchOpcode.keep, false);
  }
}

enum ControlStreamCodec { plain, rle, bitpack, huffman, fse }

extension ControlStreamCodecWire on ControlStreamCodec {
  int get wireValue => index;
  static (ControlStreamCodec, bool) fromByte(int b) {
    if (b >= 0 && b < ControlStreamCodec.values.length) {
      return (ControlStreamCodec.values[b], true);
    }
    return (ControlStreamCodec.plain, false);
  }
}

class ControlStreamMessage {
  ControlStreamMessage({required this.codec, required this.payload});
  ControlStreamCodec codec;
  Uint8List payload;
}

class Value {
  Value({
    this.kind = ValueKind.nullKind,
    this.boolValue = false,
    this.i64 = 0,
    this.u64 = 0,
    this.f64 = 0.0,
    this.str = '',
    Uint8List? bin,
    List<Value>? arr,
    List<MapEntry>? map,
  })  : bin = bin ?? Uint8List(0),
        arr = arr ?? [],
        map = map ?? [];

  ValueKind kind;
  bool boolValue;
  int i64;
  int u64;
  double f64;
  String str;
  Uint8List bin;
  List<Value> arr;
  List<MapEntry> map;

  bool get isScalar => kind != ValueKind.array && kind != ValueKind.map;

  Value clone() {
    switch (kind) {
      case ValueKind.nullKind:
      case ValueKind.boolKind:
      case ValueKind.i64:
      case ValueKind.u64:
      case ValueKind.f64:
      case ValueKind.string:
        return Value(
            kind: kind,
            boolValue: boolValue,
            i64: i64,
            u64: u64,
            f64: f64,
            str: str);
      case ValueKind.binary:
        return Value(kind: kind, bin: Uint8List.fromList(bin));
      case ValueKind.array:
        return Value(kind: kind, arr: arr.map((v) => v.clone()).toList());
      case ValueKind.map:
        return Value(
            kind: kind,
            map: map.map((e) => MapEntry(e.key, e.value.clone())).toList());
    }
  }
}

Value newNull() => Value();
Value newBool(bool b) => Value(kind: ValueKind.boolKind, boolValue: b);
Value newI64(int n) => Value(kind: ValueKind.i64, i64: n);
Value newU64(int n) => Value(kind: ValueKind.u64, u64: n);
Value newF64(double n) => Value(kind: ValueKind.f64, f64: n);
Value newString(String s) => Value(kind: ValueKind.string, str: s);
Value newBinary(Uint8List b) =>
    Value(kind: ValueKind.binary, bin: Uint8List.fromList(b));
Value newArray(List<Value> items) =>
    Value(kind: ValueKind.array, arr: items.map((v) => v.clone()).toList());
MapEntry entry(String key, Value value) => MapEntry(key, value);
Value newMap(List<MapEntry> entries) => Value(
    kind: ValueKind.map,
    map: entries.map((e) => MapEntry(e.key, e.value.clone())).toList());

bool equal(Value a, Value b) {
  if (a.kind != b.kind) return false;
  switch (a.kind) {
    case ValueKind.nullKind:
      return true;
    case ValueKind.boolKind:
      return a.boolValue == b.boolValue;
    case ValueKind.i64:
      return a.i64 == b.i64;
    case ValueKind.u64:
      return a.u64 == b.u64;
    case ValueKind.f64:
      return a.f64 == b.f64;
    case ValueKind.string:
      return a.str == b.str;
    case ValueKind.binary:
      return _bytesEqual(a.bin, b.bin);
    case ValueKind.array:
      if (a.arr.length != b.arr.length) return false;
      for (var i = 0; i < a.arr.length; i++) {
        if (!equal(a.arr[i], b.arr[i])) return false;
      }
      return true;
    case ValueKind.map:
      if (a.map.length != b.map.length) return false;
      for (var i = 0; i < a.map.length; i++) {
        if (a.map[i].key != b.map[i].key ||
            !equal(a.map[i].value, b.map[i].value)) {
          return false;
        }
      }
      return true;
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class Message {
  Message({
    required this.kind,
    this.scalar,
    this.array = const [],
    this.map = const [],
    this.shapedObject,
    this.schemaObject,
    this.typedVector,
    this.rowBatch,
    this.columnBatch,
    this.statePatch,
    this.templateBatch,
    this.baseSnapshot,
    this.controlStream,
  });
  MessageKind kind;
  Value? scalar;
  List<Value> array;
  List<MessageMapEntry> map;
  ShapedObjectMessage? shapedObject;
  SchemaObjectMessage? schemaObject;
  TypedVector? typedVector;
  RowBatchMessage? rowBatch;
  ColumnBatchMessage? columnBatch;
  StatePatchMessage? statePatch;
  TemplateBatchMessage? templateBatch;
  BaseSnapshotMessage? baseSnapshot;
  ControlStreamMessage? controlStream;
}

class ColumnBatchMessage {
  ColumnBatchMessage({required this.count, this.columns = const []});
  int count;
  List<Column> columns;
}

class StatePatchMessage {
  StatePatchMessage({
    required this.baseRef,
    this.operations = const [],
    this.literals = const [],
  });
  BaseRef baseRef;
  List<PatchOperation> operations;
  List<Value> literals;
}

class PatchOperation {
  PatchOperation({required this.fieldId, required this.opcode, this.value});
  int fieldId;
  PatchOpcode opcode;
  Value? value;
}

class TemplateBatchMessage {
  TemplateBatchMessage({
    required this.templateId,
    required this.count,
    this.changedColumnMask = const [],
    this.columns = const [],
  });
  int templateId;
  int count;
  List<bool> changedColumnMask;
  List<Column> columns;
}

class BaseSnapshotMessage {
  BaseSnapshotMessage({
    required this.baseId,
    required this.schemaOrShapeRef,
    required this.payload,
  });
  int baseId;
  int schemaOrShapeRef;
  Message payload;
}

BaseRef baseRefPrevious() => BaseRef(previous: true);
BaseRef baseRefId(int id) => BaseRef(baseId: id);

class SchemaObjectMessage {
  SchemaObjectMessage({
    this.schemaId,
    required this.fields,
    this.presence = const [],
    this.hasPresence = false,
  });
  int? schemaId;
  List<bool> presence;
  bool hasPresence;
  List<Value> fields;
}

class RowBatchMessage {
  RowBatchMessage({this.rows = const []});
  List<List<Value>> rows;
}

class ShapedObjectMessage {
  ShapedObjectMessage(
      {required this.shapeId,
      required this.values,
      this.presence = const [],
      this.hasPresence = false});
  int shapeId;
  List<bool> presence;
  bool hasPresence;
  List<Value> values;
}

class SchemaField {
  SchemaField(
      {required this.number,
      required this.name,
      this.logicalType = '',
      this.required = false,
      this.enumValues = const []});
  int number;
  String name;
  String logicalType;
  bool required;
  List<String> enumValues;
}

class Schema {
  Schema({required this.schemaId, required this.name, required this.fields});
  int schemaId;
  String name;
  List<SchemaField> fields;
}

class BaseRef {
  BaseRef({this.previous = false, this.baseId = 0});
  bool previous;
  int baseId;
  static BaseRef previousRef() => BaseRef(previous: true);
  static BaseRef idRef(int id) => BaseRef(baseId: id);
}

class TypedVectorData {
  TypedVectorData({
    this.kind = ElementType.boolType,
    List<bool>? bools,
    List<int>? i64s,
    List<int>? u64s,
    List<double>? f64s,
    List<String>? strings,
    List<Uint8List>? binary,
    List<Value>? values,
  })  : bools = bools ?? [],
        i64s = i64s ?? [],
        u64s = u64s ?? [],
        f64s = f64s ?? [],
        strings = strings ?? [],
        binary = binary ?? [],
        values = values ?? [];
  ElementType kind;
  List<bool> bools;
  List<int> i64s;
  List<int> u64s;
  List<double> f64s;
  List<String> strings;
  List<Uint8List> binary;
  List<Value> values;
}

class TypedVector {
  TypedVector(
      {required this.elementType, required this.codec, required this.data});
  ElementType elementType;
  VectorCodec codec;
  TypedVectorData data;
}

class Column {
  Column({
    required this.fieldId,
    required this.nullStrategy,
    this.presence = const [],
    this.hasPresence = false,
    this.codec = VectorCodec.plain,
    this.dictionaryId,
    TypedVectorData? values,
  }) : values = values ?? TypedVectorData();
  int fieldId;
  NullStrategy nullStrategy;
  List<bool> presence;
  bool hasPresence;
  VectorCodec codec;
  int? dictionaryId;
  TypedVectorData values;
}

class TemplateDescriptor {
  TemplateDescriptor({
    required this.templateId,
    this.fieldIds = const [],
    this.nullStrategies = const [],
    this.codecs = const [],
  });
  int templateId;
  List<int> fieldIds;
  List<NullStrategy> nullStrategies;
  List<VectorCodec> codecs;
}
