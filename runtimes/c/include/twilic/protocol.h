#pragma once
#include <optional>
#include <vector>

#include "twilic/model.h"
#include "twilic/session.h"
#include "twilic/wire.h"

namespace twilic {

class TwilicCodec {
 public:
  explicit TwilicCodec(SessionState state = new_session_state());

  std::vector<uint8_t> encode_message(const Message& message);
  Message decode_message(const std::vector<uint8_t>& data);
  std::vector<uint8_t> encode_value(const Value& value);
  Value decode_value(const std::vector<uint8_t>& data);

  SessionState state;
  Message message_for_value(const Value& value);

 private:
  [[noreturn]] void reference_error(const std::string& kind, uint64_t ref_id) const;

  Message map_message(const std::vector<MapEntry>& entries);
  Message shaped_message(uint64_t shape_id, const std::vector<MapEntry>& entries);
  std::optional<TypedVector> try_make_typed_vector(const std::vector<Value>& values);
  int observe_encode_shape_candidate(const std::vector<std::string>& keys);
  void observe_decode_shape_candidate(const std::vector<std::string>& keys);

  void write_message(const Message& message, Buffer& out);
  Message read_message(Reader& reader);
  void write_value(const Value& value, Buffer& out);
  void write_value_with_field(const Value& value, const std::optional<std::string>& field_identity, Buffer& out);
  Value read_value(Reader& reader);
  Value read_value_with_field(Reader& reader, const std::optional<std::string>& field_identity);
  Value read_string_value(Reader& reader, const std::optional<std::string>& field_identity);
  void write_key_ref(const KeyRef& key_ref, Buffer& out);
  KeyRef read_key_ref(Reader& reader);
  void write_presence(const std::vector<bool>& presence, bool has_presence, Buffer& out);
  std::pair<std::vector<bool>, bool> read_presence(Reader& reader);
  void write_typed_vector(const TypedVector& vector, Buffer& out);
  TypedVector read_typed_vector(Reader& reader, std::optional<ElementType> forced_element,
                                std::optional<VectorCodec> expected_codec);
  void write_string_vector(const std::vector<std::string>& values, VectorCodec codec, Buffer& out);
  std::vector<std::string> read_string_vector(Reader& reader, VectorCodec codec);
  void write_column(const Column& column, Buffer& out);
  Column read_column(Reader& reader);
  void write_base_ref(const BaseRef& base_ref, Buffer& out);
  BaseRef read_base_ref(Reader& reader);
  void write_control_stream_payload(ControlStreamCodec codec, const std::vector<uint8_t>& payload, Buffer& out);
  std::vector<uint8_t> read_control_stream_payload(ControlStreamCodec codec, Reader& reader);
  Message apply_state_patch(const BaseRef& base_ref, const std::vector<PatchOperation>& operations,
                            const std::vector<Value>& literals);
  struct PrefixBaseMatch {
    uint64_t base_id = 0;
    int prefix_len = 0;
    bool ok = false;
  };
  PrefixBaseMatch best_prefix_base(const std::string& value) const;
};

class SessionEncoder {
 public:
  explicit SessionEncoder(std::optional<SessionOptions> options = std::nullopt);

  std::vector<uint8_t> encode(const Value& value);
  std::vector<uint8_t> encode_with_schema(const Schema& schema, const Value& value);
  std::vector<uint8_t> encode_batch(const std::vector<Value>& values);
  std::vector<uint8_t> encode_patch(const Value& value);
  std::vector<uint8_t> encode_micro_batch(const std::vector<Value>& values);
  Message decode_message(const std::vector<uint8_t>& data);
  void reset();

  TwilicCodec codec;

 private:
  void record_full_message_as_base();
};

TwilicCodec new_twilic_codec();
SessionEncoder new_session_encoder(std::optional<SessionOptions> options = std::nullopt);

std::vector<uint8_t> encode(const Value& value);
Value decode(const std::vector<uint8_t>& data);
std::vector<uint8_t> encode_with_schema(const Schema& schema, const Value& value);
std::vector<uint8_t> encode_batch(const std::vector<Value>& values);

}  // namespace twilic
