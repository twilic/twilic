#include "twilic/wire.h"

#include <cstring>
#include <algorithm>

#include "twilic/errors.h"

namespace twilic {

void encode_varuint(uint64_t value, Buffer& out) {
  if (value < 0x80) {
    out.push_back(static_cast<uint8_t>(value));
    return;
  }
  while (true) {
    uint8_t b = static_cast<uint8_t>(value & 0x7F);
    value >>= 7;
    if (value != 0) b |= 0x80;
    out.push_back(b);
    if (value == 0) break;
  }
}

uint64_t encode_zigzag(int64_t value) {
  return static_cast<uint64_t>((static_cast<uint64_t>(value) << 1) ^ static_cast<uint64_t>(value >> 63));
}

int64_t decode_zigzag(uint64_t value) {
  return static_cast<int64_t>((value >> 1) ^ (-(value & 1)));
}

void encode_bytes(const std::vector<uint8_t>& data, Buffer& out) {
  encode_varuint(data.size(), out);
  out.insert(out.end(), data.begin(), data.end());
}

void encode_string(const std::string& value, Buffer& out) {
  encode_bytes(std::vector<uint8_t>(value.begin(), value.end()), out);
}

void encode_bitmap(const std::vector<bool>& bits, Buffer& out) {
  encode_varuint(bits.size(), out);
  int current = 0;
  for (size_t i = 0; i < bits.size(); ++i) {
    if (bits[i]) current |= 1 << (i % 8);
    if (i % 8 == 7) {
      out.push_back(static_cast<uint8_t>(current));
      current = 0;
    }
  }
  if (bits.size() % 8 != 0) out.push_back(static_cast<uint8_t>(current));
}

Reader::Reader(const std::vector<uint8_t>& input) : input_(input),
    output_remaining_(std::min<size_t>(input.size(), 1024) * 1024) {}

void Reader::claim_output(uint64_t count, size_t width) {
  if (count > (1 << 20)) throw invalid_data("decode count limit exceeded");
  if (width == 0 || count > output_remaining_ / width) throw invalid_data("decode output ratio exceeded");
  output_remaining_ -= static_cast<size_t>(count) * width;
}

uint64_t Reader::read_count(uint64_t maximum) {
  const auto count = read_varuint();
  if (count > maximum) throw invalid_data("decode count limit exceeded");
  claim_output(count);
  return count;
}

void Reader::enter_depth() {
  if (depth_ >= 64) throw invalid_data("decode depth limit exceeded");
  ++depth_;
}
void Reader::leave_depth() { --depth_; }

size_t Reader::position() const { return offset_; }

bool Reader::is_eof() const { return offset_ >= input_.size(); }

uint8_t Reader::read_u8() {
  if (offset_ >= input_.size()) throw unexpected_eof();
  return input_[offset_++];
}

std::vector<uint8_t> Reader::read_exact(size_t n) {
  if (n > input_.size() - offset_) throw unexpected_eof();
  const size_t end = offset_ + n;
  std::vector<uint8_t> slice(input_.begin() + static_cast<std::ptrdiff_t>(offset_),
                             input_.begin() + static_cast<std::ptrdiff_t>(end));
  offset_ = end;
  return slice;
}

uint64_t Reader::read_varuint() {
  int shift = 0;
  uint64_t result = 0;
  while (true) {
    if (shift >= 64) throw invalid_data("varuint too large");
    const uint8_t b = read_u8();
    if (shift == 63 && (b & 0x7E)) throw invalid_data("varuint too large");
    result |= static_cast<uint64_t>(b & 0x7F) << shift;
    if ((b & 0x80) == 0) return result;
    shift += 7;
  }
}

int64_t Reader::read_i64_zigzag() { return decode_zigzag(read_varuint()); }

std::vector<uint8_t> Reader::read_bytes() {
  const auto n = read_varuint();
  if (n > input_.size() - offset_) throw unexpected_eof();
  return read_exact(static_cast<size_t>(n));
}

std::string Reader::read_string() {
  const auto n = read_varuint();
  if (n > input_.size() - offset_) throw unexpected_eof();
  const auto data = read_exact(static_cast<size_t>(n));
  return std::string(data.begin(), data.end());
}

std::vector<bool> Reader::read_bitmap() {
  const auto bit_count = read_count();
  const auto byte_count = (bit_count + 7) / 8;
  const auto raw = read_exact(byte_count);
  std::vector<bool> bits(bit_count, false);
  for (uint64_t i = 0; i < bit_count; ++i) {
    bits[static_cast<size_t>(i)] = ((raw[i / 8] >> (i % 8)) & 1) == 1;
  }
  return bits;
}

Reader new_reader(const std::vector<uint8_t>& input) { return Reader(input); }

uint64_t read_u64_le(Reader& reader) {
  const auto b = reader.read_exact(8);
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i) v |= static_cast<uint64_t>(b[static_cast<size_t>(i)]) << (8 * i);
  return v;
}

double read_f64_le(Reader& reader) {
  const uint64_t u = read_u64_le(reader);
  double d;
  std::memcpy(&d, &u, sizeof(d));
  return d;
}

void append_u64_le(Buffer& out, uint64_t v) {
  for (int i = 0; i < 8; ++i) out.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
}

void append_f64_le(Buffer& out, double v) {
  uint64_t u;
  std::memcpy(&u, &v, sizeof(u));
  append_u64_le(out, u);
}

}  // namespace twilic
