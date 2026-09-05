#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

#include "twilic/interop_fixtures.hpp"

namespace {

int failures = 0;

void check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
    ++failures;
  }
}

}  // namespace

int main() {
  try {
    const auto frames = twilic::InteropFixtures::parse_interop_frames(
        twilic::InteropFixtures::emit_interop_fixtures());
    check(!frames.empty(), "expected emitted frames");

    twilic::TwilicCodec codec_stream;
    twilic::TwilicCodec session_stream;
    for (const auto& frame : frames) {
      if (frame.stream == "codec") {
        twilic::InteropFixtures::assert_interop_codec_decode(codec_stream, frame.label, frame.bytes);
      } else if (frame.stream == "session") {
        twilic::InteropFixtures::assert_interop_session_decode(session_stream, frame.label, frame.bytes);
      } else {
        throw std::runtime_error("unknown stream");
      }
    }

    std::istringstream roundtrip(twilic::InteropFixtures::emit_interop_fixtures());
    std::ostringstream captured;
    captured << roundtrip.rdbuf();
    twilic::InteropFixtures::decode_rust_server_frames(captured.str());
  } catch (const std::exception& ex) {
    std::cerr << ex.what() << '\n';
    return 1;
  }

  if (failures != 0) return 1;
  std::cout << "interop fixtures test passed\n";
  return 0;
}
