#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "twilic/model.h"
#include "twilic/session.h"
#include "twilic/wire.h"

namespace twilic {

size_t typed_vector_len(const TypedVectorData& data);
TypedVectorData clone_typed_vector_data(const TypedVectorData& data);
Value typed_vector_to_value(const TypedVector& vector);
std::vector<MapEntry> entries_to_map(const std::vector<MessageMapEntry>& entries);
void write_smallest_u64(uint64_t value, Buffer& out);
uint64_t read_smallest_u64(Reader& reader);

std::string key_ref_string(const KeyRef& key, const SessionState& state);
std::optional<std::string> key_ref_field_identity(const KeyRef& key, const SessionState& state);

std::vector<Value> message_fields(const Message& message);
Message rebuild_message_like(const Message& base, const std::vector<Value>& fields);
std::pair<std::vector<PatchOperation>, int> diff_message(const Message& prev, const Message& current);
bool supports_state_patch(const Message* base, const Message& current);
int encoded_size(const Message& message);

std::vector<Column> columns_from_map_values(const std::vector<Value>& values);
std::vector<std::vector<Value>> rows_from_values(const std::vector<Value>& values);
std::vector<Column> rows_to_columns(const std::vector<std::vector<Value>>& rows);
bool has_uniform_micro_batch_shape(const std::vector<Value>& values);

std::pair<VectorCodec, TypedVectorData> infer_column_codec_and_values(const std::vector<Value>& values);
TypedVectorData typed_data_i64(const std::vector<int64_t>& data);
TypedVectorData typed_data_u64(const std::vector<uint64_t>& data);
TypedVectorData typed_data_f64(const std::vector<double>& data);
TypedVectorData typed_data_bool(const std::vector<bool>& data);
TypedVectorData typed_data_string(const std::vector<std::string>& data);

VectorCodec select_integer_codec(const std::vector<int64_t>& values);
VectorCodec select_u64_codec(const std::vector<uint64_t>& values);
VectorCodec select_float_codec(const std::vector<double>& values);
VectorCodec select_string_codec(const std::vector<std::string>& values);

TemplateDescriptor template_descriptor_from_columns(uint64_t template_id,
                                                    const std::vector<Column>& columns);
std::pair<uint64_t, bool> find_template_id(const std::unordered_map<uint64_t, TemplateDescriptor>& templates,
                                           const std::vector<Column>& columns);
std::pair<std::vector<bool>, std::vector<Column>> diff_template_columns(const std::vector<Column>& previous,
                                                                        const std::vector<Column>& current);
std::vector<Column> merge_template_columns(const std::vector<Column>& previous,
                                           const std::vector<bool>& changed_mask,
                                           const std::vector<Column>& changed);

void apply_dictionary_references(SessionState& state, std::vector<Column>& columns);
int common_prefix_len(const std::string& a, const std::string& b);
bool should_register_shape(const std::vector<std::string>& keys, int observed_count);

std::vector<uint8_t> control_bitpack_encode_bytes(const std::vector<uint8_t>& input);
std::vector<uint8_t> control_bitpack_decode_bytes(const std::vector<uint8_t>& input);
std::vector<uint8_t> control_huffman_encode_bytes(const std::vector<uint8_t>& input);
std::vector<uint8_t> control_huffman_decode_bytes(const std::vector<uint8_t>& input);
std::vector<uint8_t> control_fse_encode_bytes(const std::vector<uint8_t>& input);
std::vector<uint8_t> control_fse_decode_bytes(const std::vector<uint8_t>& input);

}  // namespace twilic
