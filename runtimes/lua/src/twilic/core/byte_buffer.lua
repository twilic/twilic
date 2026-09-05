--- Growable binary buffer (Python bytearray / PHP ByteBuffer equivalent).
local M = {}

function M.new()
  return { data = "" }
end

function M.append(buf, byte)
  buf.data = buf.data .. string.char(byte & 0xFF)
end

function M.append_bytes(buf, bytes)
  buf.data = buf.data .. bytes
end

function M.bytes(buf)
  return buf.data
end

function M.length(buf)
  return #buf.data
end

return M
