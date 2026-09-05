import 'package:test/test.dart';
import 'package:twilic/twilic.dart';

void main() {
  test('emitInteropFixtures produces expected frame counts', () {
    final text = emitInteropFixtures();
    final frames = parseInteropFrames(text);
    final codec = frames.where((f) => f.stream == 'codec').length;
    final session = frames.where((f) => f.stream == 'session').length;
    expect(codec, 14);
    expect(session, 9);
    expect(frames.length, 23);
  });

  test('codec frames round-trip through local decoder', () {
    final frames = parseInteropFrames(emitInteropFixtures());
    final codec = newTwilicCodec();
    for (final frame in frames) {
      if (frame.stream != 'codec') continue;
      assertInteropCodecDecode(codec, frame.label, frame.bytes);
    }
  });

  test('session frames decode through local decoder', () {
    final frames = parseInteropFrames(emitInteropFixtures());
    final codec = newTwilicCodec();
    for (final frame in frames) {
      if (frame.stream != 'session') continue;
      assertInteropSessionDecode(codec, frame.label, frame.bytes);
    }
  });

  test('scalar_string codec value round-trip', () {
    final frames = parseInteropFrames(emitInteropFixtures());
    final frame = frames.firstWhere((f) => f.label == 'scalar_string');
    final codec = newTwilicCodec();
    final got = codec.decodeValue(frame.bytes);
    expect(equal(got, newString('alpha')), isTrue);
  });
}
