#include "twilic/dictionary.hpp"

#include "twilic/errors.hpp"

namespace twilic {

std::vector<std::string> decode_trained_dictionary_payload(const std::vector<uint8_t>& payload) {
  Reader reader(payload);
  const auto n = reader.read_count();
  std::vector<std::string> values;
  values.reserve(static_cast<size_t>(n));
  for (uint64_t i = 0; i < n; ++i) values.push_back(reader.read_string());
  if (!reader.is_eof()) throw invalid_data("trained dictionary payload trailing bytes");
  return values;
}

uint64_t dictionary_payload_hash(const std::vector<uint8_t>& payload) {
  uint64_t h = 0xCBF29CE484222325ULL;
  for (const auto b : payload) {
    h ^= b;
    h = (h * 0x100000001B3ULL) & 0xFFFFFFFFFFFFFFFFULL;
  }
  return h;
}

void apply_dictionary_references(SessionState&) {
  // Trained dictionary promotion stub (Dart subset).
}

}  // namespace twilic
