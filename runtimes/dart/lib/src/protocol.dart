import 'dart:typed_data';

import 'codec.dart';
import 'errors.dart';
import 'model.dart';
import 'protocol_helpers.dart';
import 'session.dart';
import 'wire.dart';

const _tagNull = 0;
const _tagBoolFalse = 1;
const _tagBoolTrue = 2;
const _tagI64 = 3;
const _tagU64 = 4;
const _tagF64 = 5;
const _tagString = 6;
const _tagBinary = 7;
const _tagArray = 8;
const _tagMap = 9;

class TwilicCodec {
  TwilicCodec([SessionState? state]) : state = state ?? newSessionState();

  SessionState state;

  Uint8List encodeMessage(Message message) {
    final out = BytesBuilder();
    _writeMessage(message, out);
    return out.toBytes();
  }

  Message decodeMessage(Uint8List data) {
    final reader = newReader(data);
    final msg = _readMessage(reader);
    if (!reader.isEof) throw invalidData('trailing bytes in message');
    switch (msg.kind) {
      case MessageKind.control:
        break;
      case MessageKind.statePatch:
        final sp = msg.statePatch!;
        try {
          final reconstructed =
              _applyStatePatch(sp.baseRef, sp.operations, sp.literals);
          state.previousMessage = reconstructed.cloneMessage();
          state.previousMessageSize = data.length;
        } catch (e) {
          if (isUnknownReference(e) || isStatelessRetry(e)) rethrow;
        }
      case MessageKind.templateBatch:
        if (state.previousMessage == null) {
          state.previousMessage = msg.cloneMessage();
          state.previousMessageSize = data.length;
        }
      default:
        state.previousMessage = msg.cloneMessage();
        state.previousMessageSize = data.length;
    }
    return msg;
  }

  Uint8List encodeValue(Value value) {
    final msg = _messageForValue(value);
    final out = encodeMessage(msg);
    state.previousMessage = msg.cloneMessage();
    state.previousMessageSize = out.length;
    return out;
  }

  Value decodeValue(Uint8List data) {
    final msg = decodeMessage(data);
    state.previousMessage = msg.cloneMessage();
    switch (msg.kind) {
      case MessageKind.scalar:
        return msg.scalar!.clone();
      case MessageKind.array:
        return newArray(msg.array.map((v) => v.clone()).toList());
      case MessageKind.map:
        return newMap(entriesToMap(msg.map, state));
      case MessageKind.shapedObject:
        final so = msg.shapedObject!;
        final (keys, ok) = state.shapeTable.getKeys(so.shapeId);
        if (!ok || keys == null) throw _referenceError('shape_id', so.shapeId);
        return newMap(
            shapeValuesToMap(keys, so.presence, so.hasPresence, so.values));
      case MessageKind.typedVector:
        return typedVectorToValue(msg.typedVector!);
      default:
        throw invalidData(
            'decode_value expects scalar/array/map/vector message');
    }
  }

  Never _referenceError(String kind, int refId) {
    if (state.options.unknownReferencePolicy ==
        UnknownReferencePolicy.statelessRetry) {
      throw statelessRetryRequired(kind, refId);
    }
    throw unknownReference(kind, refId);
  }

  Message _messageForValue(Value value) {
    switch (value.kind) {
      case ValueKind.array:
        final tv = _tryMakeTypedVector(value.arr);
        if (tv != null) {
          return Message(kind: MessageKind.typedVector, typedVector: tv);
        }
        return Message(
          kind: MessageKind.array,
          array: value.arr.map((v) => v.clone()).toList(),
        );
      case ValueKind.map:
        final keys = value.map.map((e) => e.key).toList();
        final sk = shapeKey(keys);
        final hadObservation = state.encodeShapeObservations.containsKey(sk);
        final obs = _observeEncodeShapeCandidate(keys);
        final (shapeId, ok) = state.shapeTable.getId(keys);
        if (ok && (!hadObservation || obs >= 2)) {
          return _shapedMessage(shapeId, value.map);
        }
        return _mapMessage(value.map);
      default:
        return Message(kind: MessageKind.scalar, scalar: value.clone());
    }
  }

  Message _mapMessage(List<MapEntry> entries) {
    final out = <MessageMapEntry>[];
    for (final e in entries) {
      final (refId, ok) = state.keyTable.getId(e.key);
      final keyRef = ok ? KeyRef.idRef(refId) : KeyRef.literalRef(e.key);
      if (!ok) state.keyTable.register(e.key);
      out.add(MessageMapEntry(key: keyRef, value: e.value.clone()));
    }
    return Message(kind: MessageKind.map, map: out);
  }

  Message _shapedMessage(int shapeId, List<MapEntry> entries) {
    final (keys, ok) = state.shapeTable.getKeys(shapeId);
    if (!ok || keys == null) throw invalidData('shape_id');
    final index = {for (final e in entries) e.key: e.value};
    final values = <Value>[];
    final presence = <bool>[];
    var allPresent = true;
    for (final key in keys) {
      final v = index[key];
      if (v != null) {
        presence.add(true);
        values.add(v.clone());
      } else {
        presence.add(false);
        values.add(newNull());
        allPresent = false;
      }
    }
    return Message(
      kind: MessageKind.shapedObject,
      shapedObject: ShapedObjectMessage(
        shapeId: shapeId,
        values: values,
        presence: allPresent ? const [] : presence,
        hasPresence: !allPresent,
      ),
    );
  }

  int _observeEncodeShapeCandidate(List<String> keys) {
    final sk = shapeKey(keys);
    final count = (state.encodeShapeObservations[sk] ?? 0) + 1;
    state.encodeShapeObservations[sk] = count;
    if (shouldRegisterShape(keys, count)) {
      state.shapeTable.register(keys);
    }
    return count;
  }

  void _observeDecodeShapeCandidate(List<String> keys) {
    if (state.shapeTable.getId(keys).$2) return;
    final observed = state.shapeTable.observe(keys);
    if (shouldRegisterShape(keys, observed)) {
      state.shapeTable.register(keys);
    }
  }

  (List<bool>, bool) _readPresence(Reader reader) {
    final flag = reader.readU8();
    if (flag == 0) return (<bool>[], false);
    if (flag != 1) throw invalidData('presence flag');
    return (reader.readBitmap(), true);
  }

  void _writePresence(List<bool> presence, bool hasPresence, BytesBuilder out) {
    if (!hasPresence) {
      out.addByte(0);
      return;
    }
    out.addByte(1);
    encodeBitmap(presence, out);
  }

  TypedVector? _tryMakeTypedVector(List<Value> values) {
    if (values.length < 4) return null;
    var allBool = true;
    var allI64 = true;
    var allU64 = true;
    var allF64 = true;
    var allStr = true;
    for (final v in values) {
      allBool = allBool && v.kind == ValueKind.boolKind;
      allI64 = allI64 && v.kind == ValueKind.i64;
      allU64 = allU64 && v.kind == ValueKind.u64;
      allF64 = allF64 && v.kind == ValueKind.f64;
      allStr = allStr && v.kind == ValueKind.string;
    }
    if (!(allBool || allI64 || allU64 || allF64 || allStr)) return null;
    if (allBool) {
      final data = values.map((v) => v.boolValue).toList();
      return TypedVector(
        elementType: ElementType.boolType,
        codec: VectorCodec.directBitpack,
        data: typedDataBool(data),
      );
    }
    if (allI64) {
      final data = values.map((v) => v.i64).toList();
      return TypedVector(
        elementType: ElementType.i64,
        codec: selectIntegerCodec(data),
        data: typedDataI64(data),
      );
    }
    if (allU64) {
      final data = values.map((v) => v.u64).toList();
      return TypedVector(
        elementType: ElementType.u64,
        codec: selectU64Codec(data),
        data: typedDataU64(data),
      );
    }
    if (allF64) {
      final data = values.map((v) => v.f64).toList();
      return TypedVector(
        elementType: ElementType.f64,
        codec: selectFloatCodec(data),
        data: typedDataF64(data),
      );
    }
    final strings = values.map((v) => v.str).toList();
    return TypedVector(
      elementType: ElementType.string,
      codec: selectStringCodec(strings),
      data: typedDataString(strings),
    );
  }

  void _writeMessage(Message message, BytesBuilder out) {
    switch (message.kind) {
      case MessageKind.scalar:
        out.addByte(MessageKind.scalar.value);
        _writeValue(message.scalar!, out);
      case MessageKind.array:
        out.addByte(MessageKind.array.value);
        encodeVaruint(message.array.length, out);
        for (final v in message.array) {
          _writeValue(v, out);
        }
      case MessageKind.map:
        out.addByte(MessageKind.map.value);
        encodeVaruint(message.map.length, out);
        for (final e in message.map) {
          _writeKeyRef(e.key, out);
          _writeValue(e.value, out);
        }
      case MessageKind.shapedObject:
        final so = message.shapedObject!;
        out.addByte(MessageKind.shapedObject.value);
        encodeVaruint(so.shapeId, out);
        _writePresence(so.presence, so.hasPresence, out);
        encodeVaruint(so.values.length, out);
        for (final v in so.values) {
          _writeValue(v, out);
        }
      case MessageKind.schemaObject:
        final so = message.schemaObject!;
        out.addByte(MessageKind.schemaObject.value);
        if (so.schemaId != null) {
          out.addByte(1);
          encodeVaruint(so.schemaId!, out);
        } else {
          out.addByte(0);
        }
        out.addByte(0);
        encodeVaruint(so.fields.length, out);
        out.addByte(0);
        for (final v in so.fields) {
          _writeValue(v, out);
        }
      case MessageKind.typedVector:
        out.addByte(MessageKind.typedVector.value);
        _writeTypedVector(message.typedVector!, out);
      case MessageKind.rowBatch:
        final rb = message.rowBatch!;
        out.addByte(MessageKind.rowBatch.value);
        encodeVaruint(rb.rows.length, out);
        for (final row in rb.rows) {
          encodeVaruint(row.length, out);
          for (final v in row) {
            _writeValue(v, out);
          }
        }
      case MessageKind.columnBatch:
        final cb = message.columnBatch!;
        out.addByte(MessageKind.columnBatch.value);
        encodeVaruint(cb.count, out);
        encodeVaruint(cb.columns.length, out);
        for (final col in cb.columns) {
          _writeColumn(col, out);
        }
      case MessageKind.statePatch:
        final sp = message.statePatch!;
        out.addByte(MessageKind.statePatch.value);
        _writeBaseRef(sp.baseRef, out);
        encodeVaruint(sp.operations.length, out);
        for (final op in sp.operations) {
          encodeVaruint(op.fieldId, out);
          out.addByte(op.opcode.value);
          if (op.value != null) {
            out.addByte(1);
            _writeValue(op.value!, out);
          } else {
            out.addByte(0);
          }
        }
        encodeVaruint(sp.literals.length, out);
        for (final lit in sp.literals) {
          _writeValue(lit, out);
        }
      case MessageKind.templateBatch:
        final tb = message.templateBatch!;
        out.addByte(MessageKind.templateBatch.value);
        encodeVaruint(tb.templateId, out);
        encodeVaruint(tb.count, out);
        encodeBitmap(tb.changedColumnMask, out);
        encodeVaruint(tb.columns.length, out);
        for (final col in tb.columns) {
          _writeColumn(col, out);
        }
      case MessageKind.baseSnapshot:
        final bs = message.baseSnapshot!;
        out.addByte(MessageKind.baseSnapshot.value);
        encodeVaruint(bs.baseId, out);
        encodeVaruint(bs.schemaOrShapeRef, out);
        _writeMessage(bs.payload, out);
        registerBaseSnapshot(state, bs.baseId, bs.payload);
      case MessageKind.controlStream:
        final cs = message.controlStream!;
        out.addByte(MessageKind.controlStream.value);
        out.addByte(cs.codec.wireValue);
        _writeControlStreamPayload(cs.codec, cs.payload, out);
      default:
        throw invalidData('unsupported message kind');
    }
  }

  Message _readMessage(Reader reader) {
    return reader.withDepth(() => _readMessageInner(reader));
  }

  Message _readMessageInner(Reader reader) {
    final kindByte = reader.readU8();
    final (kind, ok) = MessageKind.fromByte(kindByte);
    if (!ok) throw invalidKind(kindByte);
    switch (kind) {
      case MessageKind.scalar:
        return Message(kind: kind, scalar: _readValue(reader));
      case MessageKind.array:
        final n = reader.readCount();
        return Message(
          kind: kind,
          array: List.generate(n, (_) => _readValue(reader)),
        );
      case MessageKind.map:
        final n = reader.readCount();
        final map = <MessageMapEntry>[];
        for (var i = 0; i < n; i++) {
          final keyRef = _readKeyRef(reader);
          map.add(MessageMapEntry(
            key: keyRef,
            value:
                _readValueWithField(reader, keyRefFieldIdentity(keyRef, state)),
          ));
        }
        final keys = map.map((e) => keyRefString(e.key, state)).toList();
        _observeDecodeShapeCandidate(keys);
        return Message(kind: kind, map: map);
      case MessageKind.shapedObject:
        final shapeId = reader.readCount(65535);
        final (presence, hasPresence) = _readPresence(reader);
        final n = reader.readCount();
        final values = <Value>[];
        final (keys, shapeOk) = state.shapeTable.getKeys(shapeId);
        if (shapeOk && keys != null) {
          var pres = presence;
          if (!hasPresence) {
            pres = List<bool>.filled(keys.length, true);
          }
          var readCount = 0;
          for (var i = 0; i < keys.length; i++) {
            if (i < pres.length && !pres[i]) continue;
            if (readCount >= n) break;
            values.add(_readValue(reader));
            readCount++;
          }
          while (readCount < n) {
            values.add(_readValue(reader));
            readCount++;
          }
        } else {
          for (var i = 0; i < n; i++) {
            values.add(_readValue(reader));
          }
        }
        return Message(
          kind: kind,
          shapedObject: ShapedObjectMessage(
            shapeId: shapeId,
            values: values,
            presence: presence,
            hasPresence: hasPresence,
          ),
        );
      case MessageKind.typedVector:
        return Message(
            kind: kind, typedVector: _readTypedVector(reader, null, null));
      case MessageKind.rowBatch:
        final rowCount = reader.readCount();
        final rows = <List<Value>>[];
        for (var i = 0; i < rowCount; i++) {
          final fieldCount = reader.readCount();
          rows.add(List.generate(fieldCount, (_) => _readValue(reader)));
        }
        return Message(kind: kind, rowBatch: RowBatchMessage(rows: rows));
      case MessageKind.columnBatch:
        final count = reader.readCount();
        final colCount = reader.readCount();
        final cols = List.generate(colCount, (_) => _readColumn(reader));
        return Message(
          kind: kind,
          columnBatch: ColumnBatchMessage(count: count, columns: cols),
        );
      case MessageKind.statePatch:
        final baseRef = _readBaseRef(reader);
        final n = reader.readCount();
        final ops = <PatchOperation>[];
        for (var i = 0; i < n; i++) {
          final fieldId = reader.readVaruint();
          final (opcode, opOk) = PatchOpcode.fromByte(reader.readU8());
          if (!opOk) throw invalidData('patch opcode');
          final hasValue = reader.readU8();
          ops.add(PatchOperation(
            fieldId: fieldId,
            opcode: opcode,
            value: hasValue == 1 ? _readValue(reader) : null,
          ));
        }
        final litN = reader.readCount();
        final lits = List.generate(litN, (_) => _readValue(reader));
        return Message(
          kind: kind,
          statePatch: StatePatchMessage(
            baseRef: baseRef,
            operations: ops,
            literals: lits,
          ),
        );
      case MessageKind.templateBatch:
        final templateId = reader.readVaruint();
        final count = reader.readCount();
        final mask = reader.readBitmap();
        final colN = reader.readCount();
        final changedCols = List.generate(colN, (_) => _readColumn(reader));
        var fullCols = changedCols;
        final prev = state.templateColumns[templateId];
        if (prev != null) {
          fullCols = mergeTemplateColumns(prev, mask, changedCols);
        } else {
          for (final bit in mask) {
            if (!bit) throw _referenceError('template_id', templateId);
          }
        }
        state.templateColumns[templateId] = fullCols;
        state.templates[templateId] =
            templateDescriptorFromColumns(templateId, fullCols);
        if (count >= 16) {
          state.previousMessage = Message(
            kind: MessageKind.columnBatch,
            columnBatch: ColumnBatchMessage(count: count, columns: fullCols),
          );
        }
        return Message(
          kind: kind,
          templateBatch: TemplateBatchMessage(
            templateId: templateId,
            count: count,
            changedColumnMask: mask,
            columns: changedCols,
          ),
        );
      case MessageKind.baseSnapshot:
        final baseId = reader.readVaruint();
        final ref = reader.readVaruint();
        final payload = _readMessage(reader);
        registerBaseSnapshot(state, baseId, payload);
        return Message(
          kind: kind,
          baseSnapshot: BaseSnapshotMessage(
            baseId: baseId,
            schemaOrShapeRef: ref,
            payload: payload,
          ),
        );
      case MessageKind.controlStream:
        final (codec, codecOk) =
            ControlStreamCodecWire.fromByte(reader.readU8());
        if (!codecOk) throw invalidData('control stream codec');
        final payload = _readControlStreamPayload(codec, reader);
        return Message(
          kind: kind,
          controlStream: ControlStreamMessage(codec: codec, payload: payload),
        );
      default:
        throw invalidData('unsupported message kind');
    }
  }

  void _writeValue(Value value, BytesBuilder out) {
    switch (value.kind) {
      case ValueKind.nullKind:
        out.addByte(_tagNull);
      case ValueKind.boolKind:
        out.addByte(value.boolValue ? _tagBoolTrue : _tagBoolFalse);
      case ValueKind.i64:
        out.addByte(_tagI64);
        writeSmallestU64(encodeZigzag(value.i64), out);
      case ValueKind.u64:
        out.addByte(_tagU64);
        writeSmallestU64(value.u64, out);
      case ValueKind.f64:
        out.addByte(_tagF64);
        appendF64Le(out, value.f64);
      case ValueKind.string:
        out.addByte(_tagString);
        out.addByte(1);
        encodeString(value.str, out);
        state.stringTable.register(value.str);
      case ValueKind.binary:
        out.addByte(_tagBinary);
        encodeBytes(value.bin, out);
      case ValueKind.array:
        out.addByte(_tagArray);
        encodeVaruint(value.arr.length, out);
        for (final v in value.arr) {
          _writeValue(v, out);
        }
      case ValueKind.map:
        out.addByte(_tagMap);
        encodeVaruint(value.map.length, out);
        for (final e in value.map) {
          _writeKeyRef(KeyRef.literalRef(e.key), out);
          _writeValue(e.value, out);
        }
    }
  }

  Value _readValue(Reader reader) => _readValueWithField(reader, null);

  Value _readValueWithField(Reader reader, String? fieldIdentity) {
    return reader
        .withDepth(() => _readValueWithFieldInner(reader, fieldIdentity));
  }

  Value _readValueWithFieldInner(Reader reader, String? fieldIdentity) {
    final tag = reader.readU8();
    switch (tag) {
      case _tagNull:
        return newNull();
      case _tagBoolFalse:
        return newBool(false);
      case _tagBoolTrue:
        return newBool(true);
      case _tagI64:
        final (v, _) = readSmallestU64(reader);
        return newI64(decodeZigzag(v));
      case _tagU64:
        final (v, _) = readSmallestU64(reader);
        return newU64(v);
      case _tagF64:
        return newF64(readF64Le(reader));
      case _tagString:
        return _readStringValue(reader, fieldIdentity);
      case _tagBinary:
        return newBinary(reader.readBytes());
      case _tagArray:
        final n = reader.readCount();
        return newArray(List.generate(n, (_) => _readValue(reader)));
      case _tagMap:
        final n = reader.readCount();
        final entries = <MapEntry>[];
        for (var i = 0; i < n; i++) {
          final keyRef = _readKeyRef(reader);
          final value = _readValueWithField(
            reader,
            keyRefFieldIdentity(keyRef, state),
          );
          entries.add(MapEntry(keyRefString(keyRef, state), value));
        }
        return newMap(entries);
      default:
        throw invalidTag(tag);
    }
  }

  Value _readStringValue(Reader reader, String? fieldIdentity) {
    final (mode, modeOk) = StringValue.fromByte(reader.readU8());
    if (!modeOk) throw invalidData('string mode');
    switch (mode) {
      case StringMode.empty:
        return newString('');
      case StringMode.literal:
        final s = reader.readString();
        state.stringTable.register(s);
        return newString(s);
      case StringMode.ref:
        final refId = reader.readVaruint();
        final (s, ok) = state.stringTable.getValue(refId);
        if (!ok) throw _referenceError('string_id', refId);
        return newString(s);
      case StringMode.prefixDelta:
        final baseId = reader.readVaruint();
        final prefixLen = reader.readCount();
        final suffix = reader.readString();
        final (base, ok) = state.stringTable.getValue(baseId);
        if (!ok) throw _referenceError('string_id', baseId);
        if (prefixLen > base.length) throw invalidData('prefix delta length');
        final s = '${base.substring(0, prefixLen)}$suffix';
        state.stringTable.register(s);
        return newString(s);
      case StringMode.inlineEnum:
        if (fieldIdentity == null) {
          throw invalidData('inline enum missing field identity');
        }
        final enumVals = state.fieldEnums[fieldIdentity];
        if (enumVals == null) throw invalidData('inline enum unknown field');
        final code = reader.readVaruint();
        if (code >= enumVals.length) throw invalidData('inline enum code');
        return newString(enumVals[code]);
    }
  }

  void _writeKeyRef(KeyRef key, BytesBuilder out) {
    if (key.isId) {
      out.addByte(1);
      encodeVaruint(key.id, out);
    } else {
      out.addByte(0);
      encodeString(key.literal, out);
      state.keyTable.register(key.literal);
    }
  }

  KeyRef _readKeyRef(Reader reader) {
    final mode = reader.readU8();
    if (mode == 1) {
      final refId = reader.readVaruint();
      final (key, ok) = state.keyTable.getValue(refId);
      if (!ok) throw _referenceError('key_id', refId);
      return KeyRef.literalRef(key);
    }
    final s = reader.readString();
    state.keyTable.register(s);
    return KeyRef.literalRef(s);
  }

  void _writeTypedVector(TypedVector tv, BytesBuilder out) {
    out.addByte(tv.elementType.value);
    encodeVaruint(typedVectorLen(tv.data), out);
    out.addByte(tv.codec.value);
    switch (tv.elementType) {
      case ElementType.boolType:
        encodeBitmap(tv.data.bools, out);
      case ElementType.i64:
        encodeI64Vector(tv.data.i64s, tv.codec, out);
      case ElementType.u64:
        encodeU64Vector(tv.data.u64s, tv.codec, out);
      case ElementType.f64:
        encodeF64Vector(tv.data.f64s, tv.codec, out);
      case ElementType.string:
        _writeStringVector(tv.data.strings, tv.codec, out);
      case ElementType.binary:
        encodeVaruint(tv.data.binary.length, out);
        for (final b in tv.data.binary) {
          encodeBytes(b, out);
        }
      case ElementType.anyValue:
        encodeVaruint(tv.data.values.length, out);
        for (final v in tv.data.values) {
          _writeValue(v, out);
        }
    }
  }

  TypedVector _readTypedVector(Reader reader,
      [ElementType? forced, VectorCodec? expectedCodec]) {
    final (elemType, elemOk) =
        forced != null ? (forced, true) : ElementType.fromByte(reader.readU8());
    if (!elemOk) throw invalidData('vector element type');
    final expectedLen = reader.readCount();
    final (codec, codecOk) = VectorCodec.fromByte(reader.readU8());
    if (!codecOk) throw invalidData('vector codec');
    if (expectedCodec != null && codec != expectedCodec) {
      throw invalidData('column codec mismatch');
    }
    TypedVectorData data;
    switch (elemType) {
      case ElementType.boolType:
        final bools = reader.readBitmap();
        if (bools.length != expectedLen)
          throw invalidData('typed vector length mismatch');
        data = typedDataBool(bools);
      case ElementType.i64:
        final i64s = decodeI64Vector(reader, codec);
        if (i64s.length != expectedLen)
          throw invalidData('typed vector length mismatch');
        data = typedDataI64(i64s);
      case ElementType.u64:
        final u64s = decodeU64Vector(reader, codec);
        if (u64s.length != expectedLen)
          throw invalidData('typed vector length mismatch');
        data = typedDataU64(u64s);
      case ElementType.f64:
        final f64s = decodeF64Vector(reader, codec);
        if (f64s.length != expectedLen)
          throw invalidData('typed vector length mismatch');
        data = typedDataF64(f64s);
      case ElementType.string:
        final strings = _readStringVector(reader, codec);
        if (strings.length != expectedLen)
          throw invalidData('typed vector length mismatch');
        data = typedDataString(strings);
      case ElementType.binary:
        final n = reader.readCount();
        final binary = List.generate(n, (_) => reader.readBytes());
        data = TypedVectorData(kind: ElementType.binary, binary: binary);
      case ElementType.anyValue:
        final n = reader.readCount();
        final values = List.generate(n, (_) => _readValue(reader));
        data = TypedVectorData(kind: ElementType.anyValue, values: values);
    }
    return TypedVector(elementType: elemType, codec: codec, data: data);
  }

  void _writeStringVector(
      List<String> values, VectorCodec codec, BytesBuilder out) {
    switch (codec) {
      case VectorCodec.dictionary:
        final dict = <String, int>{};
        final uniq = <String>[];
        final refs = List<int>.filled(values.length, 0);
        for (var i = 0; i < values.length; i++) {
          final v = values[i];
          var id = dict[v];
          if (id == null) {
            id = uniq.length;
            dict[v] = id;
            uniq.add(v);
          }
          refs[i] = id;
        }
        encodeVaruint(uniq.length, out);
        for (final s in uniq) {
          encodeString(s, out);
        }
        encodeU64Vector(refs, VectorCodec.directBitpack, out);
      case VectorCodec.stringRef:
        encodeVaruint(values.length, out);
        for (final v in values) {
          final (id, ok) = state.stringTable.getId(v);
          if (ok) {
            encodeVaruint(id, out);
          } else {
            encodeVaruint(state.stringTable.register(v), out);
          }
        }
      case VectorCodec.prefixDelta:
        encodeVaruint(values.length, out);
        var prev = '';
        for (final v in values) {
          final prefix = commonPrefixLen(prev, v);
          encodeVaruint(prefix, out);
          encodeString(v.substring(prefix), out);
          prev = v;
        }
      default:
        encodeVaruint(values.length, out);
        for (final v in values) {
          encodeString(v, out);
        }
    }
  }

  List<String> _readStringVector(Reader reader, VectorCodec codec) {
    switch (codec) {
      case VectorCodec.dictionary:
        final dictN = reader.readCount();
        final dict = List<String>.generate(dictN, (_) => reader.readString());
        final refs = decodeU64Vector(reader, VectorCodec.directBitpack);
        return refs.map((ref) {
          if (ref >= dict.length) throw invalidData('dictionary reference');
          return dict[ref];
        }).toList();
      case VectorCodec.stringRef:
        final n = reader.readCount();
        return List.generate(n, (_) {
          final id = reader.readVaruint();
          final (s, ok) = state.stringTable.getValue(id);
          if (!ok) throw _referenceError('string_id', id);
          return s;
        });
      case VectorCodec.prefixDelta:
        final n = reader.readCount();
        final out = <String>[];
        var prev = '';
        for (var i = 0; i < n; i++) {
          final prefix = reader.readVaruint();
          final suffix = reader.readString();
          final s =
              prev.substring(0, prefix < prev.length ? prefix : prev.length) +
                  suffix;
          out.add(s);
          prev = s;
        }
        return out;
      default:
        final n = reader.readCount();
        return List.generate(n, (_) => reader.readString());
    }
  }

  void _writeColumn(Column column, BytesBuilder out) {
    encodeVaruint(column.fieldId, out);
    out.addByte(column.nullStrategy.value);
    if (column.nullStrategy == NullStrategy.presenceBitmap ||
        column.nullStrategy == NullStrategy.invertedPresenceBitmap) {
      if (!column.hasPresence)
        throw invalidData('missing column presence bitmap');
      encodeBitmap(column.presence, out);
    }
    out.addByte(column.codec.value);
    out.addByte(0); // dictionary_id always 0 (simplified)
    out.addByte(0); // trained block absent
    final tv = TypedVector(
      elementType: column.values.kind,
      codec: column.codec,
      data: column.values,
    );
    _writeTypedVector(tv, out);
  }

  Column _readColumn(Reader reader) {
    final fieldId = reader.readVaruint();
    final (nullStrategy, nsOk) = NullStrategy.fromByte(reader.readU8());
    if (!nsOk) throw invalidData('null strategy');
    var presence = <bool>[];
    var hasPresence = false;
    if (nullStrategy == NullStrategy.presenceBitmap ||
        nullStrategy == NullStrategy.invertedPresenceBitmap) {
      presence = reader.readBitmap();
      hasPresence = true;
    }
    final (codec, codecOk) = VectorCodec.fromByte(reader.readU8());
    if (!codecOk) throw invalidData('column codec');
    final hasDict = reader.readU8();
    if (hasDict != 0) {
      reader.readVaruint(); // dict id
      final hasProfile = reader.readU8();
      if (hasProfile == 1) {
        reader.readVaruint();
        reader.readVaruint();
        reader.readVaruint();
        reader.readU8();
        reader.readBytes();
      }
    }
    final payloadMode = reader.readU8();
    if (payloadMode != 0)
      throw invalidData('trained dictionary block not supported');
    final values = _readTypedVector(reader, null, codec).data;
    return Column(
      fieldId: fieldId,
      nullStrategy: nullStrategy,
      presence: presence,
      hasPresence: hasPresence,
      codec: codec,
      values: values,
    );
  }

  void _writeBaseRef(BaseRef baseRef, BytesBuilder out) {
    if (baseRef.previous) {
      out.addByte(0);
    } else {
      out.addByte(1);
      encodeVaruint(baseRef.baseId, out);
    }
  }

  BaseRef _readBaseRef(Reader reader) {
    final mode = reader.readU8();
    switch (mode) {
      case 0:
        return BaseRef.previousRef();
      case 1:
        return BaseRef.idRef(reader.readVaruint());
      default:
        throw invalidData('base ref');
    }
  }

  Message _applyStatePatch(
    BaseRef baseRef,
    List<PatchOperation> operations,
    List<Value> literals,
  ) {
    Message base;
    if (baseRef.previous) {
      if (state.previousMessage == null) throw _referenceError('previous', 0);
      base = state.previousMessage!.cloneMessage();
    } else {
      final (_, snap) = getBaseSnapshot(state, baseRef.baseId);
      if (snap == null) throw _referenceError('base_id', baseRef.baseId);
      base = snap.cloneMessage();
    }
    final fields = messageFields(base);
    for (final operation in operations) {
      final idx = operation.fieldId;
      switch (operation.opcode) {
        case PatchOpcode.keep:
          break;
        case PatchOpcode.replaceScalar:
        case PatchOpcode.replaceVector:
        case PatchOpcode.insertField:
        case PatchOpcode.stringRef:
        case PatchOpcode.prefixDelta:
          if (operation.value == null)
            throw invalidData('patch operation missing value');
          if (idx < fields.length) {
            fields[idx] = operation.value!.clone();
          } else if (idx == fields.length) {
            fields.add(operation.value!.clone());
          } else {
            throw invalidData('patch field index out of range');
          }
        case PatchOpcode.deleteField:
          if (idx < 0 || idx >= fields.length) {
            throw invalidData('delete field index out of range');
          }
          fields.removeAt(idx);
        case PatchOpcode.appendVector:
          if (operation.value == null ||
              idx < 0 ||
              idx >= fields.length ||
              fields[idx].kind != ValueKind.array ||
              operation.value!.kind != ValueKind.array) {
            throw invalidData('append vector patch invalid');
          }
          fields[idx].arr.addAll(
                operation.value!.arr.map((v) => v.clone()),
              );
        case PatchOpcode.truncateVector:
          if (operation.value == null ||
              idx < 0 ||
              idx >= fields.length ||
              fields[idx].kind != ValueKind.array ||
              operation.value!.kind != ValueKind.u64) {
            throw invalidData('truncate vector patch invalid');
          }
          final n = operation.value!.u64;
          if (n > fields[idx].arr.length) throw invalidData('truncate length');
          fields[idx].arr = fields[idx].arr.sublist(0, n);
      }
    }
    return rebuildMessageLike(base, fields);
  }

  Message messageForValue(Value value) => _messageForValue(value);

  void _writeControlStreamPayload(
    ControlStreamCodec codec,
    Uint8List payload,
    BytesBuilder out,
  ) {
    final Uint8List encoded;
    switch (codec) {
      case ControlStreamCodec.plain:
        encoded = payload;
      case ControlStreamCodec.rle:
        encoded = rleEncodeBytes(payload);
      case ControlStreamCodec.bitpack:
        encoded = controlBitpackEncodeBytes(payload);
      case ControlStreamCodec.huffman:
        encoded = controlHuffmanEncodeBytes(payload);
      case ControlStreamCodec.fse:
        encoded = controlFseEncodeBytes(payload);
    }
    encodeBytes(encoded, out);
  }

  Uint8List _readControlStreamPayload(ControlStreamCodec codec, Reader reader) {
    final encoded = reader.readBytes();
    switch (codec) {
      case ControlStreamCodec.plain:
        return encoded;
      case ControlStreamCodec.rle:
        return rleDecodeBytes(encoded);
      case ControlStreamCodec.bitpack:
        return controlBitpackDecodeBytes(encoded);
      case ControlStreamCodec.huffman:
        return controlHuffmanDecodeBytes(encoded);
      case ControlStreamCodec.fse:
        return controlFseDecodeBytes(encoded);
    }
  }
}

class SessionEncoder {
  SessionEncoder([SessionOptions? options])
      : codec = TwilicCodec(
          options != null ? newSessionStateWithOptions(options) : null,
        );

  final TwilicCodec codec;

  Uint8List encode(Value value) => codec.encodeValue(value);

  Uint8List encodeWithSchema(Schema schema, Value value) {
    if (value.kind != ValueKind.map) {
      throw invalidData('encode_with_schema expects map value');
    }
    final fields = <Value>[];
    for (final f in schema.fields) {
      Value? found;
      for (final e in value.map) {
        if (e.key == f.name) {
          found = e.value.clone();
          break;
        }
      }
      fields.add(found ?? newNull());
    }
    final msg = Message(
      kind: MessageKind.schemaObject,
      schemaObject:
          SchemaObjectMessage(schemaId: schema.schemaId, fields: fields),
    );
    return codec.encodeMessage(msg);
  }

  Uint8List encodeBatch(List<Value> values) {
    if (values.isEmpty) {
      final msg = Message(
        kind: MessageKind.rowBatch,
        rowBatch: RowBatchMessage(rows: []),
      );
      return codec.encodeMessage(msg);
    }
    Message msg;
    if (values.length >= 16) {
      var cols = columnsFromMapValues(values);
      cols ??= rowsToColumns(rowsFromValues(values));
      msg = Message(
        kind: MessageKind.columnBatch,
        columnBatch: ColumnBatchMessage(count: values.length, columns: cols!),
      );
    } else {
      msg = Message(
        kind: MessageKind.rowBatch,
        rowBatch: RowBatchMessage(
          rows: rowsFromValues(values)
              .map((r) => r.map((v) => v.clone()).toList())
              .toList(),
        ),
      );
    }
    final data = codec.encodeMessage(msg);
    codec.state.previousMessage = msg.cloneMessage();
    codec.state.previousMessageSize = data.length;
    _recordFullMessageAsBase();
    return data;
  }

  Uint8List encodePatch(Value value) {
    final msg = codec.messageForValue(value);
    if (codec.state.previousMessage == null ||
        !supportsStatePatch(codec.state.previousMessage, msg)) {
      return codec.encodeMessage(msg);
    }
    final (ops, _) = diffMessage(codec.state.previousMessage!, msg);
    final patchMsg = Message(
      kind: MessageKind.statePatch,
      statePatch: StatePatchMessage(
        baseRef: baseRefPrevious(),
        operations: ops,
      ),
    );
    if (encodedSize(patchMsg) >= encodedSize(msg)) {
      return codec.encodeMessage(msg);
    }
    return codec.encodeMessage(patchMsg);
  }

  Uint8List encodeMicroBatch(List<Value> values) {
    if (values.isEmpty) return encodeBatch(values);
    if (!codec.state.options.enableTemplateBatch ||
        !hasUniformMicroBatchShape(values)) {
      return encodeBatch(values);
    }
    var columns = columnsFromMapValues(values);
    columns ??= rowsToColumns(rowsFromValues(values));
    final (templateId, ok) = findTemplateId(codec.state.templates, columns!);
    if (!ok) {
      final newId = allocateTemplateId(codec.state);
      codec.state.templates[newId] =
          templateDescriptorFromColumns(newId, columns!);
      codec.state.templateColumns[newId] = columns!;
      final mask = List<bool>.filled(columns.length, true);
      final msg = Message(
        kind: MessageKind.templateBatch,
        templateBatch: TemplateBatchMessage(
          templateId: newId,
          count: values.length,
          changedColumnMask: mask,
          columns: columns,
        ),
      );
      return codec.encodeMessage(msg);
    }
    final (mask, changedCols) =
        diffTemplateColumns(codec.state.templateColumns[templateId]!, columns!);
    codec.state.templateColumns[templateId] = columns!;
    final msg = Message(
      kind: MessageKind.templateBatch,
      templateBatch: TemplateBatchMessage(
        templateId: templateId,
        count: values.length,
        changedColumnMask: mask,
        columns: changedCols,
      ),
    );
    return codec.encodeMessage(msg);
  }

  void _recordFullMessageAsBase() {
    if (codec.state.options.maxBaseSnapshots == 0) return;
    if (codec.state.previousMessage == null) return;
    final baseId = allocateBaseId(codec.state);
    registerBaseSnapshot(codec.state, baseId, codec.state.previousMessage!);
  }
}

TwilicCodec newTwilicCodec() => TwilicCodec();
TwilicCodec twilicCodecWithOptions(SessionOptions options) =>
    TwilicCodec(newSessionStateWithOptions(options));
SessionEncoder newSessionEncoder([SessionOptions? options]) =>
    SessionEncoder(options);

void resetEncodeShapeObservation(TwilicCodec codec, List<String> keys) {
  codec.state.encodeShapeObservations.remove(shapeKey(keys));
}

extension on Message {
  Message cloneMessage() {
    switch (kind) {
      case MessageKind.scalar:
        return Message(kind: kind, scalar: scalar?.clone());
      case MessageKind.array:
        return Message(
          kind: kind,
          array: array.map((v) => v.clone()).toList(),
        );
      case MessageKind.map:
        return Message(
          kind: kind,
          map: map
              .map(
                (e) => MessageMapEntry(
                  key: KeyRef(
                    literal: e.key.literal,
                    id: e.key.id,
                    isId: e.key.isId,
                  ),
                  value: e.value.clone(),
                ),
              )
              .toList(),
        );
      case MessageKind.shapedObject:
        final so = shapedObject!;
        return Message(
          kind: kind,
          shapedObject: ShapedObjectMessage(
            shapeId: so.shapeId,
            values: so.values.map((v) => v.clone()).toList(),
            presence: List<bool>.from(so.presence),
            hasPresence: so.hasPresence,
          ),
        );
      case MessageKind.schemaObject:
        final so = schemaObject!;
        return Message(
          kind: kind,
          schemaObject: SchemaObjectMessage(
            schemaId: so.schemaId,
            fields: so.fields.map((v) => v.clone()).toList(),
          ),
        );
      case MessageKind.typedVector:
        final tv = typedVector!;
        return Message(
          kind: kind,
          typedVector: TypedVector(
            elementType: tv.elementType,
            codec: tv.codec,
            data: TypedVectorData(
              kind: tv.data.kind,
              bools: List<bool>.from(tv.data.bools),
              u64s: List<int>.from(tv.data.u64s),
              i64s: List<int>.from(tv.data.i64s),
            ),
          ),
        );
      case MessageKind.rowBatch:
        return Message(
          kind: kind,
          rowBatch: RowBatchMessage(
            rows: rowBatch!.rows
                .map((r) => r.map((v) => v.clone()).toList())
                .toList(),
          ),
        );
      case MessageKind.columnBatch:
        final cb = columnBatch!;
        return Message(
          kind: kind,
          columnBatch: ColumnBatchMessage(
            count: cb.count,
            columns: cb.columns
                .map(
                  (c) => Column(
                    fieldId: c.fieldId,
                    nullStrategy: c.nullStrategy,
                    presence: List<bool>.from(c.presence),
                    hasPresence: c.hasPresence,
                    codec: c.codec,
                    values: TypedVectorData(
                      kind: c.values.kind,
                      bools: List<bool>.from(c.values.bools),
                      i64s: List<int>.from(c.values.i64s),
                      u64s: List<int>.from(c.values.u64s),
                      f64s: List<double>.from(c.values.f64s),
                      strings: List<String>.from(c.values.strings),
                      values: c.values.values.map((v) => v.clone()).toList(),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      case MessageKind.statePatch:
        final sp = statePatch!;
        return Message(
          kind: kind,
          statePatch: StatePatchMessage(
            baseRef: BaseRef(
              previous: sp.baseRef.previous,
              baseId: sp.baseRef.baseId,
            ),
            operations: sp.operations
                .map(
                  (op) => PatchOperation(
                    fieldId: op.fieldId,
                    opcode: op.opcode,
                    value: op.value?.clone(),
                  ),
                )
                .toList(),
            literals: sp.literals.map((v) => v.clone()).toList(),
          ),
        );
      case MessageKind.templateBatch:
        final tb = templateBatch!;
        return Message(
          kind: kind,
          templateBatch: TemplateBatchMessage(
            templateId: tb.templateId,
            count: tb.count,
            changedColumnMask: List<bool>.from(tb.changedColumnMask),
            columns: tb.columns
                .map(
                  (c) => Column(
                    fieldId: c.fieldId,
                    nullStrategy: c.nullStrategy,
                    presence: List<bool>.from(c.presence),
                    hasPresence: c.hasPresence,
                    codec: c.codec,
                    values: TypedVectorData(
                      kind: c.values.kind,
                      bools: List<bool>.from(c.values.bools),
                      i64s: List<int>.from(c.values.i64s),
                      u64s: List<int>.from(c.values.u64s),
                      f64s: List<double>.from(c.values.f64s),
                      strings: List<String>.from(c.values.strings),
                      values: c.values.values.map((v) => v.clone()).toList(),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      case MessageKind.baseSnapshot:
        final bs = baseSnapshot!;
        return Message(
          kind: kind,
          baseSnapshot: BaseSnapshotMessage(
            baseId: bs.baseId,
            schemaOrShapeRef: bs.schemaOrShapeRef,
            payload: bs.payload.cloneMessage(),
          ),
        );
      case MessageKind.controlStream:
        final cs = controlStream!;
        return Message(
          kind: kind,
          controlStream: ControlStreamMessage(
            codec: cs.codec,
            payload: Uint8List.fromList(cs.payload),
          ),
        );
      default:
        return Message(kind: kind);
    }
  }
}
