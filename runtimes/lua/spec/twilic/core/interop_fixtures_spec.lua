local tw = require("twilic")
local interop = require("twilic.core.interop_fixtures")
local protocol = require("twilic.core.protocol")
local H = require("spec.test_helpers")

describe("interop fixtures", function()
  it("codec encode decode roundtrip", function()
    local buf = interop.emit_interop_fixtures({ lines = {} })
    local frames = interop.parse_interop_frames(buf)
    local codec = tw.new_twilic_codec()
    for i = 1, #frames do
      local frame = frames[i]
      if frame.stream == "codec" then
        interop.assert_interop_codec_decode(codec, frame.label, frame.bytes)
        if interop.interop_expect_codec_value_p(frame.label) then
          local iso = interop.replay_codec_state(frames, frame.label)
          local got = iso:decode_value(frame.bytes)
          local reencoded = iso:encode_value(got)
          local roundtrip = iso:decode_value(reencoded)
          assert.is_true(tw.equal(roundtrip, got), frame.label .. ": roundtrip value mismatch")
        end
      end
    end
  end)

  it("session encode decode roundtrip", function()
    local buf = interop.emit_interop_fixtures({ lines = {} })
    local frames = interop.parse_interop_frames(buf)
    local codec = tw.new_twilic_codec()
    for i = 1, #frames do
      local frame = frames[i]
      if frame.stream == "session" then
        interop.assert_interop_session_decode(codec, frame.label, frame.bytes)
      end
    end
  end)

  it("decode rust server frames", function()
    local root = H.interop_module_root()
    local ok_rust, skip_reason = H.interop_require_twilic_rust(root)
    if not ok_rust then
      pending(skip_reason)
    end
    local manifest = root .. "/scripts/rust-server-fixtures/Cargo.toml"
    local f = io.open(manifest, "r")
    if not f then
      pending("rust fixtures not available")
      return
    end
    f:close()
    local handle = io.popen(
      string.format('cargo run --quiet --manifest-path "%s" 2>/dev/null', manifest)
    )
    local rust_out = handle:read("*a")
    handle:close()
    local frames = interop.parse_interop_frames(rust_out)
    local codec_stream = tw.new_twilic_codec()
    local session_stream = tw.new_twilic_codec()
    for i = 1, #frames do
      local frame = frames[i]
      local decoder = frame.stream == "session" and session_stream or codec_stream
      if frame.stream == "codec" then
        interop.assert_interop_codec_decode(decoder, frame.label, frame.bytes)
      else
        interop.assert_interop_session_decode(decoder, frame.label, frame.bytes)
      end
    end
  end)

  it("rust decodes lua frames with same values", function()
    local root = H.interop_module_root()
    local ok_rust, skip_reason = H.interop_require_twilic_rust(root)
    if not ok_rust then
      pending(skip_reason)
    end
    local rust_check = root .. "/scripts/rust-client-check/Cargo.toml"
    local f = io.open(rust_check, "r")
    if not f then
      pending("rust client check not available")
      return
    end
    f:close()
    local lua_buf = interop.emit_interop_fixtures({ lines = {} })
    local tmp = os.tmpname()
    local wf = assert(io.open(tmp, "w"))
    wf:write(lua_buf)
    wf:close()
    local cmd = string.format(
      'cargo run --quiet --manifest-path "%s" < "%s" 2>/dev/null',
      rust_check,
      tmp
    )
    local rh = assert(io.popen(cmd))
    local result = rh:read("*a")
    rh:close()
    os.remove(tmp)
    assert.is_truthy(result:find("value checks passed for", 1, true))
  end)
end)
