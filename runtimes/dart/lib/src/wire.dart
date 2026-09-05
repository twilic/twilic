// Generated-style native port from twilic-python wire.py
import 'dart:convert';
import 'dart:typed_data';
import 'errors.dart';

void encodeVaruint(int value, BytesBuilder out) {
  if (value < 0x80) {
    out.addByte(value);
    return;
  }
  while (true) {
    var b = value & 0x7F;
    value >>= 7;
    if (value != 0) b |= 0x80;
    out.addByte(b);
    if (value == 0) break;
  }
}

int encodeZigzag(int value) => (value << 1) ^ (value >> 63);

int decodeZigzag(int value) {
  final v = (value >> 1) ^ (-(value & 1));
  return v;
}

void encodeBytes(Uint8List data, BytesBuilder out) {
  encodeVaruint(data.length, out);
  out.add(data);
}

void encodeString(String value, BytesBuilder out) {
  encodeBytes(Uint8List.fromList(utf8.encode(value)), out);
}

void encodeBitmap(List<bool> bits, BytesBuilder out) {
  encodeVaruint(bits.length, out);
  var current = 0;
  for (var i = 0; i < bits.length; i++) {
    if (bits[i]) current |= 1 << (i % 8);
    if (i % 8 == 7) {
      out.addByte(current);
      current = 0;
    }
  }
  if (bits.length % 8 != 0) out.addByte(current);
}

class Reader {
  Reader(this._input)
      : _budget = (_input.length < 1024 ? _input.length : 1024) * 1024;
  final Uint8List _input;
  int _offset = 0;
  int _depth = 0;
  int _budget;

  void claimOutput(int count) {
    if (count < 0 || count > 1 << 20)
      throw invalidData('decode count limit exceeded');
    if (count > _budget ~/ 8) throw invalidData('decode output ratio exceeded');
    _budget -= count * 8;
  }

  int readCount([int maximum = 1 << 20]) {
    final count = readVaruint();
    if (count < 0 || count > maximum)
      throw invalidData('decode count limit exceeded');
    claimOutput(count);
    return count;
  }

  T withDepth<T>(T Function() decode) {
    if (_depth >= 64) throw invalidData('decode depth limit exceeded');
    _depth++;
    try {
      return decode();
    } finally {
      _depth--;
    }
  }

  int get position => _offset;
  bool get isEof => _offset >= _input.length;

  int readU8() {
    if (_offset >= _input.length) throw unexpectedEof();
    return _input[_offset++];
  }

  Uint8List readExact(int n) {
    final end = _offset + n;
    if (n < 0 || n > _input.length - _offset) throw unexpectedEof();
    final slice = _input.sublist(_offset, end);
    _offset = end;
    return slice;
  }

  int readVaruint() {
    var shift = 0;
    var result = 0;
    while (true) {
      if (shift >= 64) throw invalidData('varuint too large');
      final b = readU8();
      if (shift == 63 && (b & 0x7E) != 0)
        throw invalidData('varuint too large');
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  int readI64Zigzag() => decodeZigzag(readVaruint());

  Uint8List readBytes() {
    final n = readVaruint();
    return readExact(n);
  }

  String readString() {
    final n = readVaruint();
    final data = readExact(n);
    try {
      return utf8.decode(data);
    } catch (_) {
      throw utf8Error();
    }
  }

  List<bool> readBitmap() {
    final bitCount = readCount();
    final byteCount = (bitCount + 7) ~/ 8;
    final raw = readExact(byteCount);
    final bits = List<bool>.filled(bitCount, false);
    for (var i = 0; i < bitCount; i++) {
      bits[i] = ((raw[i ~/ 8] >> (i % 8)) & 1) == 1;
    }
    return bits;
  }
}

Reader newReader(Uint8List input) => Reader(input);

int readU64Le(Reader reader) {
  final b = reader.readExact(8);
  final bd = ByteData.sublistView(b);
  return bd.getUint64(0, Endian.little);
}

double readF64Le(Reader reader) {
  final u = readU64Le(reader);
  final bd = ByteData(8)..setUint64(0, u, Endian.little);
  return bd.getFloat64(0, Endian.little);
}

void appendU64Le(BytesBuilder out, int v) {
  if (v < 0 || (v >> 64) != 0) throw invalidData('u64 out of range');
  final bd = ByteData(8)..setUint64(0, v, Endian.little);
  out.add(bd.buffer.asUint8List());
}

void appendF64Le(BytesBuilder out, double v) {
  final bd = ByteData(8)..setFloat64(0, v, Endian.little);
  appendU64Le(out, bd.getUint64(0, Endian.little));
}
