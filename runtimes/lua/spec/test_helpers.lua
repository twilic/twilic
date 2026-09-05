local tw = require("twilic")
local model = require("twilic.core.model")
local errors = require("twilic.core.errors")

local M = {}

M.TAG_STRING = 6

function M.require_twilic_error_kind(err, kind)
  assert.is_table(err)
  assert.are.equal(kind, err.kind)
  return err
end

function M.equal_key_ref(a, b)
  return a.is_id == b.is_id and a.id == b.id and a.literal == b.literal
end

function M.equal_message(a, b)
  if a.kind ~= b.kind then
    return false
  end
  if a.kind == model.MESSAGE_KIND_SCALAR then
    return tw.equal(a.scalar, b.scalar)
  elseif a.kind == model.MESSAGE_KIND_ARRAY then
    if #(a.array or {}) ~= #(b.array or {}) then
      return false
    end
    for i = 1, #(a.array or {}) do
      if not tw.equal(a.array[i], b.array[i]) then
        return false
      end
    end
    return true
  elseif a.kind == model.MESSAGE_KIND_MAP then
    if #(a.map or {}) ~= #(b.map or {}) then
      return false
    end
    for i = 1, #(a.map or {}) do
      if not M.equal_key_ref(a.map[i].key, b.map[i].key) then
        return false
      end
      if not tw.equal(a.map[i].value, b.map[i].value) then
        return false
      end
    end
    return true
  elseif a.kind == model.MESSAGE_KIND_CONTROL_STREAM then
  local cs, bs = a.control_stream, b.control_stream
    return cs.codec == bs.codec and cs.payload == bs.payload
  end
  return model.clone_message(a).kind == model.clone_message(b).kind
end

function M.message_map_entry(key, value)
  return { key = model.key_ref_literal(key), value = value }
end

function M.scalar_string_mode(bytes)
  assert.is_true(#bytes >= 3, "expected at least 3 bytes")
  assert.are.equal(model.MESSAGE_KIND_SCALAR, string.byte(bytes, 1))
  assert.are.equal(M.TAG_STRING, string.byte(bytes, 2))
  return string.byte(bytes, 3)
end

function M.schema_field(opts)
  opts = opts or {}
  return {
    number = opts.number,
    name = opts.name,
    logical_type = opts.logical_type,
    required = opts.required,
    default_value = opts.default_value,
    min = opts.min,
    max = opts.max,
    enum_values = opts.enum_values or {},
  }
end

function M.sample_schema()
  return {
    schema_id = 41,
    name = "User",
    fields = {
      M.schema_field({
        number = 1,
        name = "id",
        logical_type = "u64",
        required = true,
        min = 1000,
        max = 1100,
      }),
      M.schema_field({
        number = 2,
        name = "name",
        logical_type = "string",
        required = true,
      }),
      M.schema_field({
        number = 3,
        name = "score",
        logical_type = "i64",
        required = false,
        min = 0,
        max = 100,
      }),
    },
  }
end

function M.control_message(opts)
  return {
    opcode = opts.opcode,
    register_keys = opts.register_keys or {},
    register_shape = opts.register_shape,
    register_strings = opts.register_strings or {},
    promote_string_field_to_enum = opts.promote,
    reset_tables = opts.reset_tables or false,
    reset_state = opts.reset_state or false,
  }
end

function M.encoded_control_stream_len(codec_enum, payload)
  local codec = tw.new_twilic_codec()
  local msg = model.message({
    kind = model.MESSAGE_KIND_CONTROL_STREAM,
    control_stream = { codec = codec_enum, payload = payload },
  })
  return #codec:encode_message(msg)
end

function M.empty_typed_vector_data(kind)
  return model.typed_vector_data(kind)
end

function M.assert_raises_twilic(fn, kind)
  local ok, err = pcall(fn)
  assert.is_false(ok)
  M.require_twilic_error_kind(err, kind)
  return err
end

function M.interop_module_root()
  local path = debug.getinfo(1, "S").source:sub(2)
  local dir = path:match("(.*/)")
  while dir and dir ~= "" do
    local f = io.open(dir .. "twilic-3.0.0-1.rockspec", "r")
    if f then
      f:close()
      return dir:sub(1, -2)
    end
    dir = dir:match("(.*/)[^/]+/$")
  end
  return "."
end

function M.skip_if_missing(cmd, reason)
  local h = io.popen("command -v " .. cmd .. " 2>/dev/null")
  local found = h and h:read("*a") or ""
  if h then
    h:close()
  end
  if found == "" then
    return true, reason or ("missing " .. cmd)
  end
  return false
end

function M.interop_require_twilic_rust(root)
  local skip, reason = M.skip_if_missing("cargo", "cargo not found in PATH")
  if skip then
    return false, reason
  end
  local env = os.getenv("TWILIC_RUST_ROOT")
  local candidates = {}
  if env and env ~= "" then
    candidates[#candidates + 1] = env
  end
  candidates[#candidates + 1] = root .. "/../rust"
  for _, c in ipairs(candidates) do
    local f = io.open(c .. "/Cargo.toml", "r")
    if f then
      f:close()
      return true
    end
  end
  return false, "Rust runtime not found (expected ../rust or TWILIC_RUST_ROOT)"
end

return M
