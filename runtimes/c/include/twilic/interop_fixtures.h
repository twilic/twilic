#pragma once
#include <string>
#include <vector>

#include "twilic/model.h"
#include "twilic/protocol.h"

namespace twilic {

struct InteropFrame {
  std::string stream;
  std::string label;
  std::string hex;
  std::vector<uint8_t> bytes;
};

class InteropFixtures {
 public:
  static Value interop_id_name_map(uint64_t id, const std::string& name);
  static Value interop_id_name_role_map(uint64_t id, const std::string& name, const std::string& role);
  static std::vector<Value> interop_make_i64_array(int length, int64_t start);
  static std::vector<Value> interop_make_user_rows(const std::vector<std::string>& names);

  static std::string emit_interop_fixtures();
  static std::vector<InteropFrame> parse_interop_frames(const std::string& input);

  static void assert_interop_codec_decode(TwilicCodec& codec, const std::string& label,
                                          const std::vector<uint8_t>& frame);
  static void assert_interop_session_decode(TwilicCodec& codec, const std::string& label,
                                            const std::vector<uint8_t>& frame);
  static void decode_rust_server_frames(const std::string& input);
};

}  // namespace twilic
