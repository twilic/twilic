--- Twilic Lua SDK entry point.
local errors = require("twilic.core.errors")
local model = require("twilic.core.model")
local api = require("twilic.core.api")
local session = require("twilic.core.session")
local protocol = require("twilic.core.protocol")

local M = {}

-- Re-export model constants and constructors
M.MESSAGE_KIND_SCALAR = model.MESSAGE_KIND_SCALAR
M.MESSAGE_KIND_ARRAY = model.MESSAGE_KIND_ARRAY
M.MESSAGE_KIND_MAP = model.MESSAGE_KIND_MAP
M.MESSAGE_KIND_SHAPED_OBJECT = model.MESSAGE_KIND_SHAPED_OBJECT
M.MESSAGE_KIND_SCHEMA_OBJECT = model.MESSAGE_KIND_SCHEMA_OBJECT
M.MESSAGE_KIND_TYPED_VECTOR = model.MESSAGE_KIND_TYPED_VECTOR
M.MESSAGE_KIND_ROW_BATCH = model.MESSAGE_KIND_ROW_BATCH
M.MESSAGE_KIND_COLUMN_BATCH = model.MESSAGE_KIND_COLUMN_BATCH
M.MESSAGE_KIND_CONTROL = model.MESSAGE_KIND_CONTROL
M.MESSAGE_KIND_EXT = model.MESSAGE_KIND_EXT
M.MESSAGE_KIND_STATE_PATCH = model.MESSAGE_KIND_STATE_PATCH
M.MESSAGE_KIND_TEMPLATE_BATCH = model.MESSAGE_KIND_TEMPLATE_BATCH
M.MESSAGE_KIND_CONTROL_STREAM = model.MESSAGE_KIND_CONTROL_STREAM
M.MESSAGE_KIND_BASE_SNAPSHOT = model.MESSAGE_KIND_BASE_SNAPSHOT

M.VALUE_NULL = model.VALUE_NULL
M.VALUE_BOOL = model.VALUE_BOOL
M.VALUE_I64 = model.VALUE_I64
M.VALUE_U64 = model.VALUE_U64
M.VALUE_F64 = model.VALUE_F64
M.VALUE_STRING = model.VALUE_STRING
M.VALUE_BINARY = model.VALUE_BINARY
M.VALUE_ARRAY = model.VALUE_ARRAY
M.VALUE_MAP = model.VALUE_MAP

M.UNKNOWN_REFERENCE_POLICY_FAIL_FAST = session.UNKNOWN_REFERENCE_POLICY_FAIL_FAST
M.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY = session.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY
M.DICTIONARY_FALLBACK_FAIL_FAST = session.DICTIONARY_FALLBACK_FAIL_FAST
M.DICTIONARY_FALLBACK_STATELESS_RETRY = session.DICTIONARY_FALLBACK_STATELESS_RETRY

M.ERR_UNEXPECTED_EOF = errors.ERR_UNEXPECTED_EOF
M.ERR_INVALID_KIND = errors.ERR_INVALID_KIND
M.ERR_INVALID_TAG = errors.ERR_INVALID_TAG
M.ERR_INVALID_DATA = errors.ERR_INVALID_DATA
M.ERR_UTF8 = errors.ERR_UTF8
M.ERR_UNKNOWN_REFERENCE = errors.ERR_UNKNOWN_REFERENCE
M.ERR_STATELESS_RETRY_REQUIRED = errors.ERR_STATELESS_RETRY_REQUIRED

function M.encode(value)
  return api.encode(value)
end

function M.decode(bytes)
  return api.decode(bytes)
end

function M.encode_with_schema(schema, value)
  return api.encode_with_schema(schema, value)
end

function M.encode_batch(values)
  return api.encode_batch(values)
end

function M.null()
  return model.null_value()
end

function M.bool(b)
  return model.bool_value(b)
end

function M.i64(n)
  return model.i64_value(n)
end

function M.u64(n)
  return model.u64_value(n)
end

function M.f64(n)
  return model.f64_value(n)
end

function M.string(s)
  return model.string_value(s)
end

function M.binary(b)
  return model.binary_value(b)
end

function M.array(items)
  return model.array_value(items)
end

function M.map(entries)
  return model.map_value(entries)
end

function M.entry(key, value)
  return model.entry(key, value)
end

function M.equal(a, b)
  return model.equal(a, b)
end

function M.default_session_options()
  return session.default_session_options()
end

function M.new_twilic_codec()
  return protocol.new_twilic_codec()
end

function M.twilic_codec_with_options(options)
  return protocol.twilic_codec_with_options(options)
end

function M.new_session_encoder(options)
  return protocol.new_session_encoder(options)
end

function M.reset_encode_shape_observation(codec, keys)
  return protocol.reset_encode_shape_observation(codec, keys)
end

return M
