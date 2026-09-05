--- Session state and intern tables (mutable, PHP/Ruby compatible).
local model = require("twilic.core.model")

local M = {}

M.UNKNOWN_REFERENCE_POLICY_FAIL_FAST = 0
M.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY = 1

M.DICTIONARY_FALLBACK_FAIL_FAST = 0
M.DICTIONARY_FALLBACK_STATELESS_RETRY = 1

function M.dictionary_fallback_from_byte(b)
  if b == 0 then
    return M.DICTIONARY_FALLBACK_FAIL_FAST, true
  end
  if b == 1 then
    return M.DICTIONARY_FALLBACK_STATELESS_RETRY, true
  end
  return M.DICTIONARY_FALLBACK_FAIL_FAST, false
end

function M.default_session_options()
  return {
    max_base_snapshots = 8,
    enable_state_patch = true,
    enable_template_batch = true,
    enable_trained_dictionary = true,
    unknown_reference_policy = M.UNKNOWN_REFERENCE_POLICY_FAIL_FAST,
  }
end

function M.new_intern_table()
  return { by_value = {}, by_id = {} }
end

function M.intern_get_id(table, value)
  local id = table.by_value[value]
  if id then
    return id, true
  end
  return 0, false
end

function M.intern_get_value(table, ref_id)
  if ref_id >= #table.by_id then
    return "", false
  end
  return table.by_id[ref_id + 1], true
end

function M.intern_register(table, value)
  local id = table.by_value[value]
  if id then
    return id
  end
  id = #table.by_id
  table.by_id[id + 1] = value
  table.by_value[value] = id
  return id
end

function M.intern_clear(table)
  table.by_value = {}
  table.by_id = {}
end

function M.shape_key(keys)
  return table.concat(keys, "\0")
end

function M.new_shape_table()
  return { by_keys = {}, by_id = {}, observations = {}, next_id = 0 }
end

function M.shape_get_id(shape_table, keys)
  local sk = M.shape_key(keys)
  local id = shape_table.by_keys[sk]
  if id then
    return id, true
  end
  return 0, false
end

function M.shape_get_keys(shape_table, ref_id)
  local keys = shape_table.by_id[ref_id]
  if keys then
    local copy = {}
    for i = 1, #keys do
      copy[i] = keys[i]
    end
    return copy, true
  end
  return nil, false
end

function M.shape_register(shape_table, keys)
  local sk = M.shape_key(keys)
  local id = shape_table.by_keys[sk]
  if id then
    return id
  end
  id = shape_table.next_id
  shape_table.next_id = id + 1
  local keys_copy = {}
  for i = 1, #keys do
    keys_copy[i] = keys[i]
  end
  shape_table.by_id[id] = keys_copy
  shape_table.by_keys[sk] = id
  return id
end

function M.shape_register_with_id(shape_table, shape_id, keys)
  local sk = M.shape_key(keys)
  if shape_table.by_id[shape_id] then
    return M.shape_key(shape_table.by_id[shape_id]) == sk
  end
  local existing = shape_table.by_keys[sk]
  if existing and existing ~= shape_id then
    return false
  end
  local keys_copy = {}
  for i = 1, #keys do
    keys_copy[i] = keys[i]
  end
  shape_table.by_id[shape_id] = keys_copy
  shape_table.by_keys[sk] = shape_id
  if shape_id + 1 > shape_table.next_id then
    shape_table.next_id = shape_id + 1
  end
  return true
end

function M.shape_observe(shape_table, keys)
  local sk = M.shape_key(keys)
  shape_table.observations[sk] = (shape_table.observations[sk] or 0) + 1
  return shape_table.observations[sk]
end

function M.shape_clear(shape_table)
  shape_table.by_keys = {}
  shape_table.by_id = {}
  shape_table.observations = {}
  shape_table.next_id = 0
end

function M.new_session_state(options)
  options = options or M.default_session_options()
  return {
    options = options,
    key_table = M.new_intern_table(),
    string_table = M.new_intern_table(),
    shape_table = M.new_shape_table(),
    encode_shape_observations = {},
    base_snapshots = {},
    templates = {},
    template_columns = {},
    field_enums = {},
    dictionaries = {},
    dictionary_profiles = {},
    schemas = {},
    last_schema_id = nil,
    previous_message = nil,
    previous_message_size = nil,
    next_base_id = 0,
    next_template_id = 0,
    next_dictionary_id = 0,
  }
end

function M.register_base_snapshot(state, base_id, message)
  local filtered = {}
  for _, e in ipairs(state.base_snapshots) do
    if e.id ~= base_id then
      filtered[#filtered + 1] = e
    end
  end
  filtered[#filtered + 1] = { id = base_id, message = model.clone_message(message) }
  while #filtered > state.options.max_base_snapshots do
    table.remove(filtered, 1)
  end
  state.base_snapshots = filtered
end

function M.allocate_base_id(state)
  local ref_id = state.next_base_id
  state.next_base_id = state.next_base_id + 1
  return ref_id
end

function M.allocate_template_id(state)
  local ref_id = state.next_template_id
  state.next_template_id = state.next_template_id + 1
  return ref_id
end

function M.allocate_dictionary_id(state)
  local ref_id = state.next_dictionary_id
  state.next_dictionary_id = state.next_dictionary_id + 1
  return ref_id
end

function M.get_base_snapshot(state, base_id)
  for _, entry in ipairs(state.base_snapshots) do
    if entry.id == base_id then
      return model.clone_message(entry.message), true
    end
  end
  return nil, false
end

function M.reset_tables(state)
  M.intern_clear(state.key_table)
  M.intern_clear(state.string_table)
  M.shape_clear(state.shape_table)
  state.encode_shape_observations = {}
  state.field_enums = {}
end

function M.reset_state(state)
  M.reset_tables(state)
  state.base_snapshots = {}
  state.templates = {}
  state.template_columns = {}
  state.dictionaries = {}
  state.dictionary_profiles = {}
  state.schemas = {}
  state.last_schema_id = nil
  state.previous_message = nil
  state.previous_message_size = nil
  state.next_base_id = 0
  state.next_template_id = 0
  state.next_dictionary_id = 0
end

return M
