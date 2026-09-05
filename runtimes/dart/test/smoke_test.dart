import 'package:test/test.dart';
import 'package:twilic/twilic.dart';

Value _sampleValue() => newMap([
      entry('id', newU64(1001)),
      entry('name', newString('alice')),
      entry('admin', newBool(false)),
      entry(
          'scores',
          newArray([
            newU64(12),
            newU64(15),
            newU64(18),
            newU64(21),
          ])),
    ]);

void main() {
  test('v2 roundtrip dynamic value', () {
    final value = _sampleValue();
    final encoded = encode(value);
    final decoded = decode(encoded);
    expect(equal(decoded, value), isTrue);
  });

  test('codec roundtrip dynamic value', () {
    final value = _sampleValue();
    final codec = newTwilicCodec();
    final encoded = codec.encodeValue(value);
    final decoded = codec.decodeValue(encoded);
    expect(equal(decoded, value), isTrue);
  });

  test('session encoder encode_batch smoke', () {
    final enc = newSessionEncoder();
    final value = _sampleValue();
    expect(enc.encode(value), isNotEmpty);
    expect(enc.encodeBatch([value, value]), isNotEmpty);
  });
}
