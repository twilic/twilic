#include "twilic/codec.hpp"

#include <algorithm>
#include <limits>

#include "twilic/errors.hpp"

namespace twilic {

namespace {

int bit_width(uint64_t v) {
  if (v == 0) return 1;
  int w = 0;
  while (v > 0) {
    ++w;
    v >>= 1;
  }
  return w;
}

void pack_u64_values(const std::vector<uint64_t>& values, int width, Buffer& out) {
  const size_t total_bits = values.size() * static_cast<size_t>(width);
  const size_t byte_len = (total_bits + 7) / 8;
  std::vector<uint8_t> bytes(byte_len, 0);
  size_t bit_pos = 0;
  for (const auto value : values) {
    int written = 0;
    while (written < width) {
      const size_t byte_idx = bit_pos / 8;
      const int bit_off = static_cast<int>(bit_pos % 8);
      const int room = 8 - bit_off;
      const int take = std::min(width - written, room);
      const uint64_t mask = (take >= 64) ? ~0ULL : ((1ULL << take) - 1);
      const uint64_t part = (value >> written) & mask;
      bytes[byte_idx] |= static_cast<uint8_t>(part << bit_off);
      bit_pos += static_cast<size_t>(take);
      written += take;
    }
  }
  out.insert(out.end(), bytes.begin(), bytes.end());
}

std::vector<uint64_t> unpack_u64_values(Reader& reader, size_t length, int width) {
  const size_t total_bits = length * static_cast<size_t>(width);
  const size_t byte_len = (total_bits + 7) / 8;
  const auto raw = reader.read_exact(byte_len);
  std::vector<uint64_t> out;
  out.reserve(length);
  size_t bit_pos = 0;
  for (size_t i = 0; i < length; ++i) {
    uint64_t value = 0;
    int written = 0;
    while (written < width) {
      const size_t byte_idx = bit_pos / 8;
      const int bit_off = static_cast<int>(bit_pos % 8);
      const int room = 8 - bit_off;
      const int take = std::min(width - written, room);
      const uint64_t mask = (take >= 64) ? ~0ULL : ((1ULL << take) - 1);
      const uint64_t part = (raw[byte_idx] >> bit_off) & mask;
      value |= part << written;
      bit_pos += static_cast<size_t>(take);
      written += take;
    }
    out.push_back(value);
  }
  return out;
}

void encode_u64_plain(const std::vector<uint64_t>& values, Buffer& out) {
  encode_varuint(values.size(), out);
  for (const auto value : values) encode_varuint(value, out);
}

std::vector<uint64_t> decode_u64_plain(Reader& reader) {
  const auto length = reader.read_count();
  std::vector<uint64_t> out;
  out.reserve(static_cast<size_t>(length));
  for (uint64_t i = 0; i < length; ++i) out.push_back(reader.read_varuint());
  return out;
}

void encode_u64_rle(const std::vector<uint64_t>& values, Buffer& out) {
  std::vector<std::pair<uint64_t, uint64_t>> runs;
  for (const auto value : values) {
    if (!runs.empty() && runs.back().first == value) {
      runs.back().second += 1;
    } else {
      runs.emplace_back(value, 1);
    }
  }
  encode_varuint(runs.size(), out);
  for (const auto& [val, count] : runs) {
    encode_varuint(val, out);
    encode_varuint(count, out);
  }
}

std::vector<uint64_t> decode_u64_rle(Reader& reader) {
  const auto runs_len = reader.read_count();
  std::vector<uint64_t> out;
  for (uint64_t i = 0; i < runs_len; ++i) {
    const auto value = reader.read_varuint();
    const auto count = reader.read_count();
    for (uint64_t j = 0; j < count; ++j) out.push_back(value);
  }
  return out;
}

void encode_u64_direct_bitpack(const std::vector<uint64_t>& values, Buffer& out) {
  encode_varuint(values.size(), out);
  if (values.empty()) {
    out.push_back(0);
    return;
  }
  int width = 1;
  for (const auto v : values) width = std::max(width, bit_width(v));
  out.push_back(static_cast<uint8_t>(width));
  pack_u64_values(values, width, out);
}

std::vector<uint64_t> decode_u64_direct_bitpack(Reader& reader) {
  const auto length = reader.read_count();
  const auto width = reader.read_u8();
  if (length == 0) return {};
  if (width == 0 || width > 64) throw invalid_data("bitpack width");
  return unpack_u64_values(reader, static_cast<size_t>(length), static_cast<int>(width));
}

std::vector<int64_t> delta_values(const std::vector<int64_t>& values) {
  std::vector<int64_t> out;
  out.reserve(values.size());
  int64_t prev = 0;
  for (size_t i = 0; i < values.size(); ++i) {
    if (i == 0) {
      out.push_back(values[i]);
    } else {
      out.push_back(values[i] - prev);
    }
    prev = values[i];
  }
  return out;
}

bool checked_add_i64(int64_t a, int64_t b, int64_t& out) {
  if (b > 0 && a > std::numeric_limits<int64_t>::max() - b) return false;
  if (b < 0 && a < std::numeric_limits<int64_t>::min() - b) return false;
  out = a + b;
  return true;
}

std::vector<int64_t> undelta_values(const std::vector<int64_t>& values) {
  std::vector<int64_t> out;
  out.reserve(values.size());
  int64_t prev = 0;
  for (size_t i = 0; i < values.size(); ++i) {
    if (i == 0) {
      out.push_back(values[i]);
      prev = values[i];
      continue;
    }
    int64_t next = 0;
    if (!checked_add_i64(prev, values[i], next)) throw invalid_data("undelta overflow");
    out.push_back(next);
    prev = next;
  }
  return out;
}

void encode_i64_plain(const std::vector<int64_t>& values, Buffer& out) {
  encode_varuint(values.size(), out);
  for (const auto v : values) encode_varuint(encode_zigzag(v), out);
}

std::vector<int64_t> decode_i64_plain(Reader& reader) {
  const auto length = reader.read_count();
  std::vector<int64_t> out;
  out.reserve(static_cast<size_t>(length));
  for (uint64_t i = 0; i < length; ++i) out.push_back(decode_zigzag(reader.read_varuint()));
  return out;
}

void encode_i64_rle(const std::vector<int64_t>& values, Buffer& out) {
  struct Run {
    int64_t value;
    uint64_t count;
  };
  std::vector<Run> runs;
  for (const auto v : values) {
    if (!runs.empty() && runs.back().value == v) {
      runs.back().count += 1;
    } else {
      runs.push_back({v, 1});
    }
  }
  encode_varuint(runs.size(), out);
  for (const auto& run : runs) {
    encode_varuint(encode_zigzag(run.value), out);
    encode_varuint(run.count, out);
  }
}

std::vector<int64_t> decode_i64_rle(Reader& reader) {
  const auto runs_len = reader.read_count();
  std::vector<int64_t> out;
  for (uint64_t i = 0; i < runs_len; ++i) {
    const auto value = decode_zigzag(reader.read_varuint());
    const auto count = reader.read_count();
    for (uint64_t j = 0; j < count; ++j) out.push_back(value);
  }
  return out;
}

void encode_i64_direct_bitpack(const std::vector<int64_t>& values, Buffer& out) {
  std::vector<uint64_t> encoded;
  encoded.reserve(values.size());
  int width = 1;
  for (const auto v : values) {
    const auto enc = encode_zigzag(v);
    encoded.push_back(enc);
    width = std::max(width, bit_width(enc));
  }
  encode_varuint(values.size(), out);
  if (values.empty()) {
    out.push_back(0);
    return;
  }
  out.push_back(static_cast<uint8_t>(width));
  pack_u64_values(encoded, width, out);
}

std::vector<int64_t> decode_i64_direct_bitpack(Reader& reader) {
  const auto encoded = decode_u64_direct_bitpack(reader);
  std::vector<int64_t> out;
  out.reserve(encoded.size());
  for (const auto v : encoded) out.push_back(decode_zigzag(v));
  return out;
}

void encode_i64_delta_delta(const std::vector<int64_t>& values, Buffer& out) {
  encode_varuint(values.size(), out);
  if (values.empty()) return;
  encode_varuint(encode_zigzag(values[0]), out);
  if (values.size() == 1) return;
  const int64_t d1 = values[1] - values[0];
  encode_varuint(encode_zigzag(d1), out);
  std::vector<int64_t> dd;
  dd.reserve(values.size() - 2);
  int64_t prev_delta = d1;
  for (size_t i = 1; i + 1 < values.size(); ++i) {
    const int64_t d = values[i + 1] - values[i];
    dd.push_back(d - prev_delta);
    prev_delta = d;
  }
  encode_i64_direct_bitpack(dd, out);
}

std::vector<int64_t> decode_i64_delta_delta(Reader& reader) {
  const auto len = reader.read_count();
  if (len == 0) return {};
  const auto first = decode_zigzag(reader.read_varuint());
  if (len == 1) return {first};
  const auto first_delta = decode_zigzag(reader.read_varuint());
  const auto dd = decode_i64_direct_bitpack(reader);
  if (dd.size() != len - 2) throw invalid_data("delta-delta length");
  std::vector<int64_t> out;
  out.reserve(static_cast<size_t>(len));
  out.push_back(first);
  int64_t prev = first;
  int64_t second = 0;
  if (!checked_add_i64(prev, first_delta, second)) throw invalid_data("delta-delta overflow");
  out.push_back(second);
  prev = second;
  int64_t prev_delta = first_delta;
  for (const auto ddv : dd) {
    int64_t d = 0;
    int64_t next = 0;
    if (!checked_add_i64(prev_delta, ddv, d)) throw invalid_data("delta-delta overflow");
    if (!checked_add_i64(prev, d, next)) throw invalid_data("delta-delta overflow");
    out.push_back(next);
    prev = next;
    prev_delta = d;
  }
  return out;
}

}  // namespace

void encode_u64_vector(const std::vector<uint64_t>& values, VectorCodec codec, Buffer& out) {
  switch (codec) {
    case VectorCodec::Rle:
      encode_u64_rle(values, out);
      break;
    case VectorCodec::DirectBitpack:
      encode_u64_direct_bitpack(values, out);
      break;
    case VectorCodec::ForBitpack:
      if (values.empty()) {
        encode_varuint(0, out);
        return;
      }
      {
        const auto min_value = *std::min_element(values.begin(), values.end());
        encode_varuint(min_value, out);
        std::vector<uint64_t> shifted;
        shifted.reserve(values.size());
        for (const auto v : values) shifted.push_back(v - min_value);
        encode_u64_direct_bitpack(shifted, out);
      }
      break;
    default:
      encode_u64_plain(values, out);
      break;
  }
}

std::vector<uint64_t> decode_u64_vector(Reader& reader, VectorCodec codec) {
  switch (codec) {
    case VectorCodec::Rle:
      return decode_u64_rle(reader);
    case VectorCodec::DirectBitpack:
      return decode_u64_direct_bitpack(reader);
    case VectorCodec::ForBitpack: {
      const auto min_value = reader.read_varuint();
      if (reader.is_eof()) return {};
      const auto shifted = decode_u64_direct_bitpack(reader);
      std::vector<uint64_t> out;
      out.reserve(shifted.size());
      for (const auto v : shifted) out.push_back(v + min_value);
      return out;
    }
    default:
      return decode_u64_plain(reader);
  }
}

void encode_i64_vector(const std::vector<int64_t>& values, VectorCodec codec, Buffer& out) {
  switch (codec) {
    case VectorCodec::Rle:
      encode_i64_rle(values, out);
      break;
    case VectorCodec::DirectBitpack:
      encode_i64_direct_bitpack(values, out);
      break;
    case VectorCodec::DeltaBitpack:
      encode_i64_direct_bitpack(delta_values(values), out);
      break;
    case VectorCodec::ForBitpack:
      if (values.empty()) {
        encode_varuint(0, out);
        return;
      }
      {
        const auto min_value = *std::min_element(values.begin(), values.end());
        encode_varuint(encode_zigzag(min_value), out);
        std::vector<int64_t> shifted;
        shifted.reserve(values.size());
        for (const auto v : values) shifted.push_back(v - min_value);
        encode_i64_direct_bitpack(shifted, out);
      }
      break;
    case VectorCodec::DeltaForBitpack: {
      const auto delta_vals = delta_values(values);
      if (delta_vals.empty()) {
        encode_varuint(0, out);
        return;
      }
      const auto min_value = *std::min_element(delta_vals.begin(), delta_vals.end());
      encode_varuint(encode_zigzag(min_value), out);
      std::vector<int64_t> shifted;
      shifted.reserve(delta_vals.size());
      for (const auto v : delta_vals) shifted.push_back(v - min_value);
      encode_i64_direct_bitpack(shifted, out);
      break;
    }
    case VectorCodec::DeltaDeltaBitpack:
      encode_i64_delta_delta(values, out);
      break;
    case VectorCodec::Plain:
    default:
      encode_i64_plain(values, out);
      break;
  }
}

std::vector<int64_t> decode_i64_vector(Reader& reader, VectorCodec codec) {
  switch (codec) {
    case VectorCodec::Rle:
      return decode_i64_rle(reader);
    case VectorCodec::DirectBitpack:
      return decode_i64_direct_bitpack(reader);
    case VectorCodec::DeltaBitpack:
      return undelta_values(decode_i64_direct_bitpack(reader));
    case VectorCodec::ForBitpack: {
      const auto min_value = decode_zigzag(reader.read_varuint());
      if (reader.is_eof()) return {};
      const auto shifted = decode_i64_direct_bitpack(reader);
      std::vector<int64_t> out;
      out.reserve(shifted.size());
      for (const auto v : shifted) out.push_back(v + min_value);
      return out;
    }
    case VectorCodec::DeltaForBitpack: {
      const auto min_value = decode_zigzag(reader.read_varuint());
      if (reader.is_eof()) return {};
      const auto shifted = decode_i64_direct_bitpack(reader);
      std::vector<int64_t> deltas;
      deltas.reserve(shifted.size());
      for (const auto v : shifted) deltas.push_back(v + min_value);
      return undelta_values(deltas);
    }
    case VectorCodec::DeltaDeltaBitpack:
      return decode_i64_delta_delta(reader);
    case VectorCodec::Plain:
    default:
      return decode_i64_plain(reader);
  }
}

void encode_f64_vector(const std::vector<double>& values, VectorCodec, Buffer& out) {
  encode_varuint(values.size(), out);
  for (const auto v : values) append_f64_le(out, v);
}

std::vector<double> decode_f64_vector(Reader& reader, VectorCodec) {
  const auto length = reader.read_count();
  std::vector<double> out;
  out.reserve(static_cast<size_t>(length));
  for (uint64_t i = 0; i < length; ++i) out.push_back(read_f64_le(reader));
  return out;
}

}  // namespace twilic
