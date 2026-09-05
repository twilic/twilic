import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:twilic/src/wire.dart';
import 'package:twilic/src/v2.dart';

void main() {
  test('cumulative budgets and invalid lengths', () {
    final reader = Reader(Uint8List(1));
    reader.claimOutput(100);
    expect(() => reader.claimOutput(100), throwsA(isA<Exception>()));
    expect(() => reader.readExact(-1), throwsA(isA<Exception>()));
  });
  test('depth rejection', () {
    expect(() => decodeV2(Uint8List.fromList([...List.filled(70, 0xa1), 0xc0])),
        throwsA(isA<Exception>()));
  });
}
