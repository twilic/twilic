import 'dart:typed_data';

import 'codec.dart';
import 'errors.dart';
import 'model.dart';
import 'session.dart';
import 'wire.dart';

Value typedVectorToValue(TypedVector vector) {
  switch (vector.elementType) {
    case ElementType.boolType:
      return newArray(vector.data.bools.map(newBool).toList());
    case ElementType.i64:
      return newArray(vector.data.i64s.map(newI64).toList());
    case ElementType.u64:
      return newArray(vector.data.u64s.map(newU64).toList());
    case ElementType.f64:
      return newArray(vector.data.f64s.map(newF64).toList());
    case ElementType.string:
      return newArray(vector.data.strings.map(newString).toList());
    case ElementType.binary:
    case ElementType.anyValue:
      return newArray(vector.data.values.map((v) => v.clone()).toList());
  }
}

List<MapEntry> entriesToMap(List<MessageMapEntry> entries, SessionState state) {
  final out = <MapEntry>[];
  for (final e in entries) {
    final key = keyRefString(e.key, state);
    out.add(MapEntry(key, e.value.clone()));
    final (_, ok) = state.keyTable.getId(key);
    if (!ok) state.keyTable.register(key);
  }
  return out;
}

String keyRefString(KeyRef key, SessionState state) {
  if (key.isId) {
    final (s, ok) = state.keyTable.getValue(key.id);
    return ok ? s : '';
  }
  return key.literal;
}

String? keyRefFieldIdentity(KeyRef key, SessionState state) {
  final s = keyRefString(key, state);
  return s.isEmpty ? null : s;
}

List<MapEntry> shapeValuesToMap(
  List<String> keys,
  List<bool> presence,
  bool hasPresence,
  List<Value> values,
) {
  final out = <MapEntry>[];
  var idx = 0;
  for (var i = 0; i < keys.length; i++) {
    if (hasPresence && i < presence.length && !presence[i]) continue;
    if (idx >= values.length) break;
    out.add(MapEntry(keys[i], values[idx].clone()));
    idx++;
  }
  return out;
}

void writeSmallestU64(int value, BytesBuilder out) {
  if (value <= 0xFF) {
    out.addByte(1);
    out.addByte(value);
    return;
  }
  if (value <= 0xFFFF) {
    out.addByte(2);
    out.addByte(value & 0xFF);
    out.addByte((value >> 8) & 0xFF);
    return;
  }
  if (value <= 0xFFFFFFFF) {
    out.addByte(4);
    out.addByte(value & 0xFF);
    out.addByte((value >> 8) & 0xFF);
    out.addByte((value >> 16) & 0xFF);
    out.addByte((value >> 24) & 0xFF);
    return;
  }
  out.addByte(8);
  appendU64Le(out, value);
}

(int, Reader) readSmallestU64(Reader reader) {
  final size = reader.readU8();
  switch (size) {
    case 1:
      return (reader.readU8(), reader);
    case 2:
      final b = reader.readExact(2);
      return (b[0] | (b[1] << 8), reader);
    case 4:
      final b = reader.readExact(4);
      return (
        b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24),
        reader,
      );
    case 8:
      return (readU64Le(reader), reader);
    default:
      throw invalidData('smallest u64 size');
  }
}

List<List<Value>> rowsFromValues(List<Value> values) {
  final rows = <List<Value>>[];
  for (final v in values) {
    if (v.kind == ValueKind.array) {
      rows.add(v.arr.map((x) => x.clone()).toList());
    } else {
      rows.add([v.clone()]);
    }
  }
  return rows;
}

(NullStrategy, List<bool>?, bool) columnNullStrategy(
  List<Value> values,
  List<bool> presentBits,
) {
  final nullCount = values.where((v) => v.kind == ValueKind.nullKind).length;
  if (nullCount == 0) {
    return (NullStrategy.allPresentElided, null, false);
  }
  if (nullCount <= values.length ~/ 4) {
    final inverted = presentBits.map((b) => !b).toList();
    return (NullStrategy.invertedPresenceBitmap, inverted, true);
  }
  return (NullStrategy.presenceBitmap, List<bool>.from(presentBits), true);
}

List<Value> stripNulls(List<Value> values) =>
    values.where((v) => v.kind != ValueKind.nullKind).toList();

List<Column>? rowsToColumns(List<List<Value>> rows) {
  if (rows.isEmpty) return null;
  final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  final columnValues = List.generate(width, (_) => <Value>[]);
  final columnPresence = List.generate(width, (_) => <bool>[]);
  for (final row in rows) {
    for (var col = 0; col < width; col++) {
      final value = col < row.length ? row[col].clone() : newNull();
      columnValues[col].add(value);
      columnPresence[col].add(value.kind != ValueKind.nullKind);
    }
  }
  return List.generate(width, (col) {
    final (nullStrategy, presence, hasPresence) =
        columnNullStrategy(columnValues[col], columnPresence[col]);
    final (codec, tvd) =
        inferColumnCodecAndValues(stripNulls(columnValues[col]));
    return Column(
      fieldId: col,
      nullStrategy: nullStrategy,
      presence: presence ?? [],
      hasPresence: hasPresence,
      codec: codec,
      values: tvd,
    );
  });
}

(VectorCodec, TypedVectorData) inferColumnCodecAndValues(List<Value> values) {
  if (values.isEmpty) {
    return (
      VectorCodec.plain,
      TypedVectorData(kind: ElementType.anyValue, values: []),
    );
  }
  final kinds = values.map((v) => v.kind).toList();
  if (kinds.every((k) => k == ValueKind.i64)) {
    final data = values.map((v) => v.i64).toList();
    return (selectIntegerCodec(data), typedDataI64(data));
  }
  if (kinds.every((k) => k == ValueKind.u64)) {
    final data = values.map((v) => v.u64).toList();
    return (selectU64Codec(data), typedDataU64(data));
  }
  if (kinds.every((k) => k == ValueKind.f64)) {
    final data = values.map((v) => v.f64).toList();
    return (selectFloatCodec(data), typedDataF64(data));
  }
  if (kinds.every((k) => k == ValueKind.boolKind)) {
    final data = values.map((v) => v.boolValue).toList();
    return (VectorCodec.directBitpack, typedDataBool(data));
  }
  if (kinds.every((k) => k == ValueKind.string)) {
    final data = values.map((v) => v.str).toList();
    return (selectStringCodec(data), typedDataString(data));
  }
  return (
    VectorCodec.plain,
    TypedVectorData(
      kind: ElementType.anyValue,
      values: values.map((v) => v.clone()).toList(),
    ),
  );
}

TypedVectorData typedDataI64(List<int> data) =>
    TypedVectorData(kind: ElementType.i64, i64s: data);
TypedVectorData typedDataU64(List<int> data) =>
    TypedVectorData(kind: ElementType.u64, u64s: data);
TypedVectorData typedDataF64(List<double> data) =>
    TypedVectorData(kind: ElementType.f64, f64s: data);
TypedVectorData typedDataBool(List<bool> data) =>
    TypedVectorData(kind: ElementType.boolType, bools: data);
TypedVectorData typedDataString(List<String> data) =>
    TypedVectorData(kind: ElementType.string, strings: data);

VectorCodec selectIntegerCodec(List<int> values) {
  if (values.length < 4) return VectorCodec.plain;
  final deltaVals = deltas(values);
  final dd = deltas(deltaVals);
  var nonZeroDd = 0;
  for (var i = 1; i < dd.length; i++) {
    if (dd[i] != 0) nonZeroDd++;
  }
  final nonZeroRatio = dd.length > 1 ? nonZeroDd / (dd.length - 1) : 0.0;
  final deltaRangeBits = bitWidthSigned(
    deltaVals.reduce((a, b) => a < b ? a : b),
    deltaVals.reduce((a, b) => a > b ? a : b),
  );
  if (values.length >= 8 && (nonZeroRatio <= 0.25 || deltaRangeBits <= 2)) {
    return VectorCodec.deltaDeltaBitpack;
  }
  final (repeatedRatio, avgRun) = runStats(values);
  if (repeatedRatio >= 0.5 && avgRun >= 3.0) return VectorCodec.rle;
  final rangeBits = bitWidthSigned(
    values.reduce((a, b) => a < b ? a : b),
    values.reduce((a, b) => a > b ? a : b),
  );
  if (rangeBits <= 60) return VectorCodec.forBitpack;
  var monotonic = true;
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) {
      monotonic = false;
      break;
    }
  }
  if (values.length >= 8 && monotonic && deltaRangeBits <= rangeBits - 3) {
    return VectorCodec.deltaForBitpack;
  }
  var maxAbsDeltaBits = 0;
  for (final v in deltaVals) {
    maxAbsDeltaBits = maxAbsDeltaBits > bitWidthU64(abs64(v))
        ? maxAbsDeltaBits
        : bitWidthU64(abs64(v));
  }
  if (maxAbsDeltaBits <= 61) return VectorCodec.deltaBitpack;
  var maxBitWidth = 0;
  for (final v in values) {
    maxBitWidth = maxBitWidth > bitWidthU64(abs64(v))
        ? maxBitWidth
        : bitWidthU64(abs64(v));
  }
  if (values.length >= 8 && maxBitWidth <= 16 && !monotonic) {
    return VectorCodec.simple8b;
  }
  if (maxBitWidth < 64) return VectorCodec.directBitpack;
  return VectorCodec.plain;
}

VectorCodec selectU64Codec(List<int> values) {
  var allSigned = true;
  for (final v in values) {
    if (v > 0x7FFFFFFFFFFFFFFF) {
      allSigned = false;
      break;
    }
  }
  if (allSigned) {
    return selectIntegerCodec(
      values.map((v) => v & 0x7FFFFFFFFFFFFFFF).toList(),
    );
  }
  if (values.length < 4) return VectorCodec.directBitpack;
  final (repeatedRatio, avgRun) = runStats(values);
  if (repeatedRatio >= 0.5 && avgRun >= 3.0) return VectorCodec.rle;
  if (bitWidthU64(values.reduce((a, b) => a > b ? a : b) -
          values.reduce((a, b) => a < b ? a : b)) <=
      60) {
    return VectorCodec.forBitpack;
  }
  var maxWidth = 0;
  for (final v in values) {
    maxWidth = maxWidth > bitWidthU64(v) ? maxWidth : bitWidthU64(v);
  }
  if (values.length >= 8 && maxWidth <= 16) return VectorCodec.simple8b;
  if (maxWidth < 64) return VectorCodec.directBitpack;
  return VectorCodec.plain;
}

VectorCodec selectFloatCodec(List<double> values) {
  if (values.length < 4) return VectorCodec.plain;
  var changes = 0;
  final b0 = ByteData(8)..setFloat64(0, values[0], Endian.little);
  var prev = b0.getUint64(0, Endian.little);
  for (var i = 1; i < values.length; i++) {
    final b = ByteData(8)..setFloat64(0, values[i], Endian.little);
    final bits = b.getUint64(0, Endian.little);
    if (bits != prev) changes++;
    prev = bits;
  }
  return changes * 2 <= values.length
      ? VectorCodec.xorFloat
      : VectorCodec.plain;
}

VectorCodec selectStringCodec(List<String> values) {
  if (values.isEmpty) return VectorCodec.plain;
  if (values.toSet().length * 2 <= values.length) return VectorCodec.dictionary;
  var prefixGain = 0;
  var prev = '';
  for (final v in values) {
    prefixGain += commonPrefixLen(prev, v);
    prev = v;
  }
  if (prefixGain > values.length * 2) return VectorCodec.prefixDelta;
  return VectorCodec.plain;
}

List<int> deltas(List<int> values) {
  final out = <int>[];
  for (var i = 0; i < values.length; i++) {
    out.add(i == 0 ? values[i] : values[i] - values[i - 1]);
  }
  return out;
}

(double, double) runStats(List<int> values) {
  if (values.isEmpty) return (0.0, 0.0);
  final runs = <int>[];
  var runLen = 1;
  for (var i = 1; i < values.length; i++) {
    if (values[i] == values[i - 1]) {
      runLen++;
    } else {
      runs.add(runLen);
      runLen = 1;
    }
  }
  runs.add(runLen);
  final repeatedItems = runs.where((r) => r > 1).fold<int>(0, (a, r) => a + r);
  return (
    repeatedItems / values.length,
    runs.fold<int>(0, (a, r) => a + r) / runs.length
  );
}

int bitWidthSigned(int min, int max) {
  final rangeVal = max >= min ? max - min : min - max;
  return bitWidthU64(rangeVal);
}

int bitWidthU64(int v) {
  if (v == 0) return 1;
  var n = v;
  var bits = 0;
  while (n > 0) {
    bits++;
    n >>= 1;
  }
  return bits;
}

int abs64(int v) => v < 0 ? -v : v;

int commonPrefixLen(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) return i;
  }
  return n;
}

TemplateDescriptor templateDescriptorFromColumns(
  int templateId,
  List<Column> columns,
) {
  return TemplateDescriptor(
    templateId: templateId,
    fieldIds: columns.map((c) => c.fieldId).toList(),
    nullStrategies: columns.map((c) => c.nullStrategy).toList(),
    codecs: columns.map((c) => c.codec).toList(),
  );
}

(int, bool) findTemplateId(
    Map<int, TemplateDescriptor> templates, List<Column> columns) {
  final ids = templates.keys.toList()..sort();
  for (final id in ids) {
    final t = templates[id]!;
    if (t.fieldIds.length != columns.length) continue;
    var ok = true;
    for (var i = 0; i < t.fieldIds.length; i++) {
      if (t.fieldIds[i] != columns[i].fieldId ||
          t.nullStrategies[i] != columns[i].nullStrategy) {
        ok = false;
        break;
      }
    }
    if (ok) return (id, true);
  }
  return (0, false);
}

(List<bool>, List<Column>) diffTemplateColumns(
  List<Column> previous,
  List<Column> current,
) {
  final mask = <bool>[];
  final changed = <Column>[];
  for (var i = 0; i < current.length; i++) {
    if (i >= previous.length ||
        estimateColumnSize(previous[i]) != estimateColumnSize(current[i])) {
      mask.add(true);
      changed.add(current[i]);
    } else {
      mask.add(false);
    }
  }
  return (mask, changed);
}

List<Column> mergeTemplateColumns(
  List<Column> previous,
  List<bool> changedMask,
  List<Column> changed,
) {
  final out = <Column>[];
  var idx = 0;
  for (var i = 0; i < changedMask.length; i++) {
    if (changedMask[i]) {
      if (idx >= changed.length) {
        throw invalidData('template changed column count mismatch');
      }
      out.add(changed[idx++]);
    } else {
      if (i >= previous.length) {
        throw invalidData('template reference out of range');
      }
      out.add(previous[i]);
    }
  }
  return out;
}

(List<PatchOperation>, int) diffMessage(Message prev, Message current) {
  final a = messageFields(prev);
  final b = messageFields(current);
  final n = a.length > b.length ? a.length : b.length;
  final ops = <PatchOperation>[];
  for (var i = 0; i < n; i++) {
    if (i < a.length && i < b.length) {
      if (equal(a[i], b[i])) {
        ops.add(PatchOperation(fieldId: i, opcode: PatchOpcode.keep));
      } else {
        ops.add(PatchOperation(
          fieldId: i,
          opcode: PatchOpcode.replaceScalar,
          value: b[i].clone(),
        ));
      }
    } else if (i < b.length) {
      ops.add(PatchOperation(
        fieldId: i,
        opcode: PatchOpcode.insertField,
        value: b[i].clone(),
      ));
    } else {
      ops.add(PatchOperation(fieldId: i, opcode: PatchOpcode.deleteField));
    }
  }
  return (ops, 0);
}

List<Value> messageFields(Message message) {
  switch (message.kind) {
    case MessageKind.array:
      return message.array.map((v) => v.clone()).toList();
    case MessageKind.map:
      return message.map.map((e) => e.value.clone()).toList();
    case MessageKind.shapedObject:
      return message.shapedObject!.values.map((v) => v.clone()).toList();
    case MessageKind.schemaObject:
      return message.schemaObject!.fields.map((v) => v.clone()).toList();
    default:
      return [];
  }
}

Message rebuildMessageLike(Message base, List<Value> fields) {
  switch (base.kind) {
    case MessageKind.array:
      return Message(kind: MessageKind.array, array: fields);
    case MessageKind.map:
      final entries = <MessageMapEntry>[];
      for (var i = 0; i < fields.length; i++) {
        if (i >= base.map.length) {
          throw invalidData('patch map shape mismatch');
        }
        entries.add(MessageMapEntry(key: base.map[i].key, value: fields[i]));
      }
      return Message(kind: MessageKind.map, map: entries);
    case MessageKind.shapedObject:
      final so = base.shapedObject!;
      return Message(
        kind: MessageKind.shapedObject,
        shapedObject: ShapedObjectMessage(
          shapeId: so.shapeId,
          presence: List<bool>.from(so.presence),
          hasPresence: so.hasPresence,
          values: fields,
        ),
      );
    case MessageKind.schemaObject:
      final so = base.schemaObject!;
      return Message(
        kind: MessageKind.schemaObject,
        schemaObject: SchemaObjectMessage(
          schemaId: so.schemaId,
          presence: List<bool>.from(so.presence),
          hasPresence: so.hasPresence,
          fields: fields,
        ),
      );
    default:
      throw invalidData(
          'state patch reconstruction unsupported for this message kind');
  }
}

int estimateMessageSize(Message message) {
  switch (message.kind) {
    case MessageKind.scalar:
      return 1 + estimateValueSize(message.scalar!);
    case MessageKind.array:
      return 1 +
          varuintSize(message.array.length) +
          message.array.fold(0, (s, v) => s + estimateValueSize(v));
    case MessageKind.map:
      return 1 +
          varuintSize(message.map.length) +
          message.map.fold(
            0,
            (s, e) => s + encodedKeyRefSize(e.key) + estimateValueSize(e.value),
          );
    case MessageKind.statePatch:
      final sp = message.statePatch!;
      var total = 1 + 2 + varuintSize(sp.operations.length);
      for (final op in sp.operations) {
        total += varuintSize(op.fieldId) +
            2 +
            (op.value != null ? estimateValueSize(op.value!) : 0);
      }
      return total;
    default:
      return 16;
  }
}

int estimateColumnSize(Column column) {
  var size = varuintSize(column.fieldId) + 4;
  switch (column.values.kind) {
    case ElementType.boolType:
      return size + column.values.bools.length ~/ 8 + 2;
    case ElementType.i64:
      return size + column.values.i64s.length * 4;
    case ElementType.u64:
      return size + column.values.u64s.length * 4;
    case ElementType.f64:
      return size + column.values.f64s.length * 8;
    case ElementType.string:
      return size +
          column.values.strings.fold(0, (s, str) => s + encodedStringSize(str));
    default:
      return size;
  }
}

int estimateValueSize(Value value) {
  switch (value.kind) {
    case ValueKind.nullKind:
    case ValueKind.boolKind:
      return 1;
    case ValueKind.i64:
      return 2 + smallestU64Size(encodeZigzag(value.i64));
    case ValueKind.u64:
      return 2 + smallestU64Size(value.u64);
    case ValueKind.f64:
      return 9;
    case ValueKind.string:
      return 2 + encodedStringSize(value.str);
    case ValueKind.binary:
      return 1 + encodedBytesSize(value.bin.length);
    case ValueKind.array:
      return 1 +
          varuintSize(value.arr.length) +
          value.arr.fold(0, (s, v) => s + estimateValueSize(v));
    case ValueKind.map:
      return 1 +
          varuintSize(value.map.length) +
          value.map.fold(
            0,
            (s, e) => s + encodedStringSize(e.key) + estimateValueSize(e.value),
          );
  }
}

int encodedBytesSize(int length) => varuintSize(length) + length;
int encodedStringSize(String value) => encodedBytesSize(value.codeUnits.length);

int encodedKeyRefSize(KeyRef key) {
  if (key.isId) return 1 + varuintSize(key.id);
  return encodedStringSize(key.literal);
}

int varuintSize(int value) {
  var sz = 1;
  var v = value;
  while (v >= 0x80) {
    v >>= 7;
    sz++;
  }
  return sz;
}

int smallestU64Size(int value) {
  if (value <= 0xFF) return 1;
  if (value <= 0xFFFF) return 2;
  if (value <= 0xFFFFFFFF) return 4;
  return 8;
}

int encodedSize(Message message) => estimateMessageSize(message);

bool shouldRegisterShape(List<String> keys, int observedCount) =>
    keys.isNotEmpty && observedCount >= 2;

List<Column>? columnsFromMapValues(List<Value> values) {
  if (values.isEmpty) return null;
  for (final v in values) {
    if (v.kind != ValueKind.map) return null;
  }
  final keyOrder = <String>[];
  final keyIndex = <String, int>{};
  final columnValues = <List<Value>>[];
  final columnPresence = <List<bool>>[];
  for (var rowIdx = 0; rowIdx < values.length; rowIdx++) {
    final row = values[rowIdx];
    final present = List<bool>.filled(keyOrder.length, false, growable: true);
    for (final e in row.map) {
      var colIdx = keyIndex[e.key];
      if (colIdx == null) {
        colIdx = keyOrder.length;
        keyOrder.add(e.key);
        keyIndex[e.key] = colIdx;
        columnValues.add(List<Value>.filled(rowIdx, newNull(), growable: true));
        columnPresence.add(List<bool>.filled(rowIdx, false, growable: true));
        present.add(false);
      }
      columnValues[colIdx].add(e.value.clone());
      columnPresence[colIdx].add(true);
      present[colIdx] = true;
    }
    for (var colIdx = 0; colIdx < keyOrder.length; colIdx++) {
      if (!present[colIdx]) {
        columnValues[colIdx].add(newNull());
        columnPresence[colIdx].add(false);
      }
    }
  }
  return List.generate(keyOrder.length, (fieldId) {
    final colValues = columnValues[fieldId];
    final presentBits = columnPresence[fieldId];
    final (nullStrategy, presence, hasPresence) =
        columnNullStrategy(colValues, presentBits);
    final (codec, tvd) = inferColumnCodecAndValues(stripNulls(colValues));
    return Column(
      fieldId: fieldId,
      nullStrategy: nullStrategy,
      presence: presence ?? [],
      hasPresence: hasPresence,
      codec: codec,
      values: tvd,
    );
  });
}

bool hasUniformMicroBatchShape(List<Value> values) {
  if (values.isEmpty || values[0].kind != ValueKind.map) return false;
  final keys = values[0].map.map((e) => e.key).toList();
  for (var i = 1; i < values.length; i++) {
    final v = values[i];
    if (v.kind != ValueKind.map || v.map.length != keys.length) return false;
    for (var j = 0; j < keys.length; j++) {
      if (v.map[j].key != keys[j]) return false;
    }
  }
  return true;
}

bool supportsStatePatch(Message? base, Message current) {
  if (base == null) return false;
  if (base.kind != current.kind) return false;
  return base.kind == MessageKind.map ||
      base.kind == MessageKind.schemaObject ||
      base.kind == MessageKind.shapedObject ||
      base.kind == MessageKind.array;
}

int typedVectorLen(TypedVectorData data) {
  switch (data.kind) {
    case ElementType.boolType:
      return data.bools.length;
    case ElementType.i64:
      return data.i64s.length;
    case ElementType.u64:
      return data.u64s.length;
    case ElementType.f64:
      return data.f64s.length;
    case ElementType.string:
      return data.strings.length;
    case ElementType.binary:
      return data.binary.length;
    case ElementType.anyValue:
      return data.values.length;
  }
}
