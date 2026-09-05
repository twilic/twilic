library twilic;

export 'src/errors.dart';
export 'src/interop_fixtures.dart';
export 'src/model.dart';
export 'src/protocol.dart';
export 'src/session.dart';
export 'src/v2.dart';

import 'dart:typed_data';

import 'src/model.dart';
import 'src/protocol.dart';
import 'src/session.dart';
import 'src/v2.dart';

Uint8List encode(Value value) => encodeV2(value);
Value decode(Uint8List data) => decodeV2(data);

Uint8List encodeWithSchema(Schema schema, Value value) =>
    newSessionEncoder().encodeWithSchema(schema, value);

Uint8List encodeBatch(List<Value> values) =>
    newSessionEncoder().encodeBatch(values);
