package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Make busted/luassert assertions available in helper modules.
assert = require("luassert")

require("spec.test_helpers")
