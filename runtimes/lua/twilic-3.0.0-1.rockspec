rockspec_format = "3.0"

package = "twilic"
version = "3.0.0-1"

source = {
  url = "https://github.com/twilic/twilic-lua/archive/v3.0.0.tar.gz",
  tag = "v3.0.0",
}

description = {
  summary = "Lua 5.4 implementation of the Twilic binary wire format (v2 protocol).",
  detailed = [[
Native Lua SDK for Twilic: dynamic encode/decode, schema-aware session encoding,
batch and micro-batch messages, and Rust interop fixtures.
  ]],
  homepage = "https://github.com/twilic/twilic-lua",
  license = "MIT",
}

dependencies = {
  "lua >= 5.4, < 5.5",
}

build = {
  type = "builtin",
  modules = {
    ["twilic"] = "src/twilic/init.lua",
    ["twilic.core.api"] = "src/twilic/core/api.lua",
    ["twilic.core.byte_buffer"] = "src/twilic/core/byte_buffer.lua",
    ["twilic.core.codec"] = "src/twilic/core/codec.lua",
    ["twilic.core.dictionary"] = "src/twilic/core/dictionary.lua",
    ["twilic.core.errors"] = "src/twilic/core/errors.lua",
    ["twilic.core.interop_fixtures"] = "src/twilic/core/interop_fixtures.lua",
    ["twilic.core.model"] = "src/twilic/core/model.lua",
    ["twilic.core.protocol"] = "src/twilic/core/protocol.lua",
    ["twilic.core.protocol_helpers"] = "src/twilic/core/protocol_helpers.lua",
    ["twilic.core.session"] = "src/twilic/core/session.lua",
    ["twilic.core.v2"] = "src/twilic/core/v2.lua",
    ["twilic.core.wire"] = "src/twilic/core/wire.lua",
  },
}

test_dependencies = {
  "busted >= 2.0",
}

test = {
  type = "command",
  command = "busted",
  flags = { "-v", "spec" },
}
