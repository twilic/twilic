#include "twilic/protocol.hpp"

#include <algorithm>
#include <unordered_map>

#include "twilic/codec.hpp"
#include "twilic/errors.hpp"
#include "twilic/protocol_helpers.hpp"
#include "twilic/v2.hpp"

namespace twilic {

namespace {

constexpr uint8_t kTagNull = 0;
constexpr uint8_t kTagBoolFalse = 1;
constexpr uint8_t kTagBoolTrue = 2;
constexpr uint8_t kTagI64 = 3;
constexpr uint8_t kTagU64 = 4;
constexpr uint8_t kTagF64 = 5;
constexpr uint8_t kTagString = 6;
constexpr uint8_t kTagBinary = 7;
constexpr uint8_t kTagArray = 8;
constexpr uint8_t kTagMap = 9;

}  // namespace

TwilicCodec::TwilicCodec(SessionState state) : state(std::move(state)) {}

Message TwilicCodec::map_message(const std::vector<MapEntry>& entries) {
  std::vector<MessageMapEntry> out;
  out.reserve(entries.size());
  for (const auto& e : entries) {
    const auto [ref_id, ok] = state.key_table.get_id(e.key);
    if (!ok) state.key_table.register_value(e.key);
    out.push_back({ok ? KeyRef::id_ref(ref_id) : KeyRef::literal_ref(e.key), e.value.clone()});
  }
  Message msg;
  msg.kind = MessageKind::Map;
  msg.map = std::move(out);
  return msg;
}

Message TwilicCodec::shaped_message(uint64_t shape_id, const std::vector<MapEntry>& entries) {
  const auto [keys, _] = state.shape_table.get_keys(shape_id);
  std::unordered_map<std::string, Value> index;
  for (const auto& e : entries) index[e.key] = e.value.clone();
  std::vector<Value> values;
  values.reserve(keys.size());
  for (const auto& k : keys) {
    const auto it = index.find(k);
    values.push_back(it != index.end() ? it->second : new_null());
  }
  Message msg;
  msg.kind = MessageKind::ShapedObject;
  msg.has_shaped_object = true;
  msg.shaped_object.shape_id = shape_id;
  msg.shaped_object.values = std::move(values);
  return msg;
}

void TwilicCodec::reference_error(const std::string& kind, uint64_t ref_id) const {
  if (state.options.unknown_reference_policy == UnknownReferencePolicy::StatelessRetry) {
    throw stateless_retry_required(kind, ref_id);
  }
  throw unknown_reference(kind, ref_id);
}

TwilicCodec::PrefixBaseMatch TwilicCodec::best_prefix_base(const std::string& value) const {
  PrefixBaseMatch match;
  for (size_t id = 0; id < state.string_table.by_id.size(); ++id) {
    const int n = common_prefix_len(value, state.string_table.by_id[id]);
    if (n > match.prefix_len) {
      match.prefix_len = n;
      match.base_id = id;
    }
  }
  if (match.prefix_len > 0) match.ok = true;
  return match;
}

int TwilicCodec::observe_encode_shape_candidate(const std::vector<std::string>& keys) {
  const auto sk = shape_key(keys);
  state.encode_shape_observations[sk] = state.encode_shape_observations[sk] + 1;
  const int count = state.encode_shape_observations[sk];
  if (should_register_shape(keys, count)) state.shape_table.register_keys(keys);
  return count;
}

void TwilicCodec::observe_decode_shape_candidate(const std::vector<std::string>& keys) {
  const auto [_, ok] = state.shape_table.get_id(keys);
  if (ok) return;
  const int observed = state.shape_table.observe(keys);
  if (should_register_shape(keys, observed)) state.shape_table.register_keys(keys);
}

std::optional<TypedVector> TwilicCodec::try_make_typed_vector(const std::vector<Value>& values) {
  if (values.size() < 4) return std::nullopt;
  const bool all_i64 = std::all_of(values.begin(), values.end(),
                                   [](const Value& v) { return v.kind == ValueKind::I64; });
  if (all_i64) {
    std::vector<int64_t> data;
    data.reserve(values.size());
    for (const auto& v : values) data.push_back(v.i64);
    TypedVector tv;
    tv.element_type = ElementType::I64;
    tv.codec = select_integer_codec(data);
    tv.data = typed_data_i64(data);
    return tv;
  }
  const bool all_u64 = std::all_of(values.begin(), values.end(),
                                   [](const Value& v) { return v.kind == ValueKind::U64; });
  if (all_u64) {
    std::vector<uint64_t> data;
    for (const auto& v : values) data.push_back(v.u64);
    TypedVector tv;
    tv.element_type = ElementType::U64;
    tv.codec = select_u64_codec(data);
    tv.data = typed_data_u64(data);
    return tv;
  }
  const bool all_bool = std::all_of(values.begin(), values.end(),
                                    [](const Value& v) { return v.kind == ValueKind::Bool; });
  if (all_bool) {
    std::vector<bool> data;
    for (const auto& v : values) data.push_back(v.bool_value);
    TypedVector tv;
    tv.element_type = ElementType::Bool;
    tv.codec = VectorCodec::DirectBitpack;
    tv.data = typed_data_bool(data);
    return tv;
  }
  const bool all_f64 = std::all_of(values.begin(), values.end(),
                                   [](const Value& v) { return v.kind == ValueKind::F64; });
  if (all_f64) {
    std::vector<double> data;
    for (const auto& v : values) data.push_back(v.f64);
    TypedVector tv;
    tv.element_type = ElementType::F64;
    tv.codec = select_float_codec(data);
    tv.data = typed_data_f64(data);
    return tv;
  }
  const bool all_str = std::all_of(values.begin(), values.end(),
                                   [](const Value& v) { return v.kind == ValueKind::String; });
  if (all_str) {
    std::vector<std::string> data;
    for (const auto& v : values) data.push_back(v.str);
    TypedVector tv;
    tv.element_type = ElementType::String;
    tv.codec = select_string_codec(data);
    tv.data = typed_data_string(data);
    return tv;
  }
  return std::nullopt;
}

Message TwilicCodec::message_for_value(const Value& value) {
  switch (value.kind) {
    case ValueKind::Array: {
      if (const auto tv = try_make_typed_vector(value.arr)) {
        Message msg;
        msg.kind = MessageKind::TypedVector;
        msg.has_typed_vector = true;
        msg.typed_vector = *tv;
        return msg;
      }
      Message msg;
      msg.kind = MessageKind::Array;
      msg.array.reserve(value.arr.size());
      for (const auto& v : value.arr) msg.array.push_back(v.clone());
      return msg;
    }
    case ValueKind::Map: {
      std::vector<std::string> keys;
      keys.reserve(value.map.size());
      for (const auto& e : value.map) keys.push_back(e.key);
      const auto sk = shape_key(keys);
      const bool had_observation = state.encode_shape_observations.count(sk) > 0;
      const int obs = observe_encode_shape_candidate(keys);
      const auto [shape_id, ok] = state.shape_table.get_id(keys);
      if (ok && (!had_observation || obs >= 2)) return shaped_message(shape_id, value.map);
      return map_message(value.map);
    }
    default: {
      Message msg;
      msg.kind = MessageKind::Scalar;
      msg.has_scalar = true;
      msg.scalar = value.clone();
      return msg;
    }
  }
}

void TwilicCodec::write_value(const Value& value, Buffer& out) {
  write_value_with_field(value, std::nullopt, out);
}

void TwilicCodec::write_value_with_field(const Value& value,
                                         const std::optional<std::string>& field_identity,
                                         Buffer& out) {
  switch (value.kind) {
    case ValueKind::Null:
      out.push_back(kTagNull);
      break;
    case ValueKind::Bool:
      out.push_back(value.bool_value ? kTagBoolTrue : kTagBoolFalse);
      break;
    case ValueKind::I64:
      out.push_back(kTagI64);
      write_smallest_u64(encode_zigzag(value.i64), out);
      break;
    case ValueKind::U64:
      out.push_back(kTagU64);
      write_smallest_u64(value.u64, out);
      break;
    case ValueKind::F64:
      out.push_back(kTagF64);
      append_f64_le(out, value.f64);
      break;
    case ValueKind::String: {
      out.push_back(kTagString);
      if (field_identity) {
        const auto it = state.field_enums.find(*field_identity);
        if (it != state.field_enums.end()) {
          for (size_t i = 0; i < it->second.size(); ++i) {
            if (it->second[i] == value.str) {
              out.push_back(static_cast<uint8_t>(StringMode::InlineEnum));
              encode_varuint(i, out);
              return;
            }
          }
        }
      }
      if (value.str.empty()) {
        out.push_back(static_cast<uint8_t>(StringMode::Empty));
        return;
      }
      const auto [ref_id, ref_ok] = state.string_table.get_id(value.str);
      if (ref_ok) {
        out.push_back(static_cast<uint8_t>(StringMode::Ref));
        encode_varuint(ref_id, out);
        return;
      }
      const auto prefix_match = best_prefix_base(value.str);
      if (prefix_match.ok && prefix_match.prefix_len >= 4 &&
          prefix_match.prefix_len < static_cast<int>(value.str.size())) {
        out.push_back(static_cast<uint8_t>(StringMode::PrefixDelta));
        encode_varuint(prefix_match.base_id, out);
        encode_varuint(static_cast<uint64_t>(prefix_match.prefix_len), out);
        encode_string(value.str.substr(static_cast<size_t>(prefix_match.prefix_len)), out);
        state.string_table.register_value(value.str);
        return;
      }
      out.push_back(static_cast<uint8_t>(StringMode::Literal));
      encode_string(value.str, out);
      state.string_table.register_value(value.str);
      break;
    }
    case ValueKind::Binary:
      out.push_back(kTagBinary);
      encode_bytes(value.bin, out);
      break;
    case ValueKind::Array:
      out.push_back(kTagArray);
      encode_varuint(value.arr.size(), out);
      for (const auto& v : value.arr) write_value(v, out);
      break;
    case ValueKind::Map:
      out.push_back(kTagMap);
      encode_varuint(value.map.size(), out);
      for (const auto& e : value.map) {
        write_key_ref(KeyRef::literal_ref(e.key), out);
        write_value_with_field(e.value, e.key, out);
      }
      break;
  }
}

Value TwilicCodec::read_value(Reader& reader) { return read_value_with_field(reader, std::nullopt); }

Value TwilicCodec::read_value_with_field(Reader& reader, const std::optional<std::string>& field_identity) {
  DecodeDepthGuard depth(reader);
  const auto tag = reader.read_u8();
  switch (tag) {
    case kTagNull:
      return new_null();
    case kTagBoolFalse:
      return new_bool(false);
    case kTagBoolTrue:
      return new_bool(true);
    case kTagI64:
      return new_i64(decode_zigzag(read_smallest_u64(reader)));
    case kTagU64:
      return new_u64(read_smallest_u64(reader));
    case kTagF64:
      return new_f64(read_f64_le(reader));
    case kTagString:
      return read_string_value(reader, field_identity);
    case kTagBinary:
      return new_binary(reader.read_bytes());
    case kTagArray: {
      const auto n = reader.read_count();
      std::vector<Value> items;
      items.reserve(static_cast<size_t>(n));
      for (uint64_t i = 0; i < n; ++i) items.push_back(read_value(reader));
      return new_array(std::move(items));
    }
    case kTagMap: {
      const auto n = reader.read_count();
      std::vector<MapEntry> entries;
      entries.reserve(static_cast<size_t>(n));
      for (uint64_t i = 0; i < n; ++i) {
        const auto key_ref = read_key_ref(reader);
        entries.push_back(entry(key_ref.literal, read_value_with_field(reader, key_ref.literal)));
      }
      return new_map(std::move(entries));
    }
    default:
      throw invalid_tag(tag);
  }
}

Value TwilicCodec::read_string_value(Reader& reader, const std::optional<std::string>& field_identity) {
  DecodeDepthGuard depth(reader);
  const auto mode_byte = reader.read_u8();
  StringMode mode;
  if (!string_mode_from_byte(mode_byte, mode)) throw invalid_data("string mode");
  switch (mode) {
    case StringMode::Empty:
      return new_string("");
    case StringMode::Literal: {
      const auto s = reader.read_string();
      state.string_table.register_value(s);
      return new_string(s);
    }
    case StringMode::Ref: {
      const auto ref_id = reader.read_varuint();
      const auto [s, ok] = state.string_table.get_value(ref_id);
      if (!ok) reference_error("string_id", ref_id);
      return new_string(s);
    }
    case StringMode::PrefixDelta: {
      const auto base_id = reader.read_varuint();
      const auto prefix_len = reader.read_count();
      const auto suffix = reader.read_string();
      const auto [base, ok] = state.string_table.get_value(base_id);
      if (!ok) reference_error("string_id", base_id);
      if (prefix_len > base.size()) throw invalid_data("prefix delta length");
      const auto s = base.substr(0, static_cast<size_t>(prefix_len)) + suffix;
      state.string_table.register_value(s);
      return new_string(s);
    }
    case StringMode::InlineEnum: {
      if (!field_identity) throw invalid_data("inline enum missing field identity");
      const auto it = state.field_enums.find(*field_identity);
      if (it == state.field_enums.end()) throw invalid_data("inline enum unknown field");
      const auto code = reader.read_varuint();
      if (code >= it->second.size()) throw invalid_data("inline enum code");
      return new_string(it->second[static_cast<size_t>(code)]);
    }
  }
  throw invalid_data("string mode");
}

void TwilicCodec::write_key_ref(const KeyRef& key_ref, Buffer& out) {
  if (key_ref.is_id) {
    out.push_back(1);
    encode_varuint(key_ref.id, out);
    return;
  }
  out.push_back(0);
  encode_string(key_ref.literal, out);
  state.key_table.register_value(key_ref.literal);
}

KeyRef TwilicCodec::read_key_ref(Reader& reader) {
  const auto mode = reader.read_u8();
  if (mode == 1) {
    const auto ref_id = reader.read_varuint();
    const auto [key, ok] = state.key_table.get_value(ref_id);
    if (!ok) reference_error("key_id", ref_id);
    return KeyRef::literal_ref(key);
  }
  const auto s = reader.read_string();
  state.key_table.register_value(s);
  return KeyRef::literal_ref(s);
}

void TwilicCodec::write_string_vector(const std::vector<std::string>& values, VectorCodec codec, Buffer& out) {
  switch (codec) {
    case VectorCodec::Dictionary: {
      std::unordered_map<std::string, uint64_t> dictionary;
      std::vector<std::string> unique;
      std::vector<uint64_t> refs;
      for (const auto& value : values) {
        const auto it = dictionary.find(value);
        if (it != dictionary.end()) {
          refs.push_back(it->second);
        } else {
          const uint64_t new_ref = unique.size();
          dictionary[value] = new_ref;
          unique.push_back(value);
          refs.push_back(new_ref);
        }
      }
      encode_varuint(unique.size(), out);
      for (const auto& value : unique) encode_string(value, out);
      encode_u64_vector(refs, VectorCodec::DirectBitpack, out);
      break;
    }
    case VectorCodec::StringRef:
      encode_varuint(values.size(), out);
      for (const auto& value : values) {
        auto [string_id, ok] = state.string_table.get_id(value);
        if (!ok) string_id = state.string_table.register_value(value);
        encode_varuint(string_id, out);
      }
      break;
    case VectorCodec::PrefixDelta:
      encode_varuint(values.size(), out);
      {
        std::string prev;
        for (const auto& value : values) {
          const auto prefix = static_cast<uint64_t>(common_prefix_len(prev, value));
          encode_varuint(prefix, out);
          encode_string(value.substr(prefix), out);
          prev = value;
        }
      }
      break;
    default:
      encode_varuint(values.size(), out);
      for (const auto& value : values) encode_string(value, out);
      break;
  }
}

std::vector<std::string> TwilicCodec::read_string_vector(Reader& reader, VectorCodec codec) {
  switch (codec) {
    case VectorCodec::Dictionary: {
      const auto dict_size = reader.read_count();
      std::vector<std::string> dictionary;
      dictionary.reserve(static_cast<size_t>(dict_size));
      for (uint64_t i = 0; i < dict_size; ++i) dictionary.push_back(reader.read_string());
      const auto refs = decode_u64_vector(reader, VectorCodec::DirectBitpack);
      std::vector<std::string> out;
      for (const auto ref : refs) {
        if (ref >= dictionary.size()) throw invalid_data("dictionary reference");
        out.push_back(dictionary[static_cast<size_t>(ref)]);
      }
      return out;
    }
    case VectorCodec::StringRef: {
      const auto length = reader.read_count();
      std::vector<std::string> out;
      for (uint64_t i = 0; i < length; ++i) {
        const auto string_id = reader.read_varuint();
        const auto [value, ok] = state.string_table.get_value(string_id);
        if (!ok) reference_error("string_id", string_id);
        out.push_back(value);
      }
      return out;
    }
    case VectorCodec::PrefixDelta: {
      const auto length = reader.read_count();
      std::vector<std::string> out;
      std::string prev;
      for (uint64_t i = 0; i < length; ++i) {
        const auto prefix_len = reader.read_count();
        const auto suffix = reader.read_string();
        if (prefix_len > prev.size()) throw invalid_data("prefix delta in string vector");
        const auto value = prev.substr(0, static_cast<size_t>(prefix_len)) + suffix;
        out.push_back(value);
        prev = value;
      }
      return out;
    }
    default: {
      const auto length = reader.read_count();
      std::vector<std::string> out;
      for (uint64_t i = 0; i < length; ++i) out.push_back(reader.read_string());
      return out;
    }
  }
}

void TwilicCodec::write_typed_vector(const TypedVector& vector, Buffer& out) {
  out.push_back(static_cast<uint8_t>(vector.element_type));
  encode_varuint(typed_vector_len(vector.data), out);
  out.push_back(static_cast<uint8_t>(vector.codec));
  switch (vector.element_type) {
    case ElementType::Bool:
      encode_bitmap(vector.data.bools, out);
      break;
    case ElementType::I64:
      encode_i64_vector(vector.data.i64s, vector.codec, out);
      break;
    case ElementType::U64:
      encode_u64_vector(vector.data.u64s, vector.codec, out);
      break;
    case ElementType::F64:
      encode_f64_vector(vector.data.f64s, vector.codec, out);
      break;
    case ElementType::String:
      write_string_vector(vector.data.strings, vector.codec, out);
      break;
    case ElementType::Binary:
      encode_varuint(vector.data.binary.size(), out);
      for (const auto& b : vector.data.binary) encode_bytes(b, out);
      break;
    case ElementType::Value:
      encode_varuint(vector.data.values.size(), out);
      for (const auto& v : vector.data.values) write_value(v, out);
      break;
    default:
      throw invalid_data("unsupported element type");
  }
}

TypedVector TwilicCodec::read_typed_vector(Reader& reader, std::optional<ElementType> forced_element,
                                           std::optional<VectorCodec> expected_codec) {
  ElementType elem;
  if (forced_element) {
    elem = *forced_element;
  } else {
    const auto elem_byte = reader.read_u8();
    ElementType parsed;
    if (!element_type_from_byte(elem_byte, parsed)) throw invalid_data("vector element type");
    elem = parsed;
  }
  const auto expected_len = reader.read_count();
  const auto codec_byte = reader.read_u8();
  VectorCodec codec;
  if (!vector_codec_from_byte(codec_byte, codec)) throw invalid_data("vector codec");
  if (expected_codec && codec != *expected_codec) throw invalid_data("column codec mismatch");
  TypedVectorData data;
  data.kind = elem;
  switch (elem) {
    case ElementType::Bool:
      data.bools = reader.read_bitmap();
      break;
    case ElementType::I64:
      data.i64s = decode_i64_vector(reader, codec);
      break;
    case ElementType::U64:
      data.u64s = decode_u64_vector(reader, codec);
      break;
    case ElementType::F64:
      data.f64s = decode_f64_vector(reader, codec);
      break;
    case ElementType::String:
      data.strings = read_string_vector(reader, codec);
      break;
    case ElementType::Binary: {
      const auto n = reader.read_count();
      for (uint64_t i = 0; i < n; ++i) data.binary.push_back(reader.read_bytes());
      break;
    }
    case ElementType::Value: {
      const auto n = reader.read_count();
      for (uint64_t i = 0; i < n; ++i) data.values.push_back(read_value(reader));
      break;
    }
    default:
      throw invalid_data("unsupported element type");
  }
  if (typed_vector_len(data) != expected_len) throw invalid_data("typed vector length mismatch");
  return TypedVector{elem, codec, std::move(data)};
}

void TwilicCodec::write_column(const Column& column, Buffer& out) {
  encode_varuint(column.field_id, out);
  out.push_back(static_cast<uint8_t>(column.null_strategy));
  if (column.null_strategy == NullStrategy::PresenceBitmap ||
      column.null_strategy == NullStrategy::InvertedPresenceBitmap) {
    if (!column.has_presence) throw invalid_data("missing column presence bitmap");
    encode_bitmap(column.presence, out);
  }
  out.push_back(static_cast<uint8_t>(column.codec));
  if (column.dictionary_id) {
    out.push_back(1);
    encode_varuint(*column.dictionary_id, out);
    out.push_back(0);
  } else {
    out.push_back(0);
  }
  out.push_back(0);
  TypedVector tv{column.values.kind, column.codec, clone_typed_vector_data(column.values)};
  write_typed_vector(tv, out);
}

Column TwilicCodec::read_column(Reader& reader) {
  const auto field_id = reader.read_varuint();
  NullStrategy null_strategy;
  if (!null_strategy_from_byte(reader.read_u8(), null_strategy)) throw invalid_data("null strategy");
  std::vector<bool> presence;
  bool has_presence = false;
  if (null_strategy == NullStrategy::PresenceBitmap ||
      null_strategy == NullStrategy::InvertedPresenceBitmap) {
    presence = reader.read_bitmap();
    has_presence = true;
  }
  VectorCodec codec;
  if (!vector_codec_from_byte(reader.read_u8(), codec)) throw invalid_data("column codec");
  const auto has_dict = reader.read_u8();
  std::optional<uint64_t> dictionary_id;
  if (has_dict == 1) {
    const auto dict_id = reader.read_varuint();
    const auto has_profile = reader.read_u8();
    if (has_profile == 0) {
      if (state.dictionaries.find(dict_id) == state.dictionaries.end()) reference_error("dict_id", dict_id);
    } else if (has_profile == 1) {
      reader.read_varuint();
      reader.read_varuint();
      reader.read_varuint();
      reader.read_u8();
      const auto payload = reader.read_bytes();
      state.dictionaries[dict_id] = payload;
    } else {
      throw invalid_data("dictionary profile flag");
    }
    dictionary_id = dict_id;
  } else if (has_dict != 0) {
    throw invalid_data("dictionary flag");
  }
  const auto payload_mode = reader.read_u8();
  TypedVectorData values;
  if (payload_mode == 0) {
    values = read_typed_vector(reader, std::nullopt, codec).data;
  } else {
    throw invalid_data("trained dictionary block not supported");
  }
  Column col;
  col.field_id = field_id;
  col.null_strategy = null_strategy;
  col.presence = presence;
  col.has_presence = has_presence;
  col.codec = codec;
  col.dictionary_id = dictionary_id;
  col.values = std::move(values);
  return col;
}

void TwilicCodec::write_base_ref(const BaseRef& base_ref, Buffer& out) {
  if (base_ref.previous) {
    out.push_back(0);
    return;
  }
  out.push_back(1);
  encode_varuint(base_ref.base_id, out);
}

BaseRef TwilicCodec::read_base_ref(Reader& reader) {
  const auto mode = reader.read_u8();
  if (mode == 0) return BaseRef::previous_ref();
  if (mode == 1) return BaseRef::id_ref(reader.read_varuint());
  throw invalid_data("base ref");
}

void TwilicCodec::write_control_stream_payload(ControlStreamCodec codec, const std::vector<uint8_t>& payload,
                                               Buffer& out) {
  std::vector<uint8_t> encoded;
  switch (codec) {
    case ControlStreamCodec::Plain:
      encoded = payload;
      break;
    case ControlStreamCodec::Rle:
      encoded = payload;
      break;
    case ControlStreamCodec::Bitpack:
      encoded = control_bitpack_encode_bytes(payload);
      break;
    case ControlStreamCodec::Huffman:
      encoded = control_huffman_encode_bytes(payload);
      break;
    case ControlStreamCodec::Fse:
      encoded = control_fse_encode_bytes(payload);
      break;
  }
  encode_bytes(encoded, out);
}

std::vector<uint8_t> TwilicCodec::read_control_stream_payload(ControlStreamCodec codec, Reader& reader) {
  const auto encoded = reader.read_bytes();
  switch (codec) {
    case ControlStreamCodec::Plain:
      return encoded;
    case ControlStreamCodec::Rle:
      return encoded;
    case ControlStreamCodec::Bitpack:
      return control_bitpack_decode_bytes(encoded);
    case ControlStreamCodec::Huffman:
      return control_huffman_decode_bytes(encoded);
    case ControlStreamCodec::Fse:
      return control_fse_decode_bytes(encoded);
  }
  return encoded;
}

Message TwilicCodec::apply_state_patch(const BaseRef& base_ref, const std::vector<PatchOperation>& operations,
                                       const std::vector<Value>&) {
  Message base = [&]() -> Message {
    if (base_ref.previous) {
      if (!state.previous_message) reference_error("previous", 0);
      return state.previous_message->clone();
    }
    auto snap_result = get_base_snapshot(state, base_ref.base_id);
    if (!snap_result.second) reference_error("base_id", base_ref.base_id);
    return std::move(snap_result.first);
  }();
  auto fields = message_fields(base);
  for (const auto& operation : operations) {
    const size_t idx = static_cast<size_t>(operation.field_id);
    switch (operation.opcode) {
      case PatchOpcode::Keep:
        break;
      case PatchOpcode::ReplaceScalar:
      case PatchOpcode::ReplaceVector:
      case PatchOpcode::InsertField:
      case PatchOpcode::StringRef:
      case PatchOpcode::PrefixDelta:
        if (!operation.value) throw invalid_data("patch operation missing value");
        if (idx < fields.size()) {
          fields[idx] = operation.value->clone();
        } else if (idx == fields.size()) {
          fields.push_back(operation.value->clone());
        } else {
          throw invalid_data("patch field index out of range");
        }
        break;
      case PatchOpcode::DeleteField:
        if (idx >= fields.size()) throw invalid_data("delete field index out of range");
        fields.erase(fields.begin() + static_cast<std::ptrdiff_t>(idx));
        break;
      case PatchOpcode::AppendVector:
        if (!operation.value || idx >= fields.size()) throw invalid_data("append vector patch invalid");
        if (fields[idx].kind != ValueKind::Array || operation.value->kind != ValueKind::Array) {
          throw invalid_data("append vector requires arrays");
        }
        for (const auto& v : operation.value->arr) fields[idx].arr.push_back(v.clone());
        break;
      case PatchOpcode::TruncateVector:
        if (!operation.value || idx >= fields.size()) throw invalid_data("truncate vector patch invalid");
        if (fields[idx].kind != ValueKind::Array || operation.value->kind != ValueKind::U64) {
          throw invalid_data("truncate vector requires array and u64");
        }
        if (operation.value->u64 > fields[idx].arr.size()) throw invalid_data("truncate length");
        fields[idx].arr.resize(static_cast<size_t>(operation.value->u64));
        break;
    }
  }
  return rebuild_message_like(base, fields);
}

void TwilicCodec::write_message(const Message& message, Buffer& out) {
  switch (message.kind) {
    case MessageKind::Scalar:
      out.push_back(static_cast<uint8_t>(MessageKind::Scalar));
      write_value(message.scalar, out);
      break;
    case MessageKind::Array:
      out.push_back(static_cast<uint8_t>(MessageKind::Array));
      encode_varuint(message.array.size(), out);
      for (const auto& v : message.array) write_value(v, out);
      break;
    case MessageKind::Map:
      out.push_back(static_cast<uint8_t>(MessageKind::Map));
      encode_varuint(message.map.size(), out);
      for (const auto& e : message.map) {
        write_key_ref(e.key, out);
        write_value(e.value, out);
      }
      break;
    case MessageKind::ShapedObject:
      out.push_back(static_cast<uint8_t>(MessageKind::ShapedObject));
      encode_varuint(message.shaped_object.shape_id, out);
      out.push_back(0);
      encode_varuint(message.shaped_object.values.size(), out);
      for (const auto& v : message.shaped_object.values) write_value(v, out);
      break;
    case MessageKind::TypedVector:
      out.push_back(static_cast<uint8_t>(MessageKind::TypedVector));
      write_typed_vector(message.typed_vector, out);
      break;
    case MessageKind::SchemaObject:
      out.push_back(static_cast<uint8_t>(MessageKind::SchemaObject));
      if (message.schema_object.has_schema_id) {
        out.push_back(1);
        encode_varuint(message.schema_object.schema_id, out);
      } else {
        out.push_back(0);
      }
      out.push_back(0);
      encode_varuint(message.schema_object.fields.size(), out);
      out.push_back(0);
      for (const auto& v : message.schema_object.fields) write_value(v, out);
      break;
    case MessageKind::RowBatch:
      out.push_back(static_cast<uint8_t>(MessageKind::RowBatch));
      encode_varuint(message.row_batch.rows.size(), out);
      for (const auto& row : message.row_batch.rows) {
        encode_varuint(row.size(), out);
        for (const auto& v : row) write_value(v, out);
      }
      break;
    case MessageKind::ColumnBatch:
      out.push_back(static_cast<uint8_t>(MessageKind::ColumnBatch));
      encode_varuint(message.column_batch.count, out);
      encode_varuint(message.column_batch.columns.size(), out);
      for (const auto& col : message.column_batch.columns) write_column(col, out);
      break;
    case MessageKind::StatePatch:
      out.push_back(static_cast<uint8_t>(MessageKind::StatePatch));
      write_base_ref(message.state_patch.base_ref, out);
      encode_varuint(message.state_patch.operations.size(), out);
      for (const auto& op : message.state_patch.operations) {
        encode_varuint(op.field_id, out);
        out.push_back(static_cast<uint8_t>(op.opcode));
        if (op.value) {
          out.push_back(1);
          write_value(*op.value, out);
        } else {
          out.push_back(0);
        }
      }
      encode_varuint(message.state_patch.literals.size(), out);
      for (const auto& lit : message.state_patch.literals) write_value(lit, out);
      break;
    case MessageKind::TemplateBatch:
      out.push_back(static_cast<uint8_t>(MessageKind::TemplateBatch));
      encode_varuint(message.template_batch.template_id, out);
      encode_varuint(message.template_batch.count, out);
      encode_bitmap(message.template_batch.changed_column_mask, out);
      encode_varuint(message.template_batch.columns.size(), out);
      for (const auto& col : message.template_batch.columns) write_column(col, out);
      break;
    case MessageKind::BaseSnapshot:
      out.push_back(static_cast<uint8_t>(MessageKind::BaseSnapshot));
      if (!message.base_snapshot) throw invalid_data("missing base snapshot");
      encode_varuint(message.base_snapshot->base_id, out);
      encode_varuint(message.base_snapshot->schema_or_shape_ref, out);
      write_message(message.base_snapshot->payload, out);
      register_base_snapshot(state, message.base_snapshot->base_id, message.base_snapshot->payload);
      break;
    case MessageKind::ControlStream:
      out.push_back(static_cast<uint8_t>(MessageKind::ControlStream));
      out.push_back(static_cast<uint8_t>(message.control_stream.codec));
      write_control_stream_payload(message.control_stream.codec, message.control_stream.payload, out);
      break;
    case MessageKind::Ext:
      out.push_back(static_cast<uint8_t>(MessageKind::Ext));
      encode_varuint(message.ext.ext_type, out);
      encode_bytes(message.ext.payload, out);
      break;
    default:
      throw invalid_data("unsupported message kind");
  }
}

Message TwilicCodec::read_message(Reader& reader) {
  DecodeDepthGuard depth(reader);
  const auto kind_byte = reader.read_u8();
  MessageKind kind;
  if (!message_kind_from_byte(kind_byte, kind)) throw invalid_kind(kind_byte);
  switch (kind) {
    case MessageKind::Scalar: {
      Message msg;
      msg.kind = kind;
      msg.has_scalar = true;
      msg.scalar = read_value(reader);
      return msg;
    }
    case MessageKind::Array: {
      const auto n = reader.read_count();
      Message msg;
      msg.kind = kind;
      msg.array.reserve(static_cast<size_t>(n));
      for (uint64_t i = 0; i < n; ++i) msg.array.push_back(read_value(reader));
      return msg;
    }
    case MessageKind::Map: {
      const auto n = reader.read_count();
      Message msg;
      msg.kind = kind;
      msg.map.reserve(static_cast<size_t>(n));
      std::vector<std::string> keys;
      keys.reserve(static_cast<size_t>(n));
      for (uint64_t i = 0; i < n; ++i) {
        const auto key_ref = read_key_ref(reader);
        const auto field_identity = key_ref_field_identity(key_ref, state);
        msg.map.push_back({key_ref, read_value_with_field(reader, field_identity)});
        keys.push_back(key_ref_string(key_ref, state));
      }
      observe_decode_shape_candidate(keys);
      return msg;
    }
    case MessageKind::ShapedObject: {
      const auto shape_id = reader.read_count(65535);
      reader.read_u8();
      const auto n = reader.read_count();
      Message msg;
      msg.kind = kind;
      msg.has_shaped_object = true;
      msg.shaped_object.shape_id = shape_id;
      msg.shaped_object.values.reserve(static_cast<size_t>(n));
      for (uint64_t i = 0; i < n; ++i) msg.shaped_object.values.push_back(read_value(reader));
      return msg;
    }
    case MessageKind::TypedVector: {
      Message msg;
      msg.kind = kind;
      msg.has_typed_vector = true;
      msg.typed_vector = read_typed_vector(reader, std::nullopt, std::nullopt);
      return msg;
    }
    case MessageKind::SchemaObject: {
      const auto has_schema = reader.read_u8();
      std::optional<uint64_t> schema_id;
      if (has_schema == 1) schema_id = reader.read_varuint();
      reader.read_u8();
      const auto n = reader.read_count();
      reader.read_u8();
      Message msg;
      msg.kind = kind;
      msg.has_schema_object = true;
      if (schema_id) {
        msg.schema_object.schema_id = *schema_id;
        msg.schema_object.has_schema_id = true;
      }
      msg.schema_object.fields.reserve(static_cast<size_t>(n));
      for (uint64_t i = 0; i < n; ++i) msg.schema_object.fields.push_back(read_value(reader));
      return msg;
    }
    case MessageKind::RowBatch: {
      const auto row_count = reader.read_count();
      Message msg;
      msg.kind = kind;
      msg.has_row_batch = true;
      msg.row_batch.rows.reserve(static_cast<size_t>(row_count));
      for (uint64_t i = 0; i < row_count; ++i) {
        const auto field_count = reader.read_count();
        std::vector<Value> row;
        row.reserve(static_cast<size_t>(field_count));
        for (uint64_t j = 0; j < field_count; ++j) row.push_back(read_value(reader));
        msg.row_batch.rows.push_back(std::move(row));
      }
      return msg;
    }
    case MessageKind::ColumnBatch: {
      const auto count = reader.read_count();
      const auto col_count = reader.read_count();
      Message msg;
      msg.kind = kind;
      msg.has_column_batch = true;
      msg.column_batch.count = count;
      msg.column_batch.columns.reserve(static_cast<size_t>(col_count));
      for (uint64_t i = 0; i < col_count; ++i) msg.column_batch.columns.push_back(read_column(reader));
      return msg;
    }
    case MessageKind::StatePatch: {
      const auto base_ref = read_base_ref(reader);
      const auto n = reader.read_count();
      std::vector<PatchOperation> ops;
      ops.reserve(static_cast<size_t>(n));
      for (uint64_t i = 0; i < n; ++i) {
        const auto field_id = reader.read_varuint();
        PatchOpcode opcode;
        if (!patch_opcode_from_byte(reader.read_u8(), opcode)) throw invalid_data("patch opcode");
        PatchOperation op;
        op.field_id = field_id;
        op.opcode = opcode;
        if (reader.read_u8() == 1) op.value = read_value(reader);
        ops.push_back(std::move(op));
      }
      const auto lit_n = reader.read_count();
      std::vector<Value> lits;
      for (uint64_t i = 0; i < lit_n; ++i) lits.push_back(read_value(reader));
      Message msg;
      msg.kind = kind;
      msg.has_state_patch = true;
      msg.state_patch.base_ref = base_ref;
      msg.state_patch.operations = std::move(ops);
      msg.state_patch.literals = std::move(lits);
      return msg;
    }
    case MessageKind::TemplateBatch: {
      const auto template_id = reader.read_varuint();
      const auto count = reader.read_count();
      const auto mask = reader.read_bitmap();
      const auto col_n = reader.read_count();
      std::vector<Column> changed_cols;
      changed_cols.reserve(static_cast<size_t>(col_n));
      for (uint64_t i = 0; i < col_n; ++i) changed_cols.push_back(read_column(reader));
      auto full_cols = changed_cols;
      const auto prev_it = state.template_columns.find(template_id);
      if (prev_it != state.template_columns.end()) {
        full_cols = merge_template_columns(prev_it->second, mask, changed_cols);
      } else {
        for (const auto bit : mask) {
          if (!bit) reference_error("template_id", template_id);
        }
      }
      state.template_columns[template_id] = full_cols;
      state.templates[template_id] = template_descriptor_from_columns(template_id, full_cols);
      if (count >= 16) {
        Message prev_msg;
        prev_msg.kind = MessageKind::ColumnBatch;
        prev_msg.has_column_batch = true;
        prev_msg.column_batch.count = count;
        prev_msg.column_batch.columns = full_cols;
        state.previous_message = prev_msg.clone();
      }
      Message msg;
      msg.kind = kind;
      msg.has_template_batch = true;
      msg.template_batch.template_id = template_id;
      msg.template_batch.count = count;
      msg.template_batch.changed_column_mask = mask;
      msg.template_batch.columns = std::move(changed_cols);
      return msg;
    }
    case MessageKind::BaseSnapshot: {
      const auto base_id = reader.read_varuint();
      const auto ref = reader.read_varuint();
      auto payload = read_message(reader);
      register_base_snapshot(state, base_id, payload);
      Message msg;
      msg.kind = kind;
      msg.has_base_snapshot = true;
      msg.base_snapshot = std::make_unique<BaseSnapshotMessage>();
      msg.base_snapshot->base_id = base_id;
      msg.base_snapshot->schema_or_shape_ref = ref;
      msg.base_snapshot->payload = std::move(payload);
      return msg;
    }
    case MessageKind::ControlStream: {
      ControlStreamCodec stream_codec;
      if (!control_stream_codec_from_byte(reader.read_u8(), stream_codec)) {
        throw invalid_data("control stream codec");
      }
      Message msg;
      msg.kind = kind;
      msg.has_control_stream = true;
      msg.control_stream.codec = stream_codec;
      msg.control_stream.payload = read_control_stream_payload(stream_codec, reader);
      return msg;
    }
    case MessageKind::Ext: {
      Message msg;
      msg.kind = kind;
      msg.has_ext = true;
      msg.ext.ext_type = reader.read_varuint();
      msg.ext.payload = reader.read_bytes();
      return msg;
    }
    default:
      throw invalid_data("unsupported message kind");
  }
}

std::vector<uint8_t> TwilicCodec::encode_message(const Message& message) {
  Buffer out;
  write_message(message, out);
  return out;
}

Message TwilicCodec::decode_message(const std::vector<uint8_t>& data) {
  Reader reader(data);
  auto msg = read_message(reader);
  if (!reader.is_eof()) throw invalid_data("trailing bytes in message");
  switch (msg.kind) {
    case MessageKind::Control:
      break;
    case MessageKind::StatePatch:
      try {
        const auto reconstructed =
            apply_state_patch(msg.state_patch.base_ref, msg.state_patch.operations, msg.state_patch.literals);
        state.previous_message = reconstructed.clone();
        state.previous_message_size = data.size();
      } catch (const TwilicError& err) {
        if (err.kind != TwilicErrorKind::ErrUnknownReference &&
            err.kind != TwilicErrorKind::ErrStatelessRetryRequired) {
          throw;
        }
      }
      break;
    case MessageKind::TemplateBatch:
      if (!state.previous_message) {
        state.previous_message = msg.clone();
        state.previous_message_size = data.size();
      }
      break;
    default:
      state.previous_message = msg.clone();
      state.previous_message_size = data.size();
      break;
  }
  return msg;
}

std::vector<uint8_t> TwilicCodec::encode_value(const Value& value) {
  const auto msg = message_for_value(value);
  const auto out = encode_message(msg);
  state.previous_message = msg.clone();
  state.previous_message_size = out.size();
  return out;
}

Value TwilicCodec::decode_value(const std::vector<uint8_t>& data) {
  const auto msg = decode_message(data);
  switch (msg.kind) {
    case MessageKind::Scalar:
      return msg.scalar.clone();
    case MessageKind::Array: {
      std::vector<Value> items;
      items.reserve(msg.array.size());
      for (const auto& v : msg.array) items.push_back(v.clone());
      return new_array(std::move(items));
    }
    case MessageKind::Map: {
      auto entries = entries_to_map(msg.map);
      for (const auto& e : entries) {
        const auto [_, ok] = state.key_table.get_id(e.key);
        if (!ok) state.key_table.register_value(e.key);
      }
      return new_map(std::move(entries));
    }
    case MessageKind::ShapedObject: {
      const auto [keys, ok] = state.shape_table.get_keys(msg.shaped_object.shape_id);
      if (!ok) throw unknown_reference("shape_id", msg.shaped_object.shape_id);
      std::vector<MapEntry> entries;
      const size_t n = std::min(keys.size(), msg.shaped_object.values.size());
      for (size_t i = 0; i < n; ++i) entries.push_back(entry(keys[i], msg.shaped_object.values[i].clone()));
      return new_map(std::move(entries));
    }
    case MessageKind::TypedVector:
      return typed_vector_to_value(msg.typed_vector);
    default:
      throw invalid_data("decode_value expects scalar/array/map/vector message");
  }
}

SessionEncoder::SessionEncoder(std::optional<SessionOptions> options)
    : codec(new_session_state_with_options(options.value_or(default_session_options()))) {}

std::vector<uint8_t> SessionEncoder::encode(const Value& value) {
  const auto msg = codec.message_for_value(value);
  if (codec.state.options.enable_state_patch && codec.state.previous_message &&
      supports_state_patch(&*codec.state.previous_message, msg)) {
    const auto [ops, _] = diff_message(*codec.state.previous_message, msg);
    Message patch_msg;
    patch_msg.kind = MessageKind::StatePatch;
    patch_msg.has_state_patch = true;
    patch_msg.state_patch.base_ref = BaseRef::previous_ref();
    patch_msg.state_patch.operations = ops;
    if (encoded_size(patch_msg) < encoded_size(msg)) {
      try {
        return codec.encode_message(patch_msg);
      } catch (...) {
      }
    }
  }
  return codec.encode_message(msg);
}

std::vector<uint8_t> SessionEncoder::encode_with_schema(const Schema& schema, const Value& value) {
  codec.state.schemas[schema.schema_id] = schema;
  if (value.kind != ValueKind::Map) throw invalid_data("encode_with_schema expects map value");
  std::vector<Value> fields;
  fields.reserve(schema.fields.size());
  for (const auto& f : schema.fields) {
    Value found = new_null();
    for (const auto& e : value.map) {
      if (e.key == f.name) {
        found = e.value.clone();
        break;
      }
    }
    fields.push_back(std::move(found));
  }
  Message msg;
  msg.kind = MessageKind::SchemaObject;
  msg.has_schema_object = true;
  msg.schema_object.schema_id = schema.schema_id;
  msg.schema_object.has_schema_id = true;
  msg.schema_object.fields = std::move(fields);
  return codec.encode_message(msg);
}

std::vector<uint8_t> SessionEncoder::encode_batch(const std::vector<Value>& values) {
  Message msg;
  if (values.empty()) {
    msg.kind = MessageKind::RowBatch;
    msg.has_row_batch = true;
    return codec.encode_message(msg);
  }
  if (values.size() >= 16) {
    auto cols = columns_from_map_values(values);
    if (cols.empty()) cols = rows_to_columns(rows_from_values(values));
    if (codec.state.options.enable_trained_dictionary) apply_dictionary_references(codec.state, cols);
    msg.kind = MessageKind::ColumnBatch;
    msg.has_column_batch = true;
    msg.column_batch.count = values.size();
    msg.column_batch.columns = std::move(cols);
  } else {
    msg.kind = MessageKind::RowBatch;
    msg.has_row_batch = true;
    msg.row_batch.rows = rows_from_values(values);
  }
  const auto bytes = codec.encode_message(msg);
  codec.state.previous_message = msg.clone();
  codec.state.previous_message_size = bytes.size();
  record_full_message_as_base();
  return bytes;
}

std::vector<uint8_t> SessionEncoder::encode_patch(const Value& value) {
  const auto msg = codec.message_for_value(value);
  if (!codec.state.previous_message ||
      !supports_state_patch(&*codec.state.previous_message, msg)) {
    return codec.encode_message(msg);
  }
  const auto [ops, _] = diff_message(*codec.state.previous_message, msg);
  Message patch_msg;
  patch_msg.kind = MessageKind::StatePatch;
  patch_msg.has_state_patch = true;
  patch_msg.state_patch.base_ref = BaseRef::previous_ref();
  patch_msg.state_patch.operations = ops;
  if (encoded_size(patch_msg) >= encoded_size(msg)) return codec.encode_message(msg);
  return codec.encode_message(patch_msg);
}

std::vector<uint8_t> SessionEncoder::encode_micro_batch(const std::vector<Value>& values) {
  if (values.empty()) return encode_batch(values);
  if (!codec.state.options.enable_template_batch || !has_uniform_micro_batch_shape(values)) {
    return encode_batch(values);
  }
  auto columns = columns_from_map_values(values);
  if (columns.empty()) columns = rows_to_columns(rows_from_values(values));
  if (codec.state.options.enable_trained_dictionary) apply_dictionary_references(codec.state, columns);
  const auto [template_id, ok] = find_template_id(codec.state.templates, columns);
  if (!ok) {
    const auto tid = allocate_template_id(codec.state);
    codec.state.templates[tid] = template_descriptor_from_columns(tid, columns);
    codec.state.template_columns[tid] = columns;
    std::vector<bool> mask(columns.size(), true);
    Message msg;
    msg.kind = MessageKind::TemplateBatch;
    msg.has_template_batch = true;
    msg.template_batch.template_id = tid;
    msg.template_batch.count = values.size();
    msg.template_batch.changed_column_mask = std::move(mask);
    msg.template_batch.columns = columns;
    return codec.encode_message(msg);
  }
  const auto [mask, changed_cols] = diff_template_columns(codec.state.template_columns[template_id], columns);
  codec.state.template_columns[template_id] = columns;
  Message msg;
  msg.kind = MessageKind::TemplateBatch;
  msg.has_template_batch = true;
  msg.template_batch.template_id = template_id;
  msg.template_batch.count = values.size();
  msg.template_batch.changed_column_mask = mask;
  msg.template_batch.columns = changed_cols;
  return codec.encode_message(msg);
}

Message SessionEncoder::decode_message(const std::vector<uint8_t>& data) {
  return codec.decode_message(data);
}

void SessionEncoder::reset() { reset_state(codec.state); }

void SessionEncoder::record_full_message_as_base() {
  if (codec.state.options.max_base_snapshots == 0) return;
  if (!codec.state.previous_message) return;
  register_base_snapshot(codec.state, allocate_base_id(codec.state), *codec.state.previous_message);
}

TwilicCodec new_twilic_codec() { return TwilicCodec{}; }

SessionEncoder new_session_encoder(std::optional<SessionOptions> options) {
  return SessionEncoder(std::move(options));
}

std::vector<uint8_t> encode(const Value& value) { return encode_v2(value); }

Value decode(const std::vector<uint8_t>& data) { return decode_v2(data); }

std::vector<uint8_t> encode_with_schema(const Schema& schema, const Value& value) {
  return new_session_encoder().encode_with_schema(schema, value);
}

std::vector<uint8_t> encode_batch(const std::vector<Value>& values) {
  return new_session_encoder().encode_batch(values);
}

}  // namespace twilic
