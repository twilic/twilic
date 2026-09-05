--- Twilic error types.
local M = {}

M.ERR_UNEXPECTED_EOF = 0
M.ERR_INVALID_KIND = 1
M.ERR_INVALID_TAG = 2
M.ERR_INVALID_DATA = 3
M.ERR_UTF8 = 4
M.ERR_UNKNOWN_REFERENCE = 5
M.ERR_STATELESS_RETRY_REQUIRED = 6

M.ErrUnexpectedEOF = M.ERR_UNEXPECTED_EOF
M.ErrInvalidKind = M.ERR_INVALID_KIND
M.ErrInvalidTag = M.ERR_INVALID_TAG
M.ErrInvalidData = M.ERR_INVALID_DATA
M.ErrUTF8 = M.ERR_UTF8
M.ErrUnknownReference = M.ERR_UNKNOWN_REFERENCE
M.ErrStatelessRetryRequired = M.ERR_STATELESS_RETRY_REQUIRED

local function format_message(err)
  local k = err.kind
  if k == M.ERR_UNEXPECTED_EOF then
    return "unexpected end of input"
  elseif k == M.ERR_INVALID_KIND then
    return string.format("invalid message kind: 0x%02x", err.byte or 0)
  elseif k == M.ERR_INVALID_TAG then
    return string.format("invalid value tag: 0x%02x", err.byte or 0)
  elseif k == M.ERR_INVALID_DATA then
    return "invalid data: " .. (err.msg or "")
  elseif k == M.ERR_UTF8 then
    return "utf8 decode error"
  elseif k == M.ERR_UNKNOWN_REFERENCE then
    return string.format("unknown reference: %s=%s", err.ref_kind or "", tostring(err.ref_id or 0))
  elseif k == M.ERR_STATELESS_RETRY_REQUIRED then
    return string.format(
      "stateless retry required for reference: %s=%s",
      err.ref_kind or "",
      tostring(err.ref_id or 0)
    )
  end
  return "twilic error"
end

function M.new_error(kind, opts)
  opts = opts or {}
  local err = {
    kind = kind,
    byte = opts.byte,
    msg = opts.msg,
    ref_kind = opts.ref_kind,
    ref_id = opts.ref_id,
  }
  return setmetatable(err, {
    __tostring = function()
      return format_message(err)
    end,
  })
end

function M.unexpected_eof()
  return M.new_error(M.ERR_UNEXPECTED_EOF)
end

function M.invalid_kind(b)
  return M.new_error(M.ERR_INVALID_KIND, { byte = b })
end

function M.invalid_tag(b)
  return M.new_error(M.ERR_INVALID_TAG, { byte = b })
end

function M.invalid_data(msg)
  return M.new_error(M.ERR_INVALID_DATA, { msg = msg })
end

function M.utf8_error()
  return M.new_error(M.ERR_UTF8)
end

function M.unknown_reference(kind, ref_id)
  return M.new_error(M.ERR_UNKNOWN_REFERENCE, { ref_kind = kind, ref_id = ref_id })
end

function M.stateless_retry_required(kind, ref_id)
  return M.new_error(M.ERR_STATELESS_RETRY_REQUIRED, { ref_kind = kind, ref_id = ref_id })
end

function M.is_stateless_retry(err)
  return type(err) == "table" and err.kind == M.ERR_STATELESS_RETRY_REQUIRED
end

function M.is_unknown_reference(err)
  return type(err) == "table" and err.kind == M.ERR_UNKNOWN_REFERENCE
end

function M.raise(err)
  error(err, 0)
end

return M
