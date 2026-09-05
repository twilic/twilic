#include "twilic/protocol_helpers.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <unordered_set>

#include "twilic/codec.h"
#include "twilic/errors.h"

namespace twilic {

namespace {

int bit_width_u64(uint64_t v) {
  if (v == 0) return 1;
  int bits = 0;
  while (v > 0) {
    ++bits;
    v >>= 1;
  }
  return bits;
}

int64_t abs64(int64_t v) { return v < 0 ? -v : v; }

std::vector<int64_t> deltas(const std::vector<int64_t>& values) {
  std::vector<int64_t> out;
  out.reserve(values.size());
  for (size_t i = 0; i < values.size(); ++i) {
    out.push_back(i == 0 ? values[i] : values[i] - values[i - 1]);
  }
  return out;
}

std::pair<double, double> run_stats(const std::vector<int64_t>& values) {
  if (values.empty()) return {0.0, 0.0};
  std::vector<int> runs;
  int run_len = 1;
  for (size_t i = 1; i < values.size(); ++i) {
    if (values[i] == values[i - 1]) {
      ++run_len;
    } else {
      runs.push_back(run_len);
      run_len = 1;
    }
  }
  runs.push_back(run_len);
  int repeated_items = 0;
  for (const auto r : runs) {
    if (r > 1) repeated_items += r;
  }
  double sum_runs = 0;
  for (const auto r : runs) sum_runs += r;
  return {static_cast<double>(repeated_items) / static_cast<double>(values.size()),
          sum_runs / static_cast<double>(runs.size())};
}

struct ColumnNullStrategyResult {
  NullStrategy strategy;
  std::vector<bool> presence;
  bool has_presence;
};

ColumnNullStrategyResult column_null_strategy(const std::vector<Value>& values,
                                              const std::vector<bool>& present_bits) {
  size_t null_count = 0;
  for (const auto& v : values) {
    if (v.kind == ValueKind::Null) ++null_count;
  }
  if (null_count == 0) return {NullStrategy::AllPresentElided, {}, false};
  if (null_count <= values.size() / 4) {
    std::vector<bool> inverted;
    inverted.reserve(present_bits.size());
    for (const auto b : present_bits) inverted.push_back(!b);
    return {NullStrategy::InvertedPresenceBitmap, inverted, true};
  }
  return {NullStrategy::PresenceBitmap, present_bits, true};
}

std::vector<Value> strip_nulls(const std::vector<Value>& values) {
  std::vector<Value> out;
  out.reserve(values.size());
  for (const auto& v : values) {
    if (v.kind != ValueKind::Null) out.push_back(v.clone());
  }
  return out;
}

int estimate_value_size(const Value& value);
int varuint_size(uint64_t value);
int smallest_u64_size(uint64_t value);
int encoded_string_size(const std::string& value);

}  // namespace

size_t typed_vector_len(const TypedVectorData& data) {
  switch (data.kind) {
    case ElementType::Bool:
      return data.bools.size();
    case ElementType::I64:
      return data.i64s.size();
    case ElementType::U64:
      return data.u64s.size();
    case ElementType::F64:
      return data.f64s.size();
    case ElementType::String:
      return data.strings.size();
    case ElementType::Binary:
      return data.binary.size();
    case ElementType::Value:
      return data.values.size();
  }
  return 0;
}

TypedVectorData clone_typed_vector_data(const TypedVectorData& data) { return data; }

Value typed_vector_to_value(const TypedVector& vector) {
  switch (vector.element_type) {
    case ElementType::Bool: {
      std::vector<Value> items;
      for (const auto b : vector.data.bools) items.push_back(new_bool(b));
      return new_array(std::move(items));
    }
    case ElementType::I64: {
      std::vector<Value> items;
      for (const auto v : vector.data.i64s) items.push_back(new_i64(v));
      return new_array(std::move(items));
    }
    case ElementType::U64: {
      std::vector<Value> items;
      for (const auto v : vector.data.u64s) items.push_back(new_u64(v));
      return new_array(std::move(items));
    }
    case ElementType::F64: {
      std::vector<Value> items;
      for (const auto v : vector.data.f64s) items.push_back(new_f64(v));
      return new_array(std::move(items));
    }
    case ElementType::String: {
      std::vector<Value> items;
      for (const auto& s : vector.data.strings) items.push_back(new_string(s));
      return new_array(std::move(items));
    }
    default:
      return new_array({});
  }
}

std::vector<MapEntry> entries_to_map(const std::vector<MessageMapEntry>& entries) {
  std::vector<MapEntry> out;
  out.reserve(entries.size());
  for (const auto& e : entries) {
    const auto key = e.key.literal;
    out.push_back(entry(key, e.value.clone()));
  }
  return out;
}

void write_smallest_u64(uint64_t value, Buffer& out) {
  if (value <= 0xFF) {
    out.push_back(1);
    out.push_back(static_cast<uint8_t>(value));
  } else if (value <= 0xFFFF) {
    out.push_back(2);
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
  } else if (value <= 0xFFFFFFFFULL) {
    out.push_back(4);
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
  } else {
    out.push_back(8);
    append_u64_le(out, value);
  }
}

uint64_t read_smallest_u64(Reader& reader) {
  const auto size = reader.read_u8();
  switch (size) {
    case 1:
      return reader.read_u8();
    case 2: {
      const auto b = reader.read_exact(2);
      return b[0] | (static_cast<uint64_t>(b[1]) << 8);
    }
    case 4: {
      const auto b = reader.read_exact(4);
      return b[0] | (static_cast<uint64_t>(b[1]) << 8) | (static_cast<uint64_t>(b[2]) << 16) |
             (static_cast<uint64_t>(b[3]) << 24);
    }
    case 8:
      return read_u64_le(reader);
    default:
      throw invalid_data("smallest u64 size");
  }
}

std::string key_ref_string(const KeyRef& key, const SessionState& state) {
  if (key.is_id) {
    const auto [s, ok] = state.key_table.get_value(key.id);
    return ok ? s : "";
  }
  return key.literal;
}

std::optional<std::string> key_ref_field_identity(const KeyRef& key, const SessionState& state) {
  const auto s = key_ref_string(key, state);
  if (s.empty()) return std::nullopt;
  return s;
}

std::vector<Value> message_fields(const Message& message) {
  switch (message.kind) {
    case MessageKind::Array: {
      std::vector<Value> out;
      for (const auto& v : message.array) out.push_back(v.clone());
      return out;
    }
    case MessageKind::Map: {
      std::vector<Value> out;
      for (const auto& e : message.map) out.push_back(e.value.clone());
      return out;
    }
    case MessageKind::ShapedObject: {
      std::vector<Value> out;
      for (const auto& v : message.shaped_object.values) out.push_back(v.clone());
      return out;
    }
    case MessageKind::SchemaObject: {
      std::vector<Value> out;
      for (const auto& v : message.schema_object.fields) out.push_back(v.clone());
      return out;
    }
    case MessageKind::TypedVector: {
      if (!message.has_typed_vector) return {};
      const auto& tv = message.typed_vector;
      std::vector<Value> out;
      switch (tv.element_type) {
        case ElementType::Bool:
          for (const auto b : tv.data.bools) out.push_back(new_bool(b));
          break;
        case ElementType::I64:
          for (const auto v : tv.data.i64s) out.push_back(new_i64(v));
          break;
        case ElementType::U64:
          for (const auto v : tv.data.u64s) out.push_back(new_u64(v));
          break;
        case ElementType::F64:
          for (const auto v : tv.data.f64s) out.push_back(new_f64(v));
          break;
        case ElementType::String:
          for (const auto& s : tv.data.strings) out.push_back(new_string(s));
          break;
        default:
          break;
      }
      return out;
    }
    default:
      return {};
  }
}

Message rebuild_message_like(const Message& base, const std::vector<Value>& fields) {
  switch (base.kind) {
    case MessageKind::Array: {
      Message msg;
      msg.kind = MessageKind::Array;
      msg.array = fields;
      return msg;
    }
    case MessageKind::Map: {
      std::vector<MessageMapEntry> entries;
      for (size_t i = 0; i < fields.size(); ++i) {
        if (i >= base.map.size()) throw invalid_data("patch map shape mismatch");
        entries.push_back({base.map[i].key, fields[i]});
      }
      Message msg;
      msg.kind = MessageKind::Map;
      msg.map = std::move(entries);
      return msg;
    }
    case MessageKind::ShapedObject: {
      Message msg;
      msg.kind = MessageKind::ShapedObject;
      msg.has_shaped_object = true;
      msg.shaped_object = base.shaped_object;
      msg.shaped_object.values = fields;
      return msg;
    }
    case MessageKind::SchemaObject: {
      Message msg;
      msg.kind = MessageKind::SchemaObject;
      msg.has_schema_object = true;
      msg.schema_object = base.schema_object;
      msg.schema_object.fields = fields;
      return msg;
    }
    case MessageKind::TypedVector: {
      if (!base.has_typed_vector) throw invalid_data("typed vector patch missing base");
      TypedVectorData data;
      switch (base.typed_vector.element_type) {
        case ElementType::Bool:
          for (const auto& v : fields) {
            if (v.kind != ValueKind::Bool) throw invalid_data("typed bool patch");
            data.bools.push_back(v.bool_value);
          }
          break;
        case ElementType::I64:
          for (const auto& v : fields) {
            if (v.kind != ValueKind::I64) throw invalid_data("typed i64 patch");
            data.i64s.push_back(v.i64);
          }
          break;
        case ElementType::U64:
          for (const auto& v : fields) {
            if (v.kind != ValueKind::U64) throw invalid_data("typed u64 patch");
            data.u64s.push_back(v.u64);
          }
          break;
        case ElementType::F64:
          for (const auto& v : fields) {
            if (v.kind != ValueKind::F64) throw invalid_data("typed f64 patch");
            data.f64s.push_back(v.f64);
          }
          break;
        case ElementType::String:
          for (const auto& v : fields) {
            if (v.kind != ValueKind::String) throw invalid_data("typed string patch");
            data.strings.push_back(v.str);
          }
          break;
        default:
          throw invalid_data("typed vector patch unsupported element type");
      }
      Message msg;
      msg.kind = MessageKind::TypedVector;
      msg.has_typed_vector = true;
      msg.typed_vector.element_type = base.typed_vector.element_type;
      msg.typed_vector.codec = base.typed_vector.codec;
      msg.typed_vector.data = std::move(data);
      return msg;
    }
    default:
      throw invalid_data("state patch reconstruction unsupported for this message kind");
  }
}

std::pair<std::vector<PatchOperation>, int> diff_message(const Message& prev, const Message& current) {
  const auto a = message_fields(prev);
  const auto b = message_fields(current);
  const size_t n = std::max(a.size(), b.size());
  std::vector<PatchOperation> ops;
  ops.reserve(n);
  for (size_t i = 0; i < n; ++i) {
    if (i < a.size() && i < b.size()) {
      if (equal(a[i], b[i])) {
        ops.push_back({i, PatchOpcode::Keep, std::nullopt});
      } else {
        ops.push_back({i, PatchOpcode::ReplaceScalar, b[i].clone()});
      }
    } else if (i < b.size()) {
      ops.push_back({i, PatchOpcode::InsertField, b[i].clone()});
    } else {
      ops.push_back({i, PatchOpcode::DeleteField, std::nullopt});
    }
  }
  return {ops, 0};
}

bool supports_state_patch(const Message* base, const Message& current) {
  if (base == nullptr) return false;
  if (base->kind != current.kind) return false;
  switch (base->kind) {
    case MessageKind::Map:
    case MessageKind::SchemaObject:
    case MessageKind::ShapedObject:
    case MessageKind::Array:
      return true;
    case MessageKind::TypedVector:
      return current.has_typed_vector && base->has_typed_vector &&
             base->typed_vector.element_type == current.typed_vector.element_type;
    default:
      return false;
  }
}

namespace {

int estimate_column_size(const Column& column) {
  int size = static_cast<int>(varuint_size(column.field_id)) + 4;
  switch (column.values.kind) {
    case ElementType::Bool:
      size += static_cast<int>(column.values.bools.size() / 8) + 2;
      break;
    case ElementType::I64:
      size += static_cast<int>(column.values.i64s.size()) * 4;
      break;
    case ElementType::U64:
      size += static_cast<int>(column.values.u64s.size()) * 4;
      break;
    case ElementType::F64:
      size += static_cast<int>(column.values.f64s.size()) * 8;
      break;
    case ElementType::String:
      for (const auto& s : column.values.strings) size += encoded_string_size(s);
      break;
    default:
      break;
  }
  return size;
}

}  // namespace

int encoded_size(const Message& message) {
  switch (message.kind) {
    case MessageKind::Scalar:
      return 1 + estimate_value_size(message.scalar);
    case MessageKind::Array: {
      int sum = 1 + varuint_size(message.array.size());
      for (const auto& v : message.array) sum += estimate_value_size(v);
      return sum;
    }
    case MessageKind::Map: {
      int sum = 1 + varuint_size(message.map.size());
      for (const auto& e : message.map) {
        sum += static_cast<int>(e.key.literal.size()) + estimate_value_size(e.value);
      }
      return sum;
    }
    case MessageKind::StatePatch: {
      int sum = 1 + 2 + varuint_size(message.state_patch.operations.size());
      for (const auto& op : message.state_patch.operations) {
        sum += varuint_size(op.field_id) + 2;
        if (op.value) sum += estimate_value_size(*op.value);
      }
      return sum;
    }
    default:
      return 16;
  }
}

TypedVectorData typed_data_i64(const std::vector<int64_t>& data) {
  TypedVectorData tvd;
  tvd.kind = ElementType::I64;
  tvd.i64s = data;
  return tvd;
}

TypedVectorData typed_data_u64(const std::vector<uint64_t>& data) {
  TypedVectorData tvd;
  tvd.kind = ElementType::U64;
  tvd.u64s = data;
  return tvd;
}

TypedVectorData typed_data_f64(const std::vector<double>& data) {
  TypedVectorData tvd;
  tvd.kind = ElementType::F64;
  tvd.f64s = data;
  return tvd;
}

TypedVectorData typed_data_bool(const std::vector<bool>& data) {
  TypedVectorData tvd;
  tvd.kind = ElementType::Bool;
  tvd.bools = data;
  return tvd;
}

TypedVectorData typed_data_string(const std::vector<std::string>& data) {
  TypedVectorData tvd;
  tvd.kind = ElementType::String;
  tvd.strings = data;
  return tvd;
}

VectorCodec select_integer_codec(const std::vector<int64_t>& values) {
  if (values.size() < 4) return VectorCodec::Plain;
  const auto delta_vals = deltas(values);
  std::vector<int64_t> dd = deltas(delta_vals);
  int non_zero_dd = 0;
  for (size_t i = 1; i < dd.size(); ++i) {
    if (dd[i] != 0) ++non_zero_dd;
  }
  const double non_zero_ratio = dd.size() > 1 ? static_cast<double>(non_zero_dd) / static_cast<double>(dd.size() - 1) : 0.0;
  int64_t dmin = delta_vals[0];
  int64_t dmax = delta_vals[0];
  for (const auto v : delta_vals) {
    dmin = std::min(dmin, v);
    dmax = std::max(dmax, v);
  }
  const int delta_range_bits = bit_width_u64(static_cast<uint64_t>(dmax >= dmin ? dmax - dmin : dmin - dmax));
  if (values.size() >= 8 && (non_zero_ratio <= 0.25 || delta_range_bits <= 2)) {
    return VectorCodec::DeltaDeltaBitpack;
  }
  const auto [repeated_ratio, avg_run] = run_stats(values);
  if (repeated_ratio >= 0.5 && avg_run >= 3.0) return VectorCodec::Rle;
  int64_t vmin = values[0];
  int64_t vmax = values[0];
  for (const auto v : values) {
    vmin = std::min(vmin, v);
    vmax = std::max(vmax, v);
  }
  const int range_bits = bit_width_u64(static_cast<uint64_t>(vmax >= vmin ? vmax - vmin : vmin - vmax));
  if (range_bits <= 60) return VectorCodec::ForBitpack;
  bool monotonic = true;
  for (size_t i = 1; i < values.size(); ++i) {
    if (values[i] < values[i - 1]) {
      monotonic = false;
      break;
    }
  }
  if (values.size() >= 8 && monotonic && delta_range_bits <= range_bits - 3) {
    return VectorCodec::DeltaForBitpack;
  }
  int max_abs_delta_bits = 0;
  for (const auto v : delta_vals) max_abs_delta_bits = std::max(max_abs_delta_bits, bit_width_u64(abs64(v)));
  if (max_abs_delta_bits <= 61) return VectorCodec::DeltaBitpack;
  int max_bit_width = 0;
  for (const auto v : values) max_bit_width = std::max(max_bit_width, bit_width_u64(abs64(v)));
  if (values.size() >= 8 && max_bit_width <= 16 && !monotonic) return VectorCodec::Simple8b;
  if (max_bit_width < 64) return VectorCodec::DirectBitpack;
  return VectorCodec::Plain;
}

VectorCodec select_u64_codec(const std::vector<uint64_t>& values) {
  bool all_signed = true;
  for (const auto v : values) {
    if (v > 0x7FFFFFFFFFFFFFFFULL) {
      all_signed = false;
      break;
    }
  }
  if (all_signed) {
    std::vector<int64_t> signed_vals;
    signed_vals.reserve(values.size());
    for (const auto v : values) signed_vals.push_back(static_cast<int64_t>(v & 0x7FFFFFFFFFFFFFFFULL));
    return select_integer_codec(signed_vals);
  }
  if (values.size() < 4) return VectorCodec::DirectBitpack;
  const auto [repeated_ratio, avg_run] = run_stats(std::vector<int64_t>(values.begin(), values.end()));
  if (repeated_ratio >= 0.5 && avg_run >= 3.0) return VectorCodec::Rle;
  uint64_t vmin = values[0];
  uint64_t vmax = values[0];
  for (const auto v : values) {
    vmin = std::min(vmin, v);
    vmax = std::max(vmax, v);
  }
  if (bit_width_u64(vmax - vmin) <= 60) return VectorCodec::ForBitpack;
  int max_width = 0;
  for (const auto v : values) max_width = std::max(max_width, bit_width_u64(v));
  if (values.size() >= 8 && max_width <= 16) return VectorCodec::Simple8b;
  if (max_width < 64) return VectorCodec::DirectBitpack;
  return VectorCodec::Plain;
}

VectorCodec select_float_codec(const std::vector<double>& values) {
  if (values.size() < 4) return VectorCodec::Plain;
  uint64_t prev = 0;
  std::memcpy(&prev, &values[0], sizeof(double));
  int changes = 0;
  for (size_t i = 1; i < values.size(); ++i) {
    uint64_t bits = 0;
    std::memcpy(&bits, &values[i], sizeof(double));
    if (bits != prev) ++changes;
    prev = bits;
  }
  return changes * 2 <= static_cast<int>(values.size()) ? VectorCodec::XorFloat : VectorCodec::Plain;
}

VectorCodec select_string_codec(const std::vector<std::string>& values) {
  if (values.empty()) return VectorCodec::Plain;
  std::unordered_set<std::string> uniq(values.begin(), values.end());
  if (uniq.size() * 2 <= values.size()) return VectorCodec::Dictionary;
  int prefix_gain = 0;
  std::string prev;
  for (const auto& v : values) {
    prefix_gain += common_prefix_len(prev, v);
    prev = v;
  }
  if (prefix_gain > static_cast<int>(values.size()) * 2) return VectorCodec::PrefixDelta;
  return VectorCodec::Plain;
}

std::pair<VectorCodec, TypedVectorData> infer_column_codec_and_values(const std::vector<Value>& values) {
  if (values.empty()) return {VectorCodec::Plain, typed_data_i64({})};
  bool all_i64 = true;
  bool all_u64 = true;
  bool all_f64 = true;
  bool all_bool = true;
  bool all_str = true;
  for (const auto& v : values) {
    all_i64 = all_i64 && v.kind == ValueKind::I64;
    all_u64 = all_u64 && v.kind == ValueKind::U64;
    all_f64 = all_f64 && v.kind == ValueKind::F64;
    all_bool = all_bool && v.kind == ValueKind::Bool;
    all_str = all_str && v.kind == ValueKind::String;
  }
  if (all_i64) {
    std::vector<int64_t> data;
    data.reserve(values.size());
    for (const auto& v : values) data.push_back(v.i64);
    return {select_integer_codec(data), typed_data_i64(data)};
  }
  if (all_u64) {
    std::vector<uint64_t> data;
    for (const auto& v : values) data.push_back(v.u64);
    return {select_u64_codec(data), typed_data_u64(data)};
  }
  if (all_f64) {
    std::vector<double> data;
    for (const auto& v : values) data.push_back(v.f64);
    return {select_float_codec(data), typed_data_f64(data)};
  }
  if (all_bool) {
    std::vector<bool> data;
    for (const auto& v : values) data.push_back(v.bool_value);
    return {VectorCodec::DirectBitpack, typed_data_bool(data)};
  }
  if (all_str) {
    std::vector<std::string> data;
    for (const auto& v : values) data.push_back(v.str);
    return {select_string_codec(data), typed_data_string(data)};
  }
  std::vector<Value> cloned;
  for (const auto& v : values) cloned.push_back(v.clone());
  TypedVectorData tvd;
  tvd.kind = ElementType::Value;
  tvd.values = std::move(cloned);
  return {VectorCodec::Plain, tvd};
}

std::vector<std::vector<Value>> rows_from_values(const std::vector<Value>& values) {
  std::vector<std::vector<Value>> rows;
  rows.reserve(values.size());
  for (const auto& v : values) {
    if (v.kind == ValueKind::Array) {
      std::vector<Value> row;
      for (const auto& x : v.arr) row.push_back(x.clone());
      rows.push_back(std::move(row));
    } else {
      rows.push_back({v.clone()});
    }
  }
  return rows;
}

std::vector<Column> rows_to_columns(const std::vector<std::vector<Value>>& rows) {
  if (rows.empty()) return {};
  size_t width = 0;
  for (const auto& row : rows) width = std::max(width, row.size());
  std::vector<std::vector<Value>> column_values(width);
  std::vector<std::vector<bool>> column_presence(width);
  for (const auto& row : rows) {
    for (size_t col = 0; col < width; ++col) {
      const Value value = col < row.size() ? row[col].clone() : new_null();
      column_values[col].push_back(value);
      column_presence[col].push_back(value.kind != ValueKind::Null);
    }
  }
  std::vector<Column> columns;
  columns.reserve(width);
  for (size_t col = 0; col < width; ++col) {
    const auto null_info = column_null_strategy(column_values[col], column_presence[col]);
    const auto null_strategy = null_info.strategy;
    const auto& presence = null_info.presence;
    const auto has_presence = null_info.has_presence;
    const auto [codec, tvd] = infer_column_codec_and_values(strip_nulls(column_values[col]));
    columns.push_back(
        Column{col, null_strategy, presence, has_presence, codec, std::nullopt, tvd});
  }
  return columns;
}

std::vector<Column> columns_from_map_values(const std::vector<Value>& values) {
  if (values.empty()) return {};
  for (const auto& v : values) {
    if (v.kind != ValueKind::Map) return {};
  }
  std::vector<std::string> key_order;
  std::unordered_map<std::string, size_t> key_index;
  std::vector<std::vector<Value>> column_values;
  std::vector<std::vector<bool>> column_presence;
  for (size_t row_idx = 0; row_idx < values.size(); ++row_idx) {
    const auto& row = values[row_idx];
    std::vector<bool> present(key_order.size(), false);
    for (const auto& e : row.map) {
      const auto& key = e.key;
      auto it = key_index.find(key);
      size_t col_idx;
      if (it == key_index.end()) {
        col_idx = key_order.size();
        key_order.push_back(key);
        key_index[key] = col_idx;
        column_values.emplace_back(row_idx, new_null());
        column_presence.emplace_back(row_idx, false);
        present.push_back(false);
      } else {
        col_idx = it->second;
      }
      column_values[col_idx].push_back(e.value.clone());
      column_presence[col_idx].push_back(true);
      present[col_idx] = true;
    }
    for (size_t col_idx = 0; col_idx < key_order.size(); ++col_idx) {
      if (!present[col_idx]) {
        column_values[col_idx].push_back(new_null());
        column_presence[col_idx].push_back(false);
      }
    }
  }
  std::vector<Column> columns;
  columns.reserve(key_order.size());
  for (size_t field_id = 0; field_id < key_order.size(); ++field_id) {
    const auto null_info = column_null_strategy(column_values[field_id], column_presence[field_id]);
    const auto null_strategy = null_info.strategy;
    const auto& presence = null_info.presence;
    const auto has_presence = null_info.has_presence;
    const auto [codec, tvd] = infer_column_codec_and_values(strip_nulls(column_values[field_id]));
    columns.push_back(
        Column{field_id, null_strategy, presence, has_presence, codec, std::nullopt, tvd});
  }
  return columns;
}

bool has_uniform_micro_batch_shape(const std::vector<Value>& values) {
  if (values.empty() || values[0].kind != ValueKind::Map) return false;
  std::vector<std::string> keys;
  keys.reserve(values[0].map.size());
  for (const auto& e : values[0].map) keys.push_back(e.key);
  for (size_t i = 1; i < values.size(); ++i) {
    const auto& v = values[i];
    if (v.kind != ValueKind::Map || v.map.size() != keys.size()) return false;
    for (size_t j = 0; j < keys.size(); ++j) {
      if (v.map[j].key != keys[j]) return false;
    }
  }
  return true;
}

TemplateDescriptor template_descriptor_from_columns(uint64_t template_id,
                                                    const std::vector<Column>& columns) {
  TemplateDescriptor d;
  d.template_id = template_id;
  for (const auto& c : columns) {
    d.field_ids.push_back(c.field_id);
    d.null_strategies.push_back(c.null_strategy);
    d.codecs.push_back(c.codec);
  }
  return d;
}

std::pair<uint64_t, bool> find_template_id(
    const std::unordered_map<uint64_t, TemplateDescriptor>& templates,
    const std::vector<Column>& columns) {
  std::vector<uint64_t> ids;
  ids.reserve(templates.size());
  for (const auto& kv : templates) ids.push_back(kv.first);
  std::sort(ids.begin(), ids.end());
  for (const auto id : ids) {
    const auto& t = templates.at(id);
    if (t.field_ids.size() != columns.size()) continue;
    bool ok = true;
    for (size_t i = 0; i < columns.size(); ++i) {
      if (t.field_ids[i] != columns[i].field_id || t.null_strategies[i] != columns[i].null_strategy) {
        ok = false;
        break;
      }
    }
    if (ok) return {id, true};
  }
  return {0, false};
}

std::pair<std::vector<bool>, std::vector<Column>> diff_template_columns(const std::vector<Column>& previous,
                                                                        const std::vector<Column>& current) {
  std::vector<bool> mask;
  std::vector<Column> changed;
  mask.reserve(current.size());
  for (size_t i = 0; i < current.size(); ++i) {
    if (i >= previous.size() || estimate_column_size(previous[i]) != estimate_column_size(current[i])) {
      mask.push_back(true);
      changed.push_back(current[i]);
    } else {
      mask.push_back(false);
    }
  }
  return {mask, changed};
}

std::vector<Column> merge_template_columns(const std::vector<Column>& previous,
                                           const std::vector<bool>& changed_mask,
                                           const std::vector<Column>& changed) {
  std::vector<Column> out(changed_mask.size());
  size_t idx = 0;
  for (size_t i = 0; i < changed_mask.size(); ++i) {
    if (changed_mask[i]) {
      if (idx >= changed.size()) throw invalid_data("template changed column count mismatch");
      out[i] = changed[idx++];
    } else {
      if (i >= previous.size()) throw invalid_data("template reference out of range");
      out[i] = previous[i];
    }
  }
  return out;
}

void apply_dictionary_references(SessionState&, std::vector<Column>&) {}

int common_prefix_len(const std::string& a, const std::string& b) {
  const size_t n = std::min(a.size(), b.size());
  for (size_t i = 0; i < n; ++i) {
    if (a[i] != b[i]) return static_cast<int>(i);
  }
  return static_cast<int>(n);
}

bool should_register_shape(const std::vector<std::string>& keys, int observed_count) {
  return !keys.empty() && observed_count >= 2;
}

std::vector<uint8_t> control_bitpack_encode_bytes(const std::vector<uint8_t>& input) { return input; }
std::vector<uint8_t> control_bitpack_decode_bytes(const std::vector<uint8_t>& input) { return input; }
std::vector<uint8_t> control_huffman_encode_bytes(const std::vector<uint8_t>& input) { return input; }
std::vector<uint8_t> control_huffman_decode_bytes(const std::vector<uint8_t>& input) { return input; }
std::vector<uint8_t> control_fse_encode_bytes(const std::vector<uint8_t>& input) { return input; }
std::vector<uint8_t> control_fse_decode_bytes(const std::vector<uint8_t>& input) { return input; }

namespace {

int varuint_size(uint64_t value) {
  int sz = 1;
  while (value >= 0x80) {
    value >>= 7;
    ++sz;
  }
  return sz;
}

int smallest_u64_size(uint64_t value) {
  if (value <= 0xFF) return 1;
  if (value <= 0xFFFF) return 2;
  if (value <= 0xFFFFFFFFULL) return 4;
  return 8;
}

int encoded_string_size(const std::string& value) {
  return varuint_size(value.size()) + static_cast<int>(value.size());
}

int estimate_value_size(const Value& value) {
  switch (value.kind) {
    case ValueKind::Null:
    case ValueKind::Bool:
      return 1;
    case ValueKind::I64:
      return 2 + smallest_u64_size(encode_zigzag(value.i64));
    case ValueKind::U64:
      return 2 + smallest_u64_size(value.u64);
    case ValueKind::F64:
      return 9;
    case ValueKind::String:
      return 2 + encoded_string_size(value.str);
    default:
      return 1;
  }
}

}  // namespace

}  // namespace twilic
