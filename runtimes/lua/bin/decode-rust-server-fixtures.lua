#!/usr/bin/env lua
package.path = "src/?.lua;src/?/init.lua;" .. package.path

local interop = require("twilic.core.interop_fixtures")

local ok, err = pcall(function()
  interop.decode_rust_server_frames(io.stdin:read("*a"))
end)
if not ok then
  io.stderr:write("decode fixtures: " .. tostring(err) .. "\n")
  os.exit(1)
end
