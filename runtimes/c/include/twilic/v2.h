#pragma once
#include <string>
#include <unordered_map>
#include <vector>

#include "twilic/model.h"
#include "twilic/wire.h"

namespace twilic {

std::vector<uint8_t> encode_v2(const Value& value);
Value decode_v2(const std::vector<uint8_t>& data);

}  // namespace twilic
