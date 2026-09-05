#pragma once
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace twilic {

enum class MessageKind : uint8_t {
  Scalar = 0x00,
  Array = 0x01,
  Map = 0x02,
  ShapedObject = 0x03,
  SchemaObject = 0x04,
  TypedVector = 0x05,
  RowBatch = 0x06,
  ColumnBatch = 0x07,
  Control = 0x08,
  Ext = 0x09,
  StatePatch = 0x0A,
  TemplateBatch = 0x0B,
  ControlStream = 0x0C,
  BaseSnapshot = 0x0D,
};

enum class NullStrategy : uint8_t {
  None = 0,
  PresenceBitmap = 1,
  InvertedPresenceBitmap = 2,
  AllPresentElided = 3,
};

enum class PatchOpcode : uint8_t {
  Keep = 0,
  ReplaceScalar = 1,
  ReplaceVector = 2,
  AppendVector = 3,
  TruncateVector = 4,
  DeleteField = 5,
  InsertField = 6,
  StringRef = 7,
  PrefixDelta = 8,
};

enum class ControlOpcode : uint8_t {
  RegisterKeys = 0,
  RegisterShape = 1,
  RegisterStrings = 2,
  PromoteStringFieldToEnum = 3,
  ResetTables = 4,
  ResetState = 5,
};

enum class ControlStreamCodec : uint8_t {
  Plain = 0,
  Rle = 1,
  Bitpack = 2,
  Huffman = 3,
  Fse = 4,
};

enum class ValueKind {
  Null,
  Bool,
  I64,
  U64,
  F64,
  String,
  Binary,
  Array,
  Map,
};

struct Value {
  ValueKind kind = ValueKind::Null;
  bool bool_value = false;
  int64_t i64 = 0;
  uint64_t u64 = 0;
  double f64 = 0.0;
  std::string str;
  std::vector<uint8_t> bin;
  std::vector<Value> arr;
  std::vector<struct MapEntry> map;

  Value clone() const;
  bool is_scalar() const;
};

struct MapEntry {
  std::string key;
  Value value;
};

struct KeyRef {
  std::string literal;
  uint64_t id = 0;
  bool is_id = false;
  static KeyRef literal_ref(const std::string& s);
  static KeyRef id_ref(uint64_t id);
};

enum class StringMode : uint8_t { Empty, Literal, Ref, PrefixDelta, InlineEnum };

enum class ElementType : uint8_t { Bool, I64, U64, F64, String, Binary, Value };

enum class VectorCodec : uint8_t {
  Plain,
  DirectBitpack,
  DeltaBitpack,
  ForBitpack,
  DeltaForBitpack,
  DeltaDeltaBitpack,
  Rle,
  PatchedFor,
  Simple8b,
  XorFloat,
  Dictionary,
  StringRef,
  PrefixDelta,
};

struct MessageMapEntry {
  KeyRef key;
  Value value;
};

struct ShapedObjectMessage {
  uint64_t shape_id = 0;
  std::vector<bool> presence;
  bool has_presence = false;
  std::vector<Value> values;
};

struct SchemaField {
  int number = 0;
  std::string name;
  std::string logical_type;
  bool required = false;
  std::vector<std::string> enum_values;
};

struct Schema {
  uint64_t schema_id = 0;
  std::string name;
  std::vector<SchemaField> fields;
};

struct SchemaObjectMessage {
  uint64_t schema_id = 0;
  bool has_schema_id = false;
  std::vector<Value> fields;
};

struct RowBatchMessage {
  std::vector<std::vector<Value>> rows;
};

struct TypedVectorData {
  ElementType kind = ElementType::Bool;
  std::vector<bool> bools;
  std::vector<int64_t> i64s;
  std::vector<uint64_t> u64s;
  std::vector<double> f64s;
  std::vector<std::string> strings;
  std::vector<std::vector<uint8_t>> binary;
  std::vector<Value> values;
};

struct TypedVector {
  ElementType element_type = ElementType::Bool;
  VectorCodec codec = VectorCodec::Plain;
  TypedVectorData data;
};

struct Column {
  uint64_t field_id = 0;
  NullStrategy null_strategy = NullStrategy::AllPresentElided;
  std::vector<bool> presence;
  bool has_presence = false;
  VectorCodec codec = VectorCodec::Plain;
  std::optional<uint64_t> dictionary_id;
  TypedVectorData values;
};

struct ColumnBatchMessage {
  uint64_t count = 0;
  std::vector<Column> columns;
};

struct BaseRef {
  bool previous = false;
  uint64_t base_id = 0;
  static BaseRef previous_ref();
  static BaseRef id_ref(uint64_t id);
};

struct PatchOperation {
  uint64_t field_id = 0;
  PatchOpcode opcode = PatchOpcode::Keep;
  std::optional<Value> value;
};

struct StatePatchMessage {
  BaseRef base_ref = BaseRef::previous_ref();
  std::vector<PatchOperation> operations;
  std::vector<Value> literals;
};

struct TemplateBatchMessage {
  uint64_t template_id = 0;
  uint64_t count = 0;
  std::vector<bool> changed_column_mask;
  std::vector<Column> columns;
};

struct TemplateDescriptor {
  uint64_t template_id = 0;
  std::vector<uint64_t> field_ids;
  std::vector<NullStrategy> null_strategies;
  std::vector<VectorCodec> codecs;
};

struct ExtMessage {
  uint64_t ext_type = 0;
  std::vector<uint8_t> payload;
};

struct RegisterShapeControl {
  uint64_t shape_id = 0;
  std::vector<KeyRef> keys;
};

struct PromoteEnumControl {
  std::string field_identity;
  std::vector<std::string> values;
};

struct ControlMessage {
  ControlOpcode opcode = ControlOpcode::RegisterKeys;
  std::vector<std::string> register_keys;
  std::optional<RegisterShapeControl> register_shape;
  std::vector<std::string> register_strings;
  std::optional<PromoteEnumControl> promote_string_field_to_enum;
  bool reset_tables = false;
  bool reset_state = false;
};

struct ControlStreamMessage {
  ControlStreamCodec codec = ControlStreamCodec::Plain;
  std::vector<uint8_t> payload;
};

struct BaseSnapshotMessage;

struct Message {
  MessageKind kind = MessageKind::Scalar;
  Value scalar;
  std::vector<Value> array;
  std::vector<MessageMapEntry> map;
  ShapedObjectMessage shaped_object;
  SchemaObjectMessage schema_object;
  TypedVector typed_vector;
  RowBatchMessage row_batch;
  ColumnBatchMessage column_batch;
  ControlMessage control;
  ExtMessage ext;
  StatePatchMessage state_patch;
  TemplateBatchMessage template_batch;
  ControlStreamMessage control_stream;
  std::unique_ptr<BaseSnapshotMessage> base_snapshot;
  bool has_scalar = false;
  bool has_shaped_object = false;
  bool has_schema_object = false;
  bool has_typed_vector = false;
  bool has_row_batch = false;
  bool has_column_batch = false;
  bool has_control = false;
  bool has_ext = false;
  bool has_state_patch = false;
  bool has_template_batch = false;
  bool has_control_stream = false;
  bool has_base_snapshot = false;

  Message() = default;
  Message(const Message&) = delete;
  Message& operator=(const Message&) = delete;
  Message(Message&&) = default;
  Message& operator=(Message&&) = default;

  Message clone() const;
};

struct BaseSnapshotMessage {
  uint64_t base_id = 0;
  uint64_t schema_or_shape_ref = 0;
  Message payload;
};

bool message_kind_from_byte(uint8_t b, MessageKind& out);
bool patch_opcode_from_byte(uint8_t b, PatchOpcode& out);
bool null_strategy_from_byte(uint8_t b, NullStrategy& out);
bool control_opcode_from_byte(uint8_t b, ControlOpcode& out);
bool control_stream_codec_from_byte(uint8_t b, ControlStreamCodec& out);
bool element_type_from_byte(uint8_t b, ElementType& out);
bool vector_codec_from_byte(uint8_t b, VectorCodec& out);
bool string_mode_from_byte(uint8_t b, StringMode& out);
Value new_null();
Value new_bool(bool b);
Value new_i64(int64_t n);
Value new_u64(uint64_t n);
Value new_f64(double n);
Value new_string(const std::string& s);
Value new_binary(const std::vector<uint8_t>& b);
Value new_array(std::vector<Value> items);
MapEntry entry(const std::string& key, Value value);
Value new_map(std::vector<MapEntry> entries);
Value new_map(std::initializer_list<MapEntry> entries);
bool equal(const Value& a, const Value& b);

}  // namespace twilic
