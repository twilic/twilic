--- High-level encode/decode API.
local v2 = require("twilic.core.v2")
local protocol = require("twilic.core.protocol")
local session = require("twilic.core.session")

local M = {}

function M.encode(value)
  return v2.encode_v2(value)
end

function M.decode(bytes)
  return v2.decode_v2(bytes)
end

function M.encode_with_schema(schema, value)
  local enc = protocol.new_session_encoder(session.default_session_options())
  return enc:encode_with_schema(schema, value)
end

function M.encode_batch(values)
  local enc = protocol.new_session_encoder(session.default_session_options())
  return enc:encode_batch(values)
end

return M
