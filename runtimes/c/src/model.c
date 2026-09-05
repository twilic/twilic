#include "twilic/model.h"

namespace twilic {

bool message_kind_from_byte(uint8_t b, MessageKind& out) {
  if (b > static_cast<uint8_t>(MessageKind::BaseSnapshot)) return false;
  out = static_cast<MessageKind>(b);
  return true;
}

bool patch_opcode_from_byte(uint8_t b, PatchOpcode& out) {
  if (b > static_cast<uint8_t>(PatchOpcode::PrefixDelta)) return false;
  out = static_cast<PatchOpcode>(b);
  return true;
}

bool null_strategy_from_byte(uint8_t b, NullStrategy& out) {
  if (b > static_cast<uint8_t>(NullStrategy::AllPresentElided)) return false;
  out = static_cast<NullStrategy>(b);
  return true;
}

bool control_opcode_from_byte(uint8_t b, ControlOpcode& out) {
  if (b > static_cast<uint8_t>(ControlOpcode::ResetState)) return false;
  out = static_cast<ControlOpcode>(b);
  return true;
}

bool control_stream_codec_from_byte(uint8_t b, ControlStreamCodec& out) {
  if (b > static_cast<uint8_t>(ControlStreamCodec::Fse)) return false;
  out = static_cast<ControlStreamCodec>(b);
  return true;
}

bool element_type_from_byte(uint8_t b, ElementType& out) {
  if (b > static_cast<uint8_t>(ElementType::Value)) return false;
  out = static_cast<ElementType>(b);
  return true;
}

bool vector_codec_from_byte(uint8_t b, VectorCodec& out) {
  if (b > static_cast<uint8_t>(VectorCodec::PrefixDelta)) return false;
  out = static_cast<VectorCodec>(b);
  return true;
}

bool string_mode_from_byte(uint8_t b, StringMode& out) {
  if (b > static_cast<uint8_t>(StringMode::InlineEnum)) return false;
  out = static_cast<StringMode>(b);
  return true;
}

BaseRef BaseRef::previous_ref() {
  BaseRef r;
  r.previous = true;
  return r;
}

BaseRef BaseRef::id_ref(uint64_t id) {
  BaseRef r;
  r.base_id = id;
  return r;
}

Message Message::clone() const {
  Message m;
  m.kind = kind;
  m.has_scalar = has_scalar;
  m.has_shaped_object = has_shaped_object;
  m.has_schema_object = has_schema_object;
  m.has_typed_vector = has_typed_vector;
  m.has_row_batch = has_row_batch;
  m.has_column_batch = has_column_batch;
  m.has_control = has_control;
  m.has_ext = has_ext;
  m.has_state_patch = has_state_patch;
  m.has_template_batch = has_template_batch;
  m.has_control_stream = has_control_stream;
  m.has_base_snapshot = has_base_snapshot;
  if (has_scalar) m.scalar = scalar.clone();
  for (const auto& v : array) m.array.push_back(v.clone());
  for (const auto& e : map) m.map.push_back({e.key, e.value.clone()});
  if (has_shaped_object) {
    m.shaped_object = shaped_object;
    for (auto& v : m.shaped_object.values) v = v.clone();
  }
  if (has_schema_object) {
    m.schema_object = schema_object;
    for (auto& v : m.schema_object.fields) v = v.clone();
  }
  if (has_typed_vector) m.typed_vector = typed_vector;
  if (has_row_batch) {
    m.row_batch = row_batch;
    for (auto& row : m.row_batch.rows) {
      for (auto& v : row) v = v.clone();
    }
  }
  if (has_column_batch) m.column_batch = column_batch;
  if (has_control) m.control = control;
  if (has_ext) m.ext = ext;
  if (has_state_patch) {
    m.state_patch = state_patch;
    for (auto& op : m.state_patch.operations) {
      if (op.value) op.value = op.value->clone();
    }
    for (auto& lit : m.state_patch.literals) lit = lit.clone();
  }
  if (has_template_batch) m.template_batch = template_batch;
  if (has_control_stream) m.control_stream = control_stream;
  if (has_base_snapshot && base_snapshot) {
    auto snap = std::make_unique<BaseSnapshotMessage>();
    snap->base_id = base_snapshot->base_id;
    snap->schema_or_shape_ref = base_snapshot->schema_or_shape_ref;
    snap->payload = base_snapshot->payload.clone();
    m.base_snapshot = std::move(snap);
  }
  return m;
}

KeyRef KeyRef::literal_ref(const std::string& s) {
  KeyRef k;
  k.literal = s;
  return k;
}

KeyRef KeyRef::id_ref(uint64_t id) {
  KeyRef k;
  k.id = id;
  k.is_id = true;
  return k;
}

bool Value::is_scalar() const {
  return kind != ValueKind::Array && kind != ValueKind::Map;
}

Value Value::clone() const {
  switch (kind) {
    case ValueKind::Null:
    case ValueKind::Bool:
    case ValueKind::I64:
    case ValueKind::U64:
    case ValueKind::F64:
    case ValueKind::String: {
      Value v;
      v.kind = kind;
      v.bool_value = bool_value;
      v.i64 = i64;
      v.u64 = u64;
      v.f64 = f64;
      v.str = str;
      return v;
    }
    case ValueKind::Binary: {
      Value v;
      v.kind = kind;
      v.bin = bin;
      return v;
    }
    case ValueKind::Array: {
      std::vector<Value> items;
      items.reserve(arr.size());
      for (const auto& x : arr) items.push_back(x.clone());
      return new_array(std::move(items));
    }
    case ValueKind::Map: {
      std::vector<MapEntry> entries;
      entries.reserve(map.size());
      for (const auto& e : map) entries.push_back(entry(e.key, e.value.clone()));
      return new_map(std::move(entries));
    }
  }
  return new_null();
}

static bool bytes_equal(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Value new_null() { return Value{}; }
Value new_bool(bool b) {
  Value v;
  v.kind = ValueKind::Bool;
  v.bool_value = b;
  return v;
}
Value new_i64(int64_t n) {
  Value v;
  v.kind = ValueKind::I64;
  v.i64 = n;
  return v;
}
Value new_u64(uint64_t n) {
  Value v;
  v.kind = ValueKind::U64;
  v.u64 = n;
  return v;
}
Value new_f64(double n) {
  Value v;
  v.kind = ValueKind::F64;
  v.f64 = n;
  return v;
}
Value new_string(const std::string& s) {
  Value v;
  v.kind = ValueKind::String;
  v.str = s;
  return v;
}
Value new_binary(const std::vector<uint8_t>& b) {
  Value v;
  v.kind = ValueKind::Binary;
  v.bin = b;
  return v;
}
Value new_array(std::vector<Value> items) {
  Value v;
  v.kind = ValueKind::Array;
  v.arr = std::move(items);
  return v;
}
MapEntry entry(const std::string& key, Value value) {
  return MapEntry{key, value.clone()};
}
Value new_map(std::vector<MapEntry> entries) {
  Value v;
  v.kind = ValueKind::Map;
  v.map = std::move(entries);
  return v;
}
Value new_map(std::initializer_list<MapEntry> entries) {
  return new_map(std::vector<MapEntry>(entries));
}

bool equal(const Value& a, const Value& b) {
  if (a.kind != b.kind) return false;
  switch (a.kind) {
    case ValueKind::Null:
      return true;
    case ValueKind::Bool:
      return a.bool_value == b.bool_value;
    case ValueKind::I64:
      return a.i64 == b.i64;
    case ValueKind::U64:
      return a.u64 == b.u64;
    case ValueKind::F64:
      return a.f64 == b.f64;
    case ValueKind::String:
      return a.str == b.str;
    case ValueKind::Binary:
      return bytes_equal(a.bin, b.bin);
    case ValueKind::Array:
      if (a.arr.size() != b.arr.size()) return false;
      for (size_t i = 0; i < a.arr.size(); ++i) {
        if (!equal(a.arr[i], b.arr[i])) return false;
      }
      return true;
    case ValueKind::Map:
      if (a.map.size() != b.map.size()) return false;
      for (size_t i = 0; i < a.map.size(); ++i) {
        if (a.map[i].key != b.map[i].key || !equal(a.map[i].value, b.map[i].value)) return false;
      }
      return true;
  }
  return false;
}

}  // namespace twilic
