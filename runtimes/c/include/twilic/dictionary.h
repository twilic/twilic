#pragma once
#include <cstdint>
#include <string>
#include <vector>

#include "twilic/session.h"
#include "twilic/wire.h"

namespace twilic {

std::vector<std::string> decode_trained_dictionary_payload(const std::vector<uint8_t>& payload);
uint64_t dictionary_payload_hash(const std::vector<uint8_t>& payload);
void apply_dictionary_references(SessionState& state);

}  // namespace twilic
