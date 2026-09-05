#pragma once
#include <cstdint>
#include <vector>

#include "twilic/model.h"
#include "twilic/wire.h"

namespace twilic {

void encode_u64_vector(const std::vector<uint64_t>& values, VectorCodec codec, Buffer& out);
std::vector<uint64_t> decode_u64_vector(Reader& reader, VectorCodec codec);

void encode_i64_vector(const std::vector<int64_t>& values, VectorCodec codec, Buffer& out);
std::vector<int64_t> decode_i64_vector(Reader& reader, VectorCodec codec);

void encode_f64_vector(const std::vector<double>& values, VectorCodec codec, Buffer& out);
std::vector<double> decode_f64_vector(Reader& reader, VectorCodec codec);

}  // namespace twilic
