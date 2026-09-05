#include "test_helpers.h"

#include "twilic/interop_fixtures.h"

using namespace twilic;

static int test_codec_encode_decode_roundtrip(void) {
  const auto fixtures = InteropFixtures::emit_interop_fixtures();
  const auto frames = InteropFixtures::parse_interop_frames(fixtures);
  TwilicCodec codec;
  for (const auto &frame : frames) {
    if (frame.stream != "codec") continue;
    InteropFixtures::assert_interop_codec_decode(codec, frame.label, frame.bytes);
  }
  return 0;
}

static int test_session_encode_decode_roundtrip(void) {
  const auto fixtures = InteropFixtures::emit_interop_fixtures();
  const auto frames = InteropFixtures::parse_interop_frames(fixtures);
  TwilicCodec codec;
  for (const auto &frame : frames) {
    if (frame.stream != "session") continue;
    InteropFixtures::assert_interop_session_decode(codec, frame.label, frame.bytes);
  }
  return 0;
}

int main(void) {
  TEST_RUN(test_codec_encode_decode_roundtrip);
  TEST_RUN(test_session_encode_decode_roundtrip);
  return 0;
}
