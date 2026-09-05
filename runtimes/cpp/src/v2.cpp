#include "twilic/v2.hpp"

#include <optional>
#include <sstream>

#include "twilic/errors.hpp"

namespace twilic {

namespace {

constexpr uint8_t kNullTag = 0xC0;
constexpr uint8_t kFalseTag = 0xC1;
constexpr uint8_t kTrueTag = 0xC2;
constexpr uint8_t kF64Tag = 0xC3;
constexpr uint8_t kU8Tag = 0xC4;
constexpr uint8_t kU16Tag = 0xC5;
constexpr uint8_t kU32Tag = 0xC6;
constexpr uint8_t kU64Tag = 0xC7;
constexpr uint8_t kI8Tag = 0xC8;
constexpr uint8_t kI16Tag = 0xC9;
constexpr uint8_t kI32Tag = 0xCA;
constexpr uint8_t kI64Tag = 0xCB;
constexpr uint8_t kBin8Tag = 0xCC;
constexpr uint8_t kBin16Tag = 0xCD;
constexpr uint8_t kBin32Tag = 0xCE;
constexpr uint8_t kStr8Tag = 0xCF;
constexpr uint8_t kStr16Tag = 0xD0;
constexpr uint8_t kStr32Tag = 0xD1;
constexpr uint8_t kArray16Tag = 0xD2;
constexpr uint8_t kArray32Tag = 0xD3;
constexpr uint8_t kMap16Tag = 0xD4;
constexpr uint8_t kMap32Tag = 0xD5;
constexpr uint8_t kShapeDefTag = 0xD6;
constexpr uint8_t kKeyRefTag = 0xD8;
constexpr uint8_t kStrRefTag = 0xD9;

struct V2EncodeState {
  std::unordered_map<std::string, int> key_ids;
  std::unordered_map<std::string, int> str_ids;
  std::unordered_map<std::string, int> shape_ids;
  int next_key_id = 0;
  int next_str_id = 0;
  int next_shape_id = 0;
};

struct V2DecodeState {
  std::vector<std::string> keys;
  std::vector<std::string> strings;
  std::vector<std::optional<std::vector<std::string>>> shapes;
};

std::string shape_key(const std::vector<std::string>& keys) {
  std::ostringstream oss;
  for (size_t i = 0; i < keys.size(); ++i) {
    if (i > 0) oss << '\0';
    oss << keys[i];
  }
  return oss.str();
}

void encode_v2_value(const Value& value, Buffer& out, V2EncodeState& state);
Value decode_v2_value(Reader& reader, V2DecodeState& state);
Value decode_v2_value_from_tag(Reader& reader, V2DecodeState& state, uint8_t tag);
Value decode_v2_array_body(Reader& reader, V2DecodeState& state, size_t length);
Value decode_v2_map_body(Reader& reader, V2DecodeState& state, size_t length);
std::string decode_v2_key(Reader& reader, V2DecodeState& state);
Value decode_v2_string_tag(Reader& reader, V2DecodeState& state, uint8_t tag);

void encode_v2_string_literal(const std::string& value, Buffer& out) {
  const auto raw = std::vector<uint8_t>(value.begin(), value.end());
  const size_t length = raw.size();
  if (length <= 31) {
    out.push_back(static_cast<uint8_t>(0x80 | length));
  } else if (length <= 0xFF) {
    out.push_back(kStr8Tag);
    out.push_back(static_cast<uint8_t>(length));
  } else if (length <= 0xFFFF) {
    out.push_back(kStr16Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
  } else {
    out.push_back(kStr32Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 24) & 0xFF));
  }
  out.insert(out.end(), raw.begin(), raw.end());
}

void encode_v2_binary(const std::vector<uint8_t>& value, Buffer& out) {
  const size_t length = value.size();
  if (length <= 0xFF) {
    out.push_back(kBin8Tag);
    out.push_back(static_cast<uint8_t>(length));
  } else if (length <= 0xFFFF) {
    out.push_back(kBin16Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
  } else {
    out.push_back(kBin32Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 24) & 0xFF));
  }
  out.insert(out.end(), value.begin(), value.end());
}

void encode_v2_u64(uint64_t value, Buffer& out) {
  if (value <= 127) {
    out.push_back(static_cast<uint8_t>(value));
  } else if (value <= 0xFF) {
    out.push_back(kU8Tag);
    out.push_back(static_cast<uint8_t>(value));
  } else if (value <= 0xFFFF) {
    out.push_back(kU16Tag);
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
  } else if (value <= 0xFFFFFFFFULL) {
    out.push_back(kU32Tag);
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
  } else {
    out.push_back(kU64Tag);
    append_u64_le(out, value);
  }
}

void encode_v2_i64(int64_t value, Buffer& out) {
  if (value >= -32 && value <= -1) {
    out.push_back(static_cast<uint8_t>(value & 0xFF));
  } else if (value >= 0 && value <= 127) {
    out.push_back(static_cast<uint8_t>(value));
  } else if (value >= -128 && value <= 127) {
    out.push_back(kI8Tag);
    out.push_back(static_cast<uint8_t>(value & 0xFF));
  } else if (value >= -32768 && value <= 32767) {
    out.push_back(kI16Tag);
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
  } else if (value >= -2147483648LL && value <= 2147483647LL) {
    out.push_back(kI32Tag);
    const auto u = static_cast<uint32_t>(value);
    out.push_back(static_cast<uint8_t>(u & 0xFF));
    out.push_back(static_cast<uint8_t>((u >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((u >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((u >> 24) & 0xFF));
  } else {
    out.push_back(kI64Tag);
    append_u64_le(out, static_cast<uint64_t>(value));
  }
}

void write_v2_array_header(size_t length, Buffer& out) {
  if (length <= 15) {
    out.push_back(static_cast<uint8_t>(0xA0 | length));
  } else if (length <= 0xFFFF) {
    out.push_back(kArray16Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
  } else {
    out.push_back(kArray32Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 24) & 0xFF));
  }
}

void write_v2_map_header(size_t length, Buffer& out) {
  if (length <= 15) {
    out.push_back(static_cast<uint8_t>(0xB0 | length));
  } else if (length <= 0xFFFF) {
    out.push_back(kMap16Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
  } else {
    out.push_back(kMap32Tag);
    out.push_back(static_cast<uint8_t>(length & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((length >> 24) & 0xFF));
  }
}

std::optional<std::vector<std::string>> detect_shape_keys(const std::vector<Value>& values) {
  if (values.size() < 2) return std::nullopt;
  if (values[0].kind != ValueKind::Map || values[0].map.empty()) return std::nullopt;
  std::vector<std::string> keys;
  keys.reserve(values[0].map.size());
  for (const auto& e : values[0].map) keys.push_back(e.key);
  for (size_t i = 1; i < values.size(); ++i) {
    const auto& value = values[i];
    if (value.kind != ValueKind::Map || value.map.size() != keys.size()) return std::nullopt;
    for (size_t j = 0; j < keys.size(); ++j) {
      if (value.map[j].key != keys[j]) return std::nullopt;
    }
  }
  return keys;
}

void encode_v2_key(const std::string& key, Buffer& out, V2EncodeState& state) {
  const auto it = state.key_ids.find(key);
  if (it != state.key_ids.end()) {
    out.push_back(kKeyRefTag);
    encode_varuint(static_cast<uint64_t>(it->second), out);
    return;
  }
  encode_v2_string_literal(key, out);
  state.key_ids[key] = state.next_key_id++;
}

void encode_v2_map(const std::vector<MapEntry>& entries, Buffer& out, V2EncodeState& state) {
  write_v2_map_header(entries.size(), out);
  for (const auto& e : entries) {
    encode_v2_key(e.key, out, state);
    encode_v2_value(e.value, out, state);
  }
}

void encode_v2_array(const std::vector<Value>& values, Buffer& out, V2EncodeState& state) {
  const auto shape_keys = detect_shape_keys(values);
  if (shape_keys) {
    const auto sk = shape_key(*shape_keys);
    int shape_id = 0;
    const auto it = state.shape_ids.find(sk);
    if (it != state.shape_ids.end()) {
      shape_id = it->second;
    } else {
      shape_id = state.next_shape_id++;
      state.shape_ids[sk] = shape_id;
    }
    write_v2_array_header(values.size(), out);
    out.push_back(kShapeDefTag);
    encode_varuint(static_cast<uint64_t>(shape_id), out);
    encode_varuint(shape_keys->size(), out);
    for (const auto& key : *shape_keys) encode_v2_key(key, out, state);
    for (const auto& value : values) {
      if (value.kind != ValueKind::Map) throw invalid_data("shape array row must be map");
      for (const auto& field : value.map) encode_v2_value(field.value, out, state);
    }
    return;
  }
  write_v2_array_header(values.size(), out);
  for (const auto& value : values) encode_v2_value(value, out, state);
}

void encode_v2_value(const Value& value, Buffer& out, V2EncodeState& state) {
  switch (value.kind) {
    case ValueKind::Null:
      out.push_back(kNullTag);
      break;
    case ValueKind::Bool:
      out.push_back(value.bool_value ? kTrueTag : kFalseTag);
      break;
    case ValueKind::I64:
      encode_v2_i64(value.i64, out);
      break;
    case ValueKind::U64:
      encode_v2_u64(value.u64, out);
      break;
    case ValueKind::F64:
      out.push_back(kF64Tag);
      append_f64_le(out, value.f64);
      break;
    case ValueKind::String: {
      const auto it = state.str_ids.find(value.str);
      if (it != state.str_ids.end()) {
        out.push_back(kStrRefTag);
        encode_varuint(static_cast<uint64_t>(it->second), out);
      } else {
        encode_v2_string_literal(value.str, out);
        state.str_ids[value.str] = state.next_str_id++;
      }
      break;
    }
    case ValueKind::Binary:
      encode_v2_binary(value.bin, out);
      break;
    case ValueKind::Array:
      encode_v2_array(value.arr, out, state);
      break;
    case ValueKind::Map:
      encode_v2_map(value.map, out, state);
      break;
  }
}

Value decode_v2_string_tag(Reader& reader, V2DecodeState& state, uint8_t tag) {
  size_t length = 0;
  if (tag == kStr8Tag) {
    length = reader.read_u8();
  } else if (tag == kStr16Tag) {
    const auto b = reader.read_exact(2);
    length = b[0] | (static_cast<size_t>(b[1]) << 8);
  } else if (tag == kStr32Tag) {
    const auto b = reader.read_exact(4);
    length = b[0] | (static_cast<size_t>(b[1]) << 8) | (static_cast<size_t>(b[2]) << 16) |
             (static_cast<size_t>(b[3]) << 24);
  } else {
    throw invalid_data("invalid string tag");
  }
  const auto raw = reader.read_exact(length);
  const std::string s(raw.begin(), raw.end());
  state.strings.push_back(s);
  return new_string(s);
}

std::string decode_v2_key(Reader& reader, V2DecodeState& state) {
  const uint8_t tag = reader.read_u8();
  if (tag == kKeyRefTag) {
    const auto ref_id = reader.read_varuint();
    if (ref_id >= state.keys.size()) throw invalid_data("unknown key_ref id");
    return state.keys[static_cast<size_t>(ref_id)];
  }
  if (tag >= 0x80 && tag <= 0x9F) {
    const auto key_bytes = reader.read_exact(tag & 0x1F);
    const std::string key(key_bytes.begin(), key_bytes.end());
    state.keys.push_back(key);
    return key;
  }
  if (tag == kStr8Tag || tag == kStr16Tag || tag == kStr32Tag) {
    const auto v = decode_v2_string_tag(reader, state, tag);
    if (v.kind != ValueKind::String) throw invalid_data("expected string key");
    state.keys.push_back(v.str);
    return v.str;
  }
  throw invalid_data("map key must be key_ref or string");
}

Value decode_v2_map_body(Reader& reader, V2DecodeState& state, size_t length) {
  DecodeDepthGuard depth(reader);
  reader.claim_output(length);
  std::vector<MapEntry> entries;
  entries.reserve(length);
  for (size_t i = 0; i < length; ++i) {
    const auto key = decode_v2_key(reader, state);
    entries.push_back(entry(key, decode_v2_value(reader, state)));
  }
  return new_map(std::move(entries));
}

Value decode_v2_array_body(Reader& reader, V2DecodeState& state, size_t length) {
  DecodeDepthGuard depth(reader);
  reader.claim_output(length);
  if (length == 0) return new_array({});
  const uint8_t first_tag = reader.read_u8();
  if (first_tag == kShapeDefTag) {
    const auto shape_id = reader.read_count(65535);
    const auto key_count = reader.read_count(256);
    std::vector<std::string> keys;
    keys.reserve(static_cast<size_t>(key_count));
    for (uint64_t i = 0; i < key_count; ++i) keys.push_back(decode_v2_key(reader, state));
    while (state.shapes.size() <= shape_id) state.shapes.emplace_back();
    state.shapes[static_cast<size_t>(shape_id)] = keys;
    std::vector<Value> values;
    values.reserve(length);
    for (size_t i = 0; i < length; ++i) {
      std::vector<MapEntry> row;
      row.reserve(keys.size());
      reader.claim_output(keys.size());
      for (const auto& key : keys) {
        reader.claim_output(key.size(), 1);
        row.push_back(entry(key, decode_v2_value(reader, state)));
      }
      values.push_back(new_map(std::move(row)));
    }
    return new_array(std::move(values));
  }
  std::vector<Value> values;
  values.reserve(length);
  values.push_back(decode_v2_value_from_tag(reader, state, first_tag));
  for (size_t i = 1; i < length; ++i) values.push_back(decode_v2_value(reader, state));
  return new_array(std::move(values));
}

Value decode_v2_value_from_tag(Reader& reader, V2DecodeState& state, uint8_t tag) {
  if (tag <= 0x7F) return new_u64(tag);
  if (tag >= 0x80 && tag <= 0x9F) {
    const auto length = tag & 0x1F;
    const auto raw = reader.read_exact(length);
    const std::string s(raw.begin(), raw.end());
    state.strings.push_back(s);
    return new_string(s);
  }
  if (tag >= 0xA0 && tag <= 0xAF) return decode_v2_array_body(reader, state, tag & 0x0F);
  if (tag >= 0xB0 && tag <= 0xBF) return decode_v2_map_body(reader, state, tag & 0x0F);
  if (tag >= 0xE0) return new_i64(tag < 128 ? static_cast<int64_t>(tag) : static_cast<int64_t>(tag) - 256);
  switch (tag) {
    case kNullTag:
      return new_null();
    case kFalseTag:
      return new_bool(false);
    case kTrueTag:
      return new_bool(true);
    case kF64Tag:
      return new_f64(read_f64_le(reader));
    case kU8Tag:
      return new_u64(reader.read_u8());
    case kU16Tag: {
      const auto b = reader.read_exact(2);
      return new_u64(b[0] | (static_cast<uint64_t>(b[1]) << 8));
    }
    case kU32Tag: {
      const auto b = reader.read_exact(4);
      return new_u64(b[0] | (static_cast<uint64_t>(b[1]) << 8) | (static_cast<uint64_t>(b[2]) << 16) |
                     (static_cast<uint64_t>(b[3]) << 24));
    }
    case kU64Tag:
      return new_u64(read_u64_le(reader));
    case kI8Tag: {
      const auto b = reader.read_u8();
      return new_i64(b < 128 ? static_cast<int64_t>(b) : static_cast<int64_t>(b) - 256);
    }
    case kI16Tag: {
      const auto b = reader.read_exact(2);
      const int16_t v = static_cast<int16_t>(b[0] | (static_cast<int16_t>(b[1]) << 8));
      return new_i64(v);
    }
    case kI32Tag: {
      const auto b = reader.read_exact(4);
      const int32_t v = static_cast<int32_t>(b[0] | (static_cast<int32_t>(b[1]) << 8) |
                                            (static_cast<int32_t>(b[2]) << 16) |
                                            (static_cast<int32_t>(b[3]) << 24));
      return new_i64(v);
    }
    case kI64Tag: {
      const auto u = read_u64_le(reader);
      return new_i64(static_cast<int64_t>(u));
    }
    case kBin8Tag:
      return new_binary(reader.read_exact(reader.read_u8()));
    case kBin16Tag: {
      const auto b = reader.read_exact(2);
      const size_t n = b[0] | (static_cast<size_t>(b[1]) << 8);
      return new_binary(reader.read_exact(n));
    }
    case kBin32Tag: {
      const auto b = reader.read_exact(4);
      const size_t n = b[0] | (static_cast<size_t>(b[1]) << 8) | (static_cast<size_t>(b[2]) << 16) |
                     (static_cast<size_t>(b[3]) << 24);
      return new_binary(reader.read_exact(n));
    }
    case kStr8Tag:
    case kStr16Tag:
    case kStr32Tag:
      return decode_v2_string_tag(reader, state, tag);
    case kArray16Tag: {
      const auto b = reader.read_exact(2);
      return decode_v2_array_body(reader, state, b[0] | (static_cast<size_t>(b[1]) << 8));
    }
    case kArray32Tag: {
      const auto b = reader.read_exact(4);
      const size_t n = b[0] | (static_cast<size_t>(b[1]) << 8) | (static_cast<size_t>(b[2]) << 16) |
                     (static_cast<size_t>(b[3]) << 24);
      return decode_v2_array_body(reader, state, n);
    }
    case kMap16Tag: {
      const auto b = reader.read_exact(2);
      return decode_v2_map_body(reader, state, b[0] | (static_cast<size_t>(b[1]) << 8));
    }
    case kMap32Tag: {
      const auto b = reader.read_exact(4);
      const size_t n = b[0] | (static_cast<size_t>(b[1]) << 8) | (static_cast<size_t>(b[2]) << 16) |
                     (static_cast<size_t>(b[3]) << 24);
      return decode_v2_map_body(reader, state, n);
    }
    case kStrRefTag: {
      const auto ref_id = reader.read_varuint();
      if (ref_id >= state.strings.size()) throw invalid_data("unknown str_ref id");
      reader.claim_output(state.strings[static_cast<size_t>(ref_id)].size(), 1);
      return new_string(state.strings[static_cast<size_t>(ref_id)]);
    }
    default:
      throw invalid_tag(tag);
  }
}

Value decode_v2_value(Reader& reader, V2DecodeState& state) {
  return decode_v2_value_from_tag(reader, state, reader.read_u8());
}

}  // namespace

std::vector<uint8_t> encode_v2(const Value& value) {
  Buffer out;
  V2EncodeState state;
  encode_v2_value(value, out, state);
  return out;
}

Value decode_v2(const std::vector<uint8_t>& data) {
  Reader reader(data);
  V2DecodeState state;
  const auto value = decode_v2_value(reader, state);
  if (!reader.is_eof()) throw invalid_data("trailing bytes in v2 decode");
  return value;
}

}  // namespace twilic
