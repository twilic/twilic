import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'model.dart';
import 'session.dart' show shapeKey;
import 'wire.dart';

const _nullTag = 0xC0;
const _falseTag = 0xC1;
const _trueTag = 0xC2;
const _f64Tag = 0xC3;
const _u8Tag = 0xC4;
const _u16Tag = 0xC5;
const _u32Tag = 0xC6;
const _u64Tag = 0xC7;
const _i8Tag = 0xC8;
const _i16Tag = 0xC9;
const _i32Tag = 0xCA;
const _i64Tag = 0xCB;
const _bin8Tag = 0xCC;
const _bin16Tag = 0xCD;
const _bin32Tag = 0xCE;
const _str8Tag = 0xCF;
const _str16Tag = 0xD0;
const _str32Tag = 0xD1;
const _array16Tag = 0xD2;
const _array32Tag = 0xD3;
const _map16Tag = 0xD4;
const _map32Tag = 0xD5;
const _shapeDefTag = 0xD6;
const _keyRefTag = 0xD8;
const _strRefTag = 0xD9;

class _V2EncodeState {
  final keyIds = <String, int>{};
  final strIds = <String, int>{};
  final shapeIds = <String, int>{};
  int nextKeyId = 0;
  int nextStrId = 0;
  int nextShapeId = 0;
}

class _V2DecodeState {
  final keys = <String>[];
  final strings = <String>[];
  final shapes = <List<String>?>[];
}

Uint8List encodeV2(Value value) {
  final out = BytesBuilder();
  final state = _V2EncodeState();
  _encodeV2Value(value, out, state);
  return out.toBytes();
}

Value decodeV2(Uint8List data) {
  final reader = newReader(data);
  final state = _V2DecodeState();
  final value = _decodeV2Value(reader, state);
  if (!reader.isEof) throw invalidData('trailing bytes in v2 decode');
  return value;
}

void _encodeV2Value(Value value, BytesBuilder out, _V2EncodeState state) {
  switch (value.kind) {
    case ValueKind.nullKind:
      out.addByte(_nullTag);
    case ValueKind.boolKind:
      out.addByte(value.boolValue ? _trueTag : _falseTag);
    case ValueKind.i64:
      _encodeV2I64(value.i64, out);
    case ValueKind.u64:
      _encodeV2U64(value.u64, out);
    case ValueKind.f64:
      out.addByte(_f64Tag);
      appendF64Le(out, value.f64);
    case ValueKind.string:
      final refId = state.strIds[value.str];
      if (refId != null) {
        out.addByte(_strRefTag);
        encodeVaruint(refId, out);
      } else {
        _encodeV2StringLiteral(value.str, out);
        state.strIds[value.str] = state.nextStrId++;
      }
    case ValueKind.binary:
      _encodeV2Binary(value.bin, out);
    case ValueKind.array:
      _encodeV2Array(value.arr, out, state);
    case ValueKind.map:
      _encodeV2Map(value.map, out, state);
  }
}

void _encodeV2Array(
    List<Value> values, BytesBuilder out, _V2EncodeState state) {
  final shapeKeys = _detectShapeKeys(values);
  if (shapeKeys != null) {
    final sk = shapeKey(shapeKeys);
    var shapeId = state.shapeIds[sk];
    if (shapeId == null) {
      shapeId = state.nextShapeId++;
      state.shapeIds[sk] = shapeId;
    }
    _writeV2ArrayHeader(values.length, out);
    out.addByte(_shapeDefTag);
    encodeVaruint(shapeId, out);
    encodeVaruint(shapeKeys.length, out);
    for (final key in shapeKeys) {
      _encodeV2Key(key, out, state);
    }
    for (final value in values) {
      if (value.kind != ValueKind.map) {
        throw invalidData('shape array row must be map');
      }
      for (final field in value.map) {
        _encodeV2Value(field.value, out, state);
      }
    }
    return;
  }
  _writeV2ArrayHeader(values.length, out);
  for (final value in values) {
    _encodeV2Value(value, out, state);
  }
}

void _encodeV2Map(
    List<MapEntry> entries, BytesBuilder out, _V2EncodeState state) {
  _writeV2MapHeader(entries.length, out);
  for (final e in entries) {
    _encodeV2Key(e.key, out, state);
    _encodeV2Value(e.value, out, state);
  }
}

void _encodeV2Key(String key, BytesBuilder out, _V2EncodeState state) {
  final refId = state.keyIds[key];
  if (refId != null) {
    out.addByte(_keyRefTag);
    encodeVaruint(refId, out);
    return;
  }
  _encodeV2StringLiteral(key, out);
  state.keyIds[key] = state.nextKeyId++;
}

void _encodeV2StringLiteral(String value, BytesBuilder out) {
  final raw = utf8.encode(value);
  final length = raw.length;
  if (length <= 31) {
    out.addByte(0x80 | length);
  } else if (length <= 0xFF) {
    out.addByte(_str8Tag);
    out.addByte(length);
  } else if (length <= 0xFFFF) {
    out.addByte(_str16Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
  } else {
    out.addByte(_str32Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
    out.addByte((length >> 16) & 0xFF);
    out.addByte((length >> 24) & 0xFF);
  }
  out.add(raw);
}

void _encodeV2Binary(Uint8List value, BytesBuilder out) {
  final length = value.length;
  if (length <= 0xFF) {
    out.addByte(_bin8Tag);
    out.addByte(length);
  } else if (length <= 0xFFFF) {
    out.addByte(_bin16Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
  } else {
    out.addByte(_bin32Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
    out.addByte((length >> 16) & 0xFF);
    out.addByte((length >> 24) & 0xFF);
  }
  out.add(value);
}

void _encodeV2U64(int value, BytesBuilder out) {
  if (value <= 127) {
    out.addByte(value);
  } else if (value <= 0xFF) {
    out.addByte(_u8Tag);
    out.addByte(value);
  } else if (value <= 0xFFFF) {
    out.addByte(_u16Tag);
    out.addByte(value & 0xFF);
    out.addByte((value >> 8) & 0xFF);
  } else if (value <= 0xFFFFFFFF) {
    out.addByte(_u32Tag);
    out.addByte(value & 0xFF);
    out.addByte((value >> 8) & 0xFF);
    out.addByte((value >> 16) & 0xFF);
    out.addByte((value >> 24) & 0xFF);
  } else {
    out.addByte(_u64Tag);
    appendU64Le(out, value);
  }
}

void _encodeV2I64(int value, BytesBuilder out) {
  if (value >= -32 && value <= -1) {
    out.addByte(value & 0xFF);
  } else if (value >= 0 && value <= 127) {
    out.addByte(value);
  } else if (value >= -128 && value <= 127) {
    out.addByte(_i8Tag);
    out.addByte(value & 0xFF);
  } else if (value >= -32768 && value <= 32767) {
    out.addByte(_i16Tag);
    out.addByte(value & 0xFF);
    out.addByte((value >> 8) & 0xFF);
  } else if (value >= -2147483648 && value <= 2147483647) {
    out.addByte(_i32Tag);
    out.addByte(value & 0xFF);
    out.addByte((value >> 8) & 0xFF);
    out.addByte((value >> 16) & 0xFF);
    out.addByte((value >> 24) & 0xFF);
  } else {
    out.addByte(_i64Tag);
    appendU64Le(out, value);
  }
}

void _writeV2ArrayHeader(int length, BytesBuilder out) {
  if (length <= 15) {
    out.addByte(0xA0 | length);
  } else if (length <= 0xFFFF) {
    out.addByte(_array16Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
  } else {
    out.addByte(_array32Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
    out.addByte((length >> 16) & 0xFF);
    out.addByte((length >> 24) & 0xFF);
  }
}

void _writeV2MapHeader(int length, BytesBuilder out) {
  if (length <= 15) {
    out.addByte(0xB0 | length);
  } else if (length <= 0xFFFF) {
    out.addByte(_map16Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
  } else {
    out.addByte(_map32Tag);
    out.addByte(length & 0xFF);
    out.addByte((length >> 8) & 0xFF);
    out.addByte((length >> 16) & 0xFF);
    out.addByte((length >> 24) & 0xFF);
  }
}

List<String>? _detectShapeKeys(List<Value> values) {
  if (values.length < 2) return null;
  if (values[0].kind != ValueKind.map || values[0].map.isEmpty) return null;
  final keys = values[0].map.map((e) => e.key).toList();
  for (var i = 1; i < values.length; i++) {
    final value = values[i];
    if (value.kind != ValueKind.map || value.map.length != keys.length)
      return null;
    for (var j = 0; j < keys.length; j++) {
      if (value.map[j].key != keys[j]) return null;
    }
  }
  return keys;
}

Value _decodeV2Value(Reader reader, _V2DecodeState state) {
  final tag = reader.readU8();
  return _decodeV2ValueFromTag(reader, state, tag);
}

Value _decodeV2ValueFromTag(Reader reader, _V2DecodeState state, int tag) {
  if (tag <= 0x7F) return newU64(tag);
  if (tag >= 0x80 && tag <= 0x9F) {
    final length = tag & 0x1F;
    final s = utf8.decode(reader.readExact(length));
    state.strings.add(s);
    return newString(s);
  }
  if (tag >= 0xA0 && tag <= 0xAF) {
    return _decodeV2ArrayBody(reader, state, tag & 0x0F);
  }
  if (tag >= 0xB0 && tag <= 0xBF) {
    return _decodeV2MapBody(reader, state, tag & 0x0F);
  }
  if (tag >= 0xE0) return newI64(tag < 128 ? tag : tag - 256);
  switch (tag) {
    case _nullTag:
      return newNull();
    case _falseTag:
      return newBool(false);
    case _trueTag:
      return newBool(true);
    case _f64Tag:
      return newF64(readF64Le(reader));
    case _u8Tag:
      return newU64(reader.readU8());
    case _u16Tag:
      final b = reader.readExact(2);
      return newU64(b[0] | (b[1] << 8));
    case _u32Tag:
      final b = reader.readExact(4);
      return newU64(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24));
    case _u64Tag:
      return newU64(readU64Le(reader));
    case _i8Tag:
      final b = reader.readU8();
      return newI64(b < 128 ? b : b - 256);
    case _i16Tag:
      final b = reader.readExact(2);
      final bd = ByteData.sublistView(b);
      return newI64(bd.getInt16(0, Endian.little));
    case _i32Tag:
      final b = reader.readExact(4);
      final bd = ByteData.sublistView(b);
      return newI64(bd.getInt32(0, Endian.little));
    case _i64Tag:
      final b = reader.readExact(8);
      final bd = ByteData.sublistView(b);
      return newI64(bd.getInt64(0, Endian.little));
    case _bin8Tag:
      return newBinary(reader.readExact(reader.readU8()));
    case _bin16Tag:
      final b = reader.readExact(2);
      return newBinary(reader.readExact(b[0] | (b[1] << 8)));
    case _bin32Tag:
      final b = reader.readExact(4);
      final n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
      return newBinary(reader.readExact(n));
    case _str8Tag:
    case _str16Tag:
    case _str32Tag:
      return _decodeV2StringTag(reader, state, tag);
    case _array16Tag:
      final b = reader.readExact(2);
      return _decodeV2ArrayBody(reader, state, b[0] | (b[1] << 8));
    case _array32Tag:
      final b = reader.readExact(4);
      final n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
      return _decodeV2ArrayBody(reader, state, n);
    case _map16Tag:
      final b = reader.readExact(2);
      return _decodeV2MapBody(reader, state, b[0] | (b[1] << 8));
    case _map32Tag:
      final b = reader.readExact(4);
      final n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
      return _decodeV2MapBody(reader, state, n);
    case _strRefTag:
      final refId = reader.readVaruint();
      if (refId >= state.strings.length)
        throw invalidData('unknown str_ref id');
      return newString(state.strings[refId]);
    default:
      throw invalidTag(tag);
  }
}

Value _decodeV2StringTag(Reader reader, _V2DecodeState state, int tag) {
  late final int length;
  if (tag == _str8Tag) {
    length = reader.readU8();
  } else if (tag == _str16Tag) {
    final b = reader.readExact(2);
    length = b[0] | (b[1] << 8);
  } else {
    final b = reader.readExact(4);
    length = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }
  final s = utf8.decode(reader.readExact(length));
  state.strings.add(s);
  return newString(s);
}

Value _decodeV2ArrayBody(Reader reader, _V2DecodeState state, int length) {
  reader.claimOutput(length);
  return reader.withDepth(() => _decodeV2ArrayBodyInner(reader, state, length));
}

Value _decodeV2ArrayBodyInner(Reader reader, _V2DecodeState state, int length) {
  if (length == 0) return newArray([]);
  final firstTag = reader.readU8();
  if (firstTag == _shapeDefTag) {
    final shapeId = reader.readCount(65535);
    final keyCount = reader.readCount(256);
    final keys = <String>[];
    for (var i = 0; i < keyCount; i++) {
      keys.add(_decodeV2Key(reader, state));
    }
    while (state.shapes.length <= shapeId) {
      state.shapes.add(null);
    }
    state.shapes[shapeId] = keys;
    final values = <Value>[];
    for (var i = 0; i < length; i++) {
      reader.claimOutput(keys.length);
      final row = <MapEntry>[];
      for (final key in keys) {
        row.add(MapEntry(key, _decodeV2Value(reader, state)));
      }
      values.add(newMap(row));
    }
    return newArray(values);
  }
  final values = <Value>[_decodeV2ValueFromTag(reader, state, firstTag)];
  for (var i = 1; i < length; i++) {
    values.add(_decodeV2Value(reader, state));
  }
  return newArray(values);
}

Value _decodeV2MapBody(Reader reader, _V2DecodeState state, int length) {
  reader.claimOutput(length);
  return reader.withDepth(() => _decodeV2MapBodyInner(reader, state, length));
}

Value _decodeV2MapBodyInner(Reader reader, _V2DecodeState state, int length) {
  final entries = <MapEntry>[];
  for (var i = 0; i < length; i++) {
    entries.add(
        MapEntry(_decodeV2Key(reader, state), _decodeV2Value(reader, state)));
  }
  return newMap(entries);
}

String _decodeV2Key(Reader reader, _V2DecodeState state) {
  final tag = reader.readU8();
  if (tag == _keyRefTag) {
    final refId = reader.readVaruint();
    if (refId >= state.keys.length) throw invalidData('unknown key_ref id');
    return state.keys[refId];
  }
  if (tag >= 0x80 && tag <= 0x9F) {
    final key = utf8.decode(reader.readExact(tag & 0x1F));
    state.keys.add(key);
    return key;
  }
  if (tag == _str8Tag || tag == _str16Tag || tag == _str32Tag) {
    final v = _decodeV2ValueFromTag(reader, state, tag);
    if (v.kind != ValueKind.string) throw invalidData('expected string key');
    state.keys.add(v.str);
    return v.str;
  }
  throw invalidData('map key must be key_ref or string');
}
