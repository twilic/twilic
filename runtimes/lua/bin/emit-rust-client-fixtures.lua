#!/usr/bin/env lua
package.path = "src/?.lua;src/?/init.lua;" .. package.path

local interop = require("twilic.core.interop_fixtures")

local ok, err = pcall(function()
  io.write(interop.emit_interop_fixtures({ lines = {} }))
end)
if not ok then
  io.stderr:write("emit fixtures: " .. tostring(err) .. "\n")
  os.exit(1)
end
