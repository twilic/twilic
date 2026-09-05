import 'dart:typed_data';

import 'errors.dart';
import 'model.dart';
import 'wire.dart';

const _simple8bSlots = <(int, int)>[
  (60, 1),
  (30, 2),
  (20, 3),
  (15, 4),
  (12, 5),
  (10, 6),
  (8, 7),
  (7, 8),
  (6, 10),
  (5, 12),
  (4, 15),
  (3, 20),
  (2, 30),
  (1, 60),
];

bool fitsU64(int v) => v >= 0 && (v >> 64) == 0;

int _lowBitsMask(int width) => width == 64 ? -1 : (1 << width) - 1;

int _bitWidth(int v) {
  if (v == 0) return 1;
  var n = v;
  var bits = 0;
  while (n > 0) {
    bits++;
    n >>= 1;
  }
  return bits;
}

void _packU64Values(List<int> values, int width, BytesBuilder out) {
  final totalBits = values.length * width;
  final byteLen = (totalBits + 7) ~/ 8;
  final bytes = Uint8List(byteLen);
  var bitPos = 0;
  for (final value in values) {
    var written = 0;
    while (written < width) {
      final byteIdx = bitPos ~/ 8;
      final bitOff = bitPos % 8;
      final room = 8 - bitOff;
      final take = width - written < room ? width - written : room;
      final mask = (1 << take) - 1;
      final part = (value >> written) & mask;
      bytes[byteIdx] |= part << bitOff;
      bitPos += take;
      written += take;
    }
  }
  out.add(bytes);
}

List<int> _unpackU64Values(Reader reader, int length, int width) {
  final totalBits = length * width;
  final byteLen = (totalBits + 7) ~/ 8;
  final raw = reader.readExact(byteLen);
  final out = <int>[];
  var bitPos = 0;
  for (var i = 0; i < length; i++) {
    var value = 0;
    var read = 0;
    while (read < width) {
      final byteIdx = bitPos ~/ 8;
      final bitOff = bitPos % 8;
      final room = 8 - bitOff;
      final take = width - read < room ? width - read : room;
      final mask = (1 << take) - 1;
      final part = (raw[byteIdx] >> bitOff) & mask;
      value |= part << read;
      bitPos += take;
      read += take;
    }
    out.add(value);
  }
  return out;
}

(int, bool) _checkedAddU64(int a, int b) {
  if (!fitsU64(a) || !fitsU64(b)) return (0, false);
  final sum = a + b;
  if (!fitsU64(sum)) return (0, false);
  return (sum, true);
}

(int, bool) _checkedAddI64(int a, int b) {
  final sum = a + b;
  if ((b > 0 && sum < a) || (b < 0 && sum > a)) return (0, false);
  return (sum, true);
}

List<int> _delta(List<int> values) {
  final out = <int>[];
  for (var i = 0; i < values.length; i++) {
    out.add(i == 0 ? values[i] : values[i] - values[i - 1]);
  }
  return out;
}

List<int> _undelta(List<int> values) {
  final out = <int>[];
  var prev = 0;
  for (var i = 0; i < values.length; i++) {
    if (i == 0) {
      out.add(values[i]);
      prev = values[i];
    } else {
      final (nxt, ok) = _checkedAddI64(prev, values[i]);
      if (!ok) throw invalidData('delta overflow');
      out.add(nxt);
      prev = nxt;
    }
  }
  return out;
}

void encodeI64Vector(List<int> values, VectorCodec codec, BytesBuilder out) {
  switch (codec) {
    case VectorCodec.rle:
      encodeI64Rle(values, out);
    case VectorCodec.directBitpack:
      encodeI64DirectBitpack(values, out);
    case VectorCodec.deltaBitpack:
      encodeI64DirectBitpack(_delta(values), out);
    case VectorCodec.forBitpack:
      if (values.isEmpty) {
        encodeVaruint(0, out);
        return;
      }
      var minValue = values[0];
      for (var i = 1; i < values.length; i++) {
        if (values[i] < minValue) minValue = values[i];
      }
      encodeVaruint(encodeZigzag(minValue), out);
      encodeI64DirectBitpack(
        values.map((v) => v - minValue).toList(),
        out,
      );
    case VectorCodec.deltaForBitpack:
      final deltas = _delta(values);
      if (deltas.isEmpty) {
        encodeVaruint(0, out);
        return;
      }
      var minValue = deltas[0];
      for (var i = 1; i < deltas.length; i++) {
        if (deltas[i] < minValue) minValue = deltas[i];
      }
      encodeVaruint(encodeZigzag(minValue), out);
      encodeI64DirectBitpack(
        deltas.map((v) => v - minValue).toList(),
        out,
      );
    case VectorCodec.deltaDeltaBitpack:
      encodeI64DeltaDelta(values, out);
    case VectorCodec.patchedFor:
      encodeI64PatchedFor(values, out);
    case VectorCodec.simple8b:
      encodeI64Simple8b(values, out);
    case VectorCodec.plain:
    case VectorCodec.dictionary:
    case VectorCodec.stringRef:
    case VectorCodec.prefixDelta:
    case VectorCodec.xorFloat:
      encodeI64Plain(values, out);
  }
}

List<int> decodeI64Vector(Reader reader, VectorCodec codec) {
  switch (codec) {
    case VectorCodec.rle:
      return decodeI64Rle(reader);
    case VectorCodec.directBitpack:
      return decodeI64DirectBitpack(reader);
    case VectorCodec.deltaBitpack:
      return _undelta(decodeI64DirectBitpack(reader));
    case VectorCodec.forBitpack:
      final encodedMin = reader.readVaruint();
      final minValue = decodeZigzag(encodedMin);
      if (reader.isEof) return [];
      final shifted = decodeI64DirectBitpack(reader);
      return shifted.map((v) => v + minValue).toList();
    case VectorCodec.deltaForBitpack:
      final encodedMin = reader.readVaruint();
      final minValue = decodeZigzag(encodedMin);
      if (reader.isEof) return [];
      final shifted = decodeI64DirectBitpack(reader);
      return _undelta(shifted.map((v) => v + minValue).toList());
    case VectorCodec.deltaDeltaBitpack:
      return decodeI64DeltaDelta(reader);
    case VectorCodec.patchedFor:
      return decodeI64PatchedFor(reader);
    case VectorCodec.simple8b:
      return decodeI64Simple8b(reader);
    case VectorCodec.plain:
    case VectorCodec.dictionary:
    case VectorCodec.stringRef:
    case VectorCodec.prefixDelta:
    case VectorCodec.xorFloat:
      return decodeI64Plain(reader);
  }
}

void encodeU64Vector(List<int> values, VectorCodec codec, BytesBuilder out) {
  switch (codec) {
    case VectorCodec.rle:
      encodeU64Rle(values, out);
    case VectorCodec.directBitpack:
      encodeU64DirectBitpack(values, out);
    case VectorCodec.forBitpack:
      if (values.isEmpty) {
        encodeVaruint(0, out);
        return;
      }
      var minValue = values[0];
      for (var i = 1; i < values.length; i++) {
        if (values[i] < minValue) minValue = values[i];
      }
      encodeVaruint(minValue, out);
      encodeU64DirectBitpack(
        values.map((v) => v - minValue).toList(),
        out,
      );
    case VectorCodec.plain:
      encodeU64Plain(values, out);
    case VectorCodec.simple8b:
      encodeU64Simple8b(values, out);
    case VectorCodec.dictionary:
    case VectorCodec.stringRef:
    case VectorCodec.prefixDelta:
    case VectorCodec.xorFloat:
    case VectorCodec.deltaBitpack:
    case VectorCodec.deltaForBitpack:
    case VectorCodec.deltaDeltaBitpack:
    case VectorCodec.patchedFor:
      encodeU64Plain(values, out);
  }
}

List<int> decodeU64Vector(Reader reader, VectorCodec codec) {
  switch (codec) {
    case VectorCodec.rle:
      return decodeU64Rle(reader);
    case VectorCodec.directBitpack:
      return decodeU64DirectBitpack(reader);
    case VectorCodec.forBitpack:
      final minValue = reader.readVaruint();
      if (reader.isEof) return [];
      final shifted = decodeU64DirectBitpack(reader);
      final out = <int>[];
      for (final v in shifted) {
        final (sum, ok) = _checkedAddU64(v, minValue);
        if (!ok) throw invalidData('u64 FOR overflow');
        out.add(sum);
      }
      return out;
    case VectorCodec.plain:
      return decodeU64Plain(reader);
    case VectorCodec.simple8b:
      return decodeU64Simple8b(reader);
    default:
      return decodeU64Plain(reader);
  }
}

void encodeF64Vector(List<double> values, VectorCodec codec, BytesBuilder out) {
  if (codec == VectorCodec.xorFloat) {
    encodeXorFloat(values, out);
    return;
  }
  encodeVaruint(values.length, out);
  for (final v in values) {
    appendF64Le(out, v);
  }
}

List<double> decodeF64Vector(Reader reader, VectorCodec codec) {
  if (codec == VectorCodec.xorFloat) return decodeXorFloat(reader);
  final length = reader.readCount();
  return List.generate(length, (_) => readF64Le(reader));
}

void encodeU64Plain(List<int> values, BytesBuilder out) {
  encodeVaruint(values.length, out);
  for (final value in values) {
    encodeVaruint(value, out);
  }
}

List<int> decodeU64Plain(Reader reader) {
  final length = reader.readCount();
  return List.generate(length, (_) => reader.readVaruint());
}

void encodeU64Rle(List<int> values, BytesBuilder out) {
  final runs = <(int, int)>[];
  for (final value in values) {
    if (runs.isNotEmpty && runs.last.$1 == value) {
      runs[runs.length - 1] = (value, runs.last.$2 + 1);
    } else {
      runs.add((value, 1));
    }
  }
  encodeVaruint(runs.length, out);
  for (final run in runs) {
    encodeVaruint(run.$1, out);
    encodeVaruint(run.$2, out);
  }
}

List<int> decodeU64Rle(Reader reader) {
  final runsLen = reader.readCount();
  final out = <int>[];
  for (var i = 0; i < runsLen; i++) {
    final value = reader.readVaruint();
    final count = reader.readCount();
    for (var j = 0; j < count; j++) {
      out.add(value);
    }
  }
  return out;
}

void encodeU64DirectBitpack(List<int> values, BytesBuilder out) {
  encodeVaruint(values.length, out);
  if (values.isEmpty) {
    out.addByte(0);
    return;
  }
  var width = 1;
  for (final v in values) {
    final bw = _bitWidth(v);
    if (bw > width) width = bw;
  }
  out.addByte(width);
  _packU64Values(values, width, out);
}

List<int> decodeU64DirectBitpack(Reader reader) {
  final length = reader.readCount();
  final width = reader.readU8();
  if (length == 0) return [];
  if (width == 0 || width > 64) throw invalidData('bitpack width');
  return _unpackU64Values(reader, length, width);
}

void encodeI64Plain(List<int> values, BytesBuilder out) {
  encodeVaruint(values.length, out);
  for (final value in values) {
    encodeVaruint(encodeZigzag(value), out);
  }
}

List<int> decodeI64Plain(Reader reader) {
  final length = reader.readCount();
  return List.generate(length, (_) => decodeZigzag(reader.readVaruint()));
}

void encodeI64Simple8b(List<int> values, BytesBuilder out) {
  encodeU64Simple8bInner(
    values.map(encodeZigzag).toList(),
    out,
  );
}

List<int> decodeI64Simple8b(Reader reader) {
  return decodeU64Simple8bInner(reader).map(decodeZigzag).toList();
}

void encodeU64Simple8b(List<int> values, BytesBuilder out) {
  encodeU64Simple8bInner(values, out);
}

List<int> decodeU64Simple8b(Reader reader) => decodeU64Simple8bInner(reader);

void encodeU64Simple8bInner(List<int> values, BytesBuilder out) {
  encodeVaruint(values.length, out);
  if (values.isEmpty) return;
  var maxValue = 0;
  for (final v in values) {
    if (v > maxValue) maxValue = v;
  }
  if (maxValue > (1 << 60) - 1) {
    out.addByte(0);
    for (final value in values) {
      encodeVaruint(value, out);
    }
    return;
  }
  out.addByte(1);
  var idx = 0;
  while (idx < values.length) {
    var zeroRun = 0;
    while (idx + zeroRun < values.length &&
        values[idx + zeroRun] == 0 &&
        zeroRun < 240) {
      zeroRun++;
    }
    if (zeroRun >= 120) {
      final take = zeroRun >= 240 ? 240 : 120;
      final word = take == 240 ? 0 : (1 << 60);
      appendU64Le(out, word);
      idx += take;
      continue;
    }
    var packed = false;
    for (var selectorIdx = 0;
        selectorIdx < _simple8bSlots.length;
        selectorIdx++) {
      final slot = _simple8bSlots[selectorIdx];
      if (idx + slot.$1 > values.length) continue;
      var allFit = true;
      for (var j = 0; j < slot.$1; j++) {
        final v = values[idx + j];
        if (slot.$2 == 64) {
          if (!fitsU64(v)) {
            allFit = false;
            break;
          }
        } else if (v > _lowBitsMask(slot.$2)) {
          allFit = false;
          break;
        }
      }
      if (!allFit) continue;
      final selector = selectorIdx + 2;
      var payload = 0;
      var shift = 0;
      for (var j = 0; j < slot.$1; j++) {
        payload |= values[idx + j] << shift;
        shift += slot.$2;
      }
      appendU64Le(out, (selector << 60) | payload);
      idx += slot.$1;
      packed = true;
      break;
    }
    if (!packed) {
      appendU64Le(out, (15 << 60) | (values[idx] & ((1 << 60) - 1)));
      idx++;
    }
  }
}

List<int> decodeU64Simple8bInner(Reader reader) {
  final length = reader.readCount();
  if (length == 0) return [];
  final mode = reader.readU8();
  if (mode == 0) {
    return List.generate(length, (_) => reader.readVaruint());
  }
  if (mode != 1) throw invalidData('simple8b mode');
  final out = <int>[];
  while (out.length < length) {
    final packed = readU64Le(reader);
    final selector = packed >> 60;
    final payload = packed & ((1 << 60) - 1);
    if (selector == 0 || selector == 1) {
      final count = selector == 1 ? 120 : 240;
      final remain = length - out.length;
      final limit = remain < count ? remain : count;
      for (var i = 0; i < limit; i++) {
        out.add(0);
      }
    } else if (selector >= 2 && selector <= 15) {
      late int count;
      late int width;
      if (selector == 15) {
        count = 1;
        width = 60;
      } else {
        final slot = _simple8bSlots[selector - 2];
        count = slot.$1;
        width = slot.$2;
      }
      final mask = _lowBitsMask(width);
      var shift = 0;
      final remain = length - out.length;
      final limit = remain < count ? remain : count;
      for (var i = 0; i < limit; i++) {
        out.add((payload >> shift) & mask);
        shift += width;
      }
    } else {
      throw invalidData('simple8b selector');
    }
  }
  return out;
}

void encodeI64Rle(List<int> values, BytesBuilder out) {
  final runs = <(int, int)>[];
  for (final value in values) {
    if (runs.isNotEmpty && runs.last.$1 == value) {
      runs[runs.length - 1] = (value, runs.last.$2 + 1);
    } else {
      runs.add((value, 1));
    }
  }
  encodeVaruint(runs.length, out);
  for (final run in runs) {
    encodeVaruint(encodeZigzag(run.$1), out);
    encodeVaruint(run.$2, out);
  }
}

List<int> decodeI64Rle(Reader reader) {
  final runsLen = reader.readCount();
  final out = <int>[];
  for (var i = 0; i < runsLen; i++) {
    final value = decodeZigzag(reader.readVaruint());
    final count = reader.readCount();
    for (var j = 0; j < count; j++) {
      out.add(value);
    }
  }
  return out;
}

void encodeI64PatchedFor(List<int> values, BytesBuilder out) {
  if (values.isEmpty) {
    encodeVaruint(0, out);
    return;
  }
  var base = values[0];
  for (var i = 1; i < values.length; i++) {
    if (values[i] < base) base = values[i];
  }
  final shifted = values.map((v) => v - base).toList();
  encodeVaruint(shifted.length, out);
  encodeVaruint(encodeZigzag(base), out);
  var maxValue = 0;
  for (final value in shifted) {
    if (value > maxValue) maxValue = value;
  }
  final bw = _bitWidth(maxValue);
  final baseWidth = bw > 2 ? bw - 2 : 0;
  out.addByte(baseWidth);
  final patchPositions = <(int, int)>[];
  final mainValues = <int>[];
  for (var idx = 0; idx < shifted.length; idx++) {
    final value = shifted[idx];
    if (_bitWidth(value) > baseWidth) {
      patchPositions.add((idx, value));
      var main = 0;
      if (baseWidth > 0) {
        final mask = (1 << baseWidth) - 1;
        main = value & mask;
        if (main < 0) main = 0;
      }
      mainValues.add(main);
    } else {
      mainValues.add(value);
    }
  }
  for (final value in mainValues) {
    encodeVaruint(value, out);
  }
  encodeVaruint(patchPositions.length, out);
  for (final patch in patchPositions) {
    encodeVaruint(patch.$1, out);
    encodeVaruint(patch.$2, out);
  }
}

List<int> decodeI64PatchedFor(Reader reader) {
  final length = reader.readCount();
  if (length == 0) return [];
  final base = decodeZigzag(reader.readVaruint());
  reader.readU8();
  final values = List.generate(length, (_) => reader.readVaruint());
  final patchCount = reader.readCount();
  for (var i = 0; i < patchCount; i++) {
    final pos = reader.readVaruint();
    final patch = reader.readVaruint();
    if (pos < values.length) values[pos] = patch;
  }
  return values.map((v) => v + base).toList();
}

int _f64Bits(double v) {
  final b = ByteData(8)..setFloat64(0, v, Endian.little);
  return b.getUint64(0, Endian.little);
}

double _f64FromBits(int bits) {
  final b = ByteData(8)..setUint64(0, bits, Endian.little);
  return b.getFloat64(0, Endian.little);
}

int _leadingZeros64(int x) {
  if (x == 0) return 64;
  var n = 0;
  while ((x & 0x8000000000000000) == 0) {
    n++;
    x <<= 1;
  }
  return n;
}

int _trailingZeros64(int x) {
  if (x == 0) return 64;
  var n = 0;
  while ((x & 1) == 0) {
    n++;
    x >>= 1;
  }
  return n;
}

void encodeXorFloat(List<double> values, BytesBuilder out) {
  encodeVaruint(values.length, out);
  if (values.isEmpty) return;
  appendU64Le(out, _f64Bits(values[0]));
  var prev = _f64Bits(values[0]);
  for (var i = 1; i < values.length; i++) {
    final bitsValue = _f64Bits(values[i]);
    final x = prev ^ bitsValue;
    if (x == 0) {
      out.addByte(0);
    } else {
      out.addByte(1);
      final leading = _leadingZeros64(x);
      final trailing = _trailingZeros64(x);
      final width = 64 - (leading + trailing);
      encodeVaruint(leading, out);
      encodeVaruint(trailing, out);
      encodeVaruint(width, out);
      final payload = width == 64 ? x : (x >> trailing) & ((1 << width) - 1);
      encodeVaruint(payload, out);
    }
    prev = bitsValue;
  }
}

List<double> decodeXorFloat(Reader reader) {
  final length = reader.readCount();
  if (length == 0) return [];
  var prev = readU64Le(reader);
  final out = <double>[_f64FromBits(prev)];
  for (var i = 1; i < length; i++) {
    final flag = reader.readU8();
    var bitsValue = prev;
    if (flag != 0) {
      final leading = reader.readVaruint();
      final trailing = reader.readVaruint();
      final width = reader.readVaruint();
      final payload = reader.readVaruint();
      if (leading + trailing + width > 64) {
        throw invalidData('xor-float bit widths');
      }
      final x = width == 64 ? payload : payload << trailing;
      bitsValue = prev ^ x;
    }
    out.add(_f64FromBits(bitsValue));
    prev = bitsValue;
  }
  return out;
}

void encodeI64DirectBitpack(List<int> values, BytesBuilder out) {
  encodeVaruint(values.length, out);
  if (values.isEmpty) {
    out.addByte(0);
    return;
  }
  final encoded = values.map(encodeZigzag).toList();
  var width = 1;
  for (final enc in encoded) {
    final bw = _bitWidth(enc);
    if (bw > width) width = bw;
  }
  out.addByte(width);
  _packU64Values(encoded, width, out);
}

List<int> decodeI64DirectBitpack(Reader reader) {
  final length = reader.readCount();
  final width = reader.readU8();
  if (length == 0) return [];
  if (width == 0 || width > 64) throw invalidData('bitpack width');
  return _unpackU64Values(reader, length, width).map(decodeZigzag).toList();
}

void encodeI64DeltaDelta(List<int> values, BytesBuilder out) {
  encodeVaruint(values.length, out);
  if (values.isEmpty) return;
  encodeVaruint(encodeZigzag(values[0]), out);
  if (values.length == 1) return;
  final d1 = values[1] - values[0];
  encodeVaruint(encodeZigzag(d1), out);
  final dd = <int>[];
  var prevDelta = d1;
  for (var i = 1; i < values.length - 1; i++) {
    final d = values[i + 1] - values[i];
    dd.add(d - prevDelta);
    prevDelta = d;
  }
  encodeI64DirectBitpack(dd, out);
}

List<int> decodeI64DeltaDelta(Reader reader) {
  final length = reader.readCount();
  if (length == 0) return [];
  final first = decodeZigzag(reader.readVaruint());
  if (length == 1) return [first];
  final firstDelta = decodeZigzag(reader.readVaruint());
  final dd = decodeI64DirectBitpack(reader);
  if (dd.length != length - 2) throw invalidData('delta-delta length');
  final out = <int>[first];
  var prev = first;
  var (second, ok) = _checkedAddI64(prev, firstDelta);
  if (!ok) throw invalidData('delta-delta overflow');
  out.add(second);
  prev = second;
  var prevDelta = firstDelta;
  for (final ddv in dd) {
    final (d, okD) = _checkedAddI64(prevDelta, ddv);
    if (!okD) throw invalidData('delta-delta overflow');
    final (nxt, okN) = _checkedAddI64(prev, d);
    if (!okN) throw invalidData('delta-delta overflow');
    out.add(nxt);
    prev = nxt;
    prevDelta = d;
  }
  return out;
}

Uint8List rleEncodeBytes(Uint8List input) {
  if (input.isEmpty) return Uint8List(0);
  final out = BytesBuilder();
  var i = 0;
  while (i < input.length) {
    var j = i + 1;
    while (j < input.length && input[j] == input[i] && j - i < 255) {
      j++;
    }
    out.addByte(j - i);
    out.addByte(input[i]);
    i = j;
  }
  return out.toBytes();
}

Uint8List rleDecodeBytes(Uint8List input) {
  final out = BytesBuilder();
  var i = 0;
  while (i < input.length) {
    if (i + 1 >= input.length) throw invalidData('rle payload');
    final run = input[i];
    final b = input[i + 1];
    for (var k = 0; k < run; k++) {
      out.addByte(b);
    }
    i += 2;
  }
  return out.toBytes();
}

Uint8List controlBitpackEncodeBytes(Uint8List input) =>
    Uint8List.fromList(input);
Uint8List controlBitpackDecodeBytes(Uint8List input) =>
    Uint8List.fromList(input);
Uint8List controlHuffmanEncodeBytes(Uint8List input) =>
    Uint8List.fromList(input);
Uint8List controlHuffmanDecodeBytes(Uint8List input) =>
    Uint8List.fromList(input);
Uint8List controlFseEncodeBytes(Uint8List input) => Uint8List.fromList(input);
Uint8List controlFseDecodeBytes(Uint8List input) => Uint8List.fromList(input);
