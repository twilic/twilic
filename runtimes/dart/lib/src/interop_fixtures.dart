import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';
import 'protocol.dart';
import 'protocol_helpers.dart';
import 'session.dart';

class InteropFrame {
  InteropFrame({
    required this.stream,
    required this.label,
    required this.hex,
    required this.bytes,
  });
  final String stream;
  final String label;
  final String hex;
  final Uint8List bytes;
}

Value interopIdNameMap(int id, String name) => newMap([
      entry('id', newU64(id)),
      entry('name', newString(name)),
    ]);

Value interopIdNameRoleMap(int id, String name, String role) => newMap([
      entry('id', newU64(id)),
      entry('name', newString(name)),
      entry('role', newString(role)),
    ]);

List<Value> interopMakeI64Array(int length, int start) =>
    List.generate(length, (i) => newI64(start + i));

List<Value> interopMakeUserRows(List<String> names) => [
      for (var i = 0; i < names.length; i++)
        newMap([
          entry('id', newU64(i + 1)),
          entry('name', newString(names[i])),
        ]),
    ];

String emitInteropFixtures() {
  final buf = StringBuffer();
  final codec = newTwilicCodec();

  emitInteropValue(buf, 'codec', 'scalar_string', codec, newString('alpha'));

  final mapTwo = interopIdNameMap(1, 'alice');
  emitInteropValue(buf, 'codec', 'map_two_fields_first', codec, mapTwo);
  resetEncodeShapeObservation(codec, ['id', 'name']);
  emitInteropValue(buf, 'codec', 'map_two_fields_second', codec, mapTwo);

  final mapThree = interopIdNameRoleMap(1, 'alice', 'admin');
  emitInteropValue(buf, 'codec', 'map_three_fields_first', codec, mapThree);
  resetEncodeShapeObservation(codec, ['id', 'name', 'role']);
  emitInteropValue(buf, 'codec', 'map_three_fields_second', codec, mapThree);

  for (var i = 0; i < 8; i++) {
    emitInteropValue(
      buf,
      'codec',
      'bulk_map_$i',
      codec,
      interopIdNameMap(10 + i, 'user-$i'),
    );
  }

  final baseSnapshot = Message(
    kind: MessageKind.baseSnapshot,
    baseSnapshot: BaseSnapshotMessage(
      baseId: 77,
      schemaOrShapeRef: 0,
      payload: Message(kind: MessageKind.scalar, scalar: newI64(42)),
    ),
  );
  emitInteropMessage(buf, 'codec', 'base_snapshot', codec, baseSnapshot);

  final enc = newSessionEncoder(defaultSessionOptions());
  emitInteropFrame(
    buf,
    'session',
    'session_base_array',
    enc.encode(newArray(interopMakeI64Array(100, 0))),
  );

  final oneChangeArr = interopMakeI64Array(100, 0);
  oneChangeArr[0] = newI64(10000);
  emitInteropFrame(
    buf,
    'session',
    'session_patch_one_change',
    enc.encodePatch(newArray(oneChangeArr)),
  );

  for (var step = 0; step < 4; step++) {
    final iterArr = interopMakeI64Array(100, 0);
    iterArr[step] = newI64(20000 + step);
    emitInteropFrame(
      buf,
      'session',
      'session_patch_iter_$step',
      enc.encodePatch(newArray(iterArr)),
    );
  }

  final manyArr = interopMakeI64Array(100, 0);
  for (var i = 0; i < 12; i++) {
    manyArr[i] = newI64(10000 + i);
  }
  emitInteropFrame(
    buf,
    'session',
    'session_patch_many_changes',
    enc.encodePatch(newArray(manyArr)),
  );

  emitInteropFrame(
    buf,
    'session',
    'session_micro_batch_first',
    enc.encodeMicroBatch(interopMakeUserRows(['a', 'b', 'c', 'd'])),
  );
  emitInteropFrame(
    buf,
    'session',
    'session_micro_batch_second',
    enc.encodeMicroBatch(interopMakeUserRows(['aa', 'bb', 'cc', 'dd'])),
  );

  return buf.toString();
}

List<InteropFrame> parseInteropFrames(String input) {
  final frames = <InteropFrame>[];
  final lines = const LineSplitter().convert(input);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split('|');
    if (parts.length != 3) {
      throw ArgumentError('line ${i + 1}: invalid frame');
    }
    frames.add(InteropFrame(
      stream: parts[0],
      label: parts[1],
      hex: parts[2],
      bytes: decodeInteropHex(parts[2]),
    ));
  }
  if (frames.isEmpty) {
    throw ArgumentError('no fixture frames found');
  }
  return frames;
}

void decodeRustServerFrames(String input) {
  final frames = parseInteropFrames(input);
  final codecStream = newTwilicCodec();
  final sessionStream = newTwilicCodec();
  var decoded = 0;
  for (final frame in frames) {
    if (frame.stream == 'codec') {
      assertInteropCodecDecode(codecStream, frame.label, frame.bytes);
    } else if (frame.stream == 'session') {
      assertInteropSessionDecode(sessionStream, frame.label, frame.bytes);
    } else {
      throw ArgumentError('unknown stream ${frame.stream}');
    }
    decoded++;
  }
  // ignore: avoid_print
  print('Dart client decode and value checks passed for $decoded Rust frames');
}

void assertInteropCodecDecode(
    TwilicCodec codec, String label, Uint8List frame) {
  if (label == 'base_snapshot') {
    final msg = codec.decodeMessage(frame);
    if (msg.kind != MessageKind.baseSnapshot || msg.baseSnapshot == null) {
      throw StateError('expected base snapshot');
    }
    if (msg.baseSnapshot!.baseId != 77) {
      throw StateError('base_id mismatch');
    }
    final payload = msg.baseSnapshot!.payload;
    if (payload.kind != MessageKind.scalar ||
        payload.scalar?.kind != ValueKind.i64 ||
        payload.scalar!.i64 != 42) {
      throw StateError('payload mismatch');
    }
    return;
  }

  final controlCodec = interopExpectControlStreamCodec(label);
  if (controlCodec != null) {
    final msg = codec.decodeMessage(frame);
    if (msg.kind != MessageKind.controlStream || msg.controlStream == null) {
      throw StateError('expected control stream');
    }
    if (msg.controlStream!.codec != controlCodec) {
      throw StateError('control stream codec mismatch for $label');
    }
    if (msg.controlStream!.payload.isEmpty) {
      throw StateError('control stream payload empty for $label');
    }
    return;
  }

  final expected = interopExpectCodecValue(label);
  if (expected == null) {
    throw ArgumentError('no codec expectation for label $label');
  }
  final got = codec.decodeValue(frame);
  if (!equal(got, expected)) {
    throw StateError('decoded value mismatch for $label');
  }
}

void assertInteropSessionDecode(
  TwilicCodec codec,
  String label,
  Uint8List frame,
) {
  switch (label) {
    case 'session_base_array':
      final got = codec.decodeValue(frame);
      final want = newArray(interopMakeI64Array(100, 0));
      if (!equal(got, want)) {
        throw StateError('session_base_array value mismatch');
      }
    case 'session_patch_one_change':
      final msg = codec.decodeMessage(frame);
      if (msg.kind != MessageKind.statePatch &&
          msg.kind != MessageKind.typedVector &&
          msg.kind != MessageKind.array) {
        throw StateError(
            'unexpected message kind for session_patch_one_change');
      }
    case 'session_patch_many_changes':
    case 'session_micro_batch_first':
    case 'session_micro_batch_second':
      final msg = codec.decodeMessage(frame);
      if (label == 'session_patch_many_changes') {
        if (msg.kind != MessageKind.statePatch &&
            msg.kind != MessageKind.typedVector &&
            msg.kind != MessageKind.array) {
          throw StateError('expected patch or array message');
        }
      } else {
        if (msg.kind != MessageKind.templateBatch ||
            msg.templateBatch == null) {
          throw StateError('expected template batch');
        }
        if (msg.templateBatch!.count != 4) {
          throw StateError('expected template batch with 4 rows');
        }
      }
    default:
      if (label.startsWith('session_patch_iter_')) {
        final msg = codec.decodeMessage(frame);
        if (msg.kind != MessageKind.statePatch &&
            msg.kind != MessageKind.typedVector &&
            msg.kind != MessageKind.array) {
          throw StateError('expected patch or array message');
        }
      } else if (label != 'session_base_array' &&
          label != 'session_patch_one_change' &&
          label != 'session_patch_many_changes' &&
          label != 'session_micro_batch_first' &&
          label != 'session_micro_batch_second') {
        throw ArgumentError('no session expectation for label $label');
      }
  }
}

Value? interopExpectCodecValue(String label) {
  if (label == 'scalar_string') return newString('alpha');
  if (label.startsWith('map_two_fields_')) {
    return interopIdNameMap(1, 'alice');
  }
  if (label.startsWith('map_three_fields_')) {
    return interopIdNameRoleMap(1, 'alice', 'admin');
  }
  if (label.startsWith('bulk_map_')) {
    final idx = int.parse(label.substring('bulk_map_'.length));
    return interopIdNameMap(10 + idx, 'user-$idx');
  }
  return null;
}

ControlStreamCodec? interopExpectControlStreamCodec(String label) {
  switch (label) {
    case 'control_stream_bitpack':
      return ControlStreamCodec.bitpack;
    case 'control_stream_huffman':
      return ControlStreamCodec.huffman;
    case 'control_stream_fse':
      return ControlStreamCodec.fse;
    default:
      return null;
  }
}

void emitInteropValue(
  StringBuffer buf,
  String stream,
  String label,
  TwilicCodec codec,
  Value value,
) {
  emitInteropFrame(buf, stream, label, codec.encodeValue(value));
}

void emitInteropMessage(
  StringBuffer buf,
  String stream,
  String label,
  TwilicCodec codec,
  Message message,
) {
  emitInteropFrame(buf, stream, label, codec.encodeMessage(message));
}

void emitInteropFrame(
    StringBuffer buf, String stream, String label, Uint8List bytes) {
  buf.write('$stream|$label|');
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  buf.writeln();
}

Uint8List decodeInteropHex(String hex) {
  if (hex.length.isOdd) {
    throw ArgumentError('invalid hex length');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) throw ArgumentError('invalid hex');
    out[i] = byte;
  }
  return out;
}
