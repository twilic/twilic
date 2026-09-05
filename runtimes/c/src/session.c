#include "twilic/session.h"

#include <sstream>

namespace twilic {

SessionOptions default_session_options() { return SessionOptions{}; }

std::pair<uint64_t, bool> InternTable::get_id(const std::string& value) const {
  const auto it = by_value.find(value);
  if (it != by_value.end()) return {it->second, true};
  return {0, false};
}

std::pair<std::string, bool> InternTable::get_value(uint64_t ref_id) const {
  if (ref_id >= by_id.size()) return {"", false};
  return {by_id[static_cast<size_t>(ref_id)], true};
}

uint64_t InternTable::register_value(const std::string& value) {
  const auto existing = by_value.find(value);
  if (existing != by_value.end()) return existing->second;
  const uint64_t ref_id = by_id.size();
  by_id.push_back(value);
  by_value[value] = ref_id;
  return ref_id;
}

void InternTable::clear() {
  by_value.clear();
  by_id.clear();
}

std::string shape_key(const std::vector<std::string>& keys) {
  std::ostringstream oss;
  for (size_t i = 0; i < keys.size(); ++i) {
    if (i > 0) oss << '\0';
    oss << keys[i];
  }
  return oss.str();
}

std::pair<uint64_t, bool> ShapeTable::get_id(const std::vector<std::string>& keys) const {
  const auto sk = shape_key(keys);
  const auto it = by_keys.find(sk);
  if (it != by_keys.end()) return {it->second, true};
  return {0, false};
}

std::pair<std::vector<std::string>, bool> ShapeTable::get_keys(uint64_t ref_id) const {
  const auto it = by_id.find(ref_id);
  if (it != by_id.end()) return {it->second, true};
  return {{}, false};
}

uint64_t ShapeTable::register_keys(const std::vector<std::string>& keys) {
  const auto sk = shape_key(keys);
  const auto existing = by_keys.find(sk);
  if (existing != by_keys.end()) return existing->second;
  const uint64_t ref_id = next_id++;
  by_id[ref_id] = keys;
  by_keys[sk] = ref_id;
  return ref_id;
}

bool ShapeTable::register_with_id(uint64_t shape_id, const std::vector<std::string>& keys) {
  const auto sk = shape_key(keys);
  const auto existing = by_id.find(shape_id);
  if (existing != by_id.end()) return shape_key(existing->second) == sk;
  const auto existing_id = by_keys.find(sk);
  if (existing_id != by_keys.end() && existing_id->second != shape_id) return false;
  by_id[shape_id] = keys;
  by_keys[sk] = shape_id;
  if (shape_id + 1 > next_id) next_id = shape_id + 1;
  return true;
}

int ShapeTable::observe(const std::vector<std::string>& keys) {
  const auto sk = shape_key(keys);
  observations[sk] = observations[sk] + 1;
  return observations[sk];
}

void ShapeTable::clear() {
  by_keys.clear();
  by_id.clear();
  observations.clear();
  next_id = 0;
}

SessionState::SessionState(SessionOptions options) : options(std::move(options)) {}

SessionState new_session_state() { return SessionState{}; }

SessionState new_session_state_with_options(SessionOptions options) {
  return SessionState(std::move(options));
}

void reset_tables(SessionState& state) {
  state.key_table.clear();
  state.string_table.clear();
  state.shape_table.clear();
  state.encode_shape_observations.clear();
}

void reset_state(SessionState& state) {
  reset_tables(state);
  state.base_snapshots.clear();
  state.schemas.clear();
  state.templates.clear();
  state.template_columns.clear();
  state.dictionaries.clear();
  state.dictionary_profiles.clear();
  state.last_schema_id.reset();
  state.previous_message.reset();
  state.previous_message_size.reset();
  state.next_base_id = 0;
  state.next_template_id = 0;
  state.next_dictionary_id = 0;
}

void register_base_snapshot(SessionState& state, uint64_t base_id, const Message& message) {
  std::vector<BaseSnapshotEntry> filtered;
  filtered.reserve(state.base_snapshots.size() + 1);
  for (const auto& e : state.base_snapshots) {
    if (e.id != base_id) {
      BaseSnapshotEntry copy;
      copy.id = e.id;
      copy.message = e.message.clone();
      filtered.push_back(std::move(copy));
    }
  }
  filtered.push_back({base_id, message.clone()});
  while (static_cast<int>(filtered.size()) > state.options.max_base_snapshots) {
    filtered.erase(filtered.begin());
  }
  state.base_snapshots = std::move(filtered);
}

std::pair<Message, bool> get_base_snapshot(const SessionState& state, uint64_t base_id) {
  for (const auto& e : state.base_snapshots) {
    if (e.id == base_id) return {e.message.clone(), true};
  }
  return {Message{}, false};
}

uint64_t allocate_base_id(SessionState& state) { return state.next_base_id++; }

uint64_t allocate_template_id(SessionState& state) { return state.next_template_id++; }

uint64_t allocate_dictionary_id(SessionState& state) { return state.next_dictionary_id++; }

void reset_encode_shape_observation(SessionState& state, const std::vector<std::string>& keys) {
  state.encode_shape_observations.erase(shape_key(keys));
}

}  // namespace twilic
