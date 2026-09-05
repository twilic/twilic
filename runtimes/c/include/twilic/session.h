#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "twilic/model.h"

namespace twilic {

enum class UnknownReferencePolicy { FailFast, StatelessRetry };
enum class DictionaryFallback { FailFast, StatelessRetry };

struct DictionaryProfile {
  uint64_t version = 0;
  uint64_t hash = 0;
  uint64_t expires_at = 0;
  DictionaryFallback fallback = DictionaryFallback::FailFast;
};

struct SessionOptions {
  int max_base_snapshots = 8;
  bool enable_state_patch = true;
  bool enable_template_batch = true;
  bool enable_trained_dictionary = true;
  UnknownReferencePolicy unknown_reference_policy = UnknownReferencePolicy::FailFast;
};

SessionOptions default_session_options();

class InternTable {
 public:
  std::pair<uint64_t, bool> get_id(const std::string& value) const;
  std::pair<std::string, bool> get_value(uint64_t ref_id) const;
  uint64_t register_value(const std::string& value);
  void clear();

  std::unordered_map<std::string, uint64_t> by_value;
  std::vector<std::string> by_id;
};

std::string shape_key(const std::vector<std::string>& keys);

class ShapeTable {
 public:
  std::pair<uint64_t, bool> get_id(const std::vector<std::string>& keys) const;
  std::pair<std::vector<std::string>, bool> get_keys(uint64_t ref_id) const;
  uint64_t register_keys(const std::vector<std::string>& keys);
  bool register_with_id(uint64_t shape_id, const std::vector<std::string>& keys);
  int observe(const std::vector<std::string>& keys);
  void clear();

  std::unordered_map<std::string, uint64_t> by_keys;
  std::unordered_map<uint64_t, std::vector<std::string>> by_id;
  std::unordered_map<std::string, int> observations;
  uint64_t next_id = 0;
};

struct BaseSnapshotEntry {
  uint64_t id = 0;
  Message message;
};

struct SessionState {
  explicit SessionState(SessionOptions options = default_session_options());
  SessionOptions options;
  InternTable key_table;
  InternTable string_table;
  ShapeTable shape_table;
  std::unordered_map<std::string, int> encode_shape_observations;
  std::vector<BaseSnapshotEntry> base_snapshots;
  std::unordered_map<uint64_t, Schema> schemas;
  std::unordered_map<uint64_t, TemplateDescriptor> templates;
  std::unordered_map<uint64_t, std::vector<Column>> template_columns;
  std::unordered_map<std::string, std::vector<std::string>> field_enums;
  std::unordered_map<uint64_t, std::vector<uint8_t>> dictionaries;
  std::unordered_map<uint64_t, DictionaryProfile> dictionary_profiles;
  std::optional<uint64_t> last_schema_id;
  std::optional<Message> previous_message;
  std::optional<size_t> previous_message_size;
  uint64_t next_base_id = 0;
  uint64_t next_template_id = 0;
  uint64_t next_dictionary_id = 0;
};

void register_base_snapshot(SessionState& state, uint64_t base_id, const Message& message);
std::pair<Message, bool> get_base_snapshot(const SessionState& state, uint64_t base_id);
uint64_t allocate_base_id(SessionState& state);
uint64_t allocate_template_id(SessionState& state);
uint64_t allocate_dictionary_id(SessionState& state);
void reset_encode_shape_observation(SessionState& state, const std::vector<std::string>& keys);

SessionState new_session_state();
SessionState new_session_state_with_options(SessionOptions options);
void reset_tables(SessionState& state);
void reset_state(SessionState& state);

}  // namespace twilic
