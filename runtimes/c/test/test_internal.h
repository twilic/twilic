#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include "twilic/errors.h"
#include "twilic/interop_fixtures.h"
#include "twilic/model.h"
#include "twilic/protocol.h"
#include "twilic/session.h"
#include "twilic/wire.h"

namespace twilic_test {

using namespace twilic;

inline TwilicCodec make_codec() { return new_twilic_codec(); }

inline SessionEncoder make_encoder() { return new_session_encoder(std::nullopt); }

inline Value id_name_map(uint64_t id, const std::string &name) {
  return new_map({entry("id", new_u64(id)), entry("name", new_string(name))});
}

inline Value id_name_role_map(uint64_t id, const std::string &name, const std::string &role) {
  return new_map({entry("id", new_u64(id)), entry("name", new_string(name)), entry("role", new_string(role))});
}

inline std::vector<Value> make_i64_array(int length, int64_t start) {
  std::vector<Value> out;
  out.reserve(static_cast<size_t>(length));
  for (int i = 0; i < length; ++i) out.push_back(new_i64(start + i));
  return out;
}

inline uint8_t scalar_string_mode(const std::vector<uint8_t> &bytes) {
  if (bytes.size() < 3) throw std::runtime_error("expected at least 3 bytes");
  if (bytes[0] != static_cast<uint8_t>(MessageKind::Scalar)) throw std::runtime_error("expected scalar kind");
  if (bytes[1] != 6) throw std::runtime_error("expected string tag");
  return bytes[2];
}

}  // namespace twilic_test
