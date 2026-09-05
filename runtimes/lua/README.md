# Twilic (Lua)

Lua 5.4 implementation of the Twilic wire format and session-aware encoder/decoder.

This module's default `Twilic.encode` / `Twilic.decode` API targets Twilic v2 (v3 support pending). Stateful protocol features use `new_twilic_codec()` and `new_session_encoder()`.

## Project layout

```text
twilic-lua/
  src/twilic/init.lua       # public API
  src/twilic/core/          # wire, model, codec, session, protocol, v2
  spec/                     # busted tests (ported from twilic-ruby)
  bin/                      # Rust interop CLI scripts
  scripts/                  # interop smoke checks
```

## Requirements

- Lua 5.4
- [LuaRocks](https://luarocks.org/) (for `busted` in development)

## Install (LuaRocks)

```bash
luarocks install twilic-3.0.0-1.rockspec
```

Or use the tree directly by setting `LUA_PATH`:

```bash
export LUA_PATH="$(pwd)/src/?.lua;$(pwd)/src/?/init.lua;;"
```

## Quick start

```lua
local twilic = require("twilic")

local value = twilic.map({
  id = twilic.u64(1001),
  name = twilic.string("alice"),
})

local bytes = twilic.encode(value)
local decoded = twilic.decode(bytes)
print(twilic.equal(decoded, value)) -- true
```

## Session encoder

```lua
local twilic = require("twilic")

local enc = twilic.new_session_encoder()
local value = twilic.map({
  id = twilic.u64(1),
  role = twilic.string("admin"),
})
local bytes = enc:encode(value)
```

## Development

```bash
luarocks install busted
export LUA_PATH="src/?.lua;src/?/init.lua;;"
busted spec
```

Rust interop (requires `cargo` and the sibling `../rust` runtime):

```bash
bash scripts/check-interop.sh
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
