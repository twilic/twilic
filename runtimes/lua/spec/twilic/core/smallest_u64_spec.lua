local tw = require("twilic")

describe("session smallest u64 widths", function()
  local fixtures = {
    { 65535, string.char(0, 4, 2, 255, 255) },
    { 65536, string.char(0, 4, 4, 0, 0, 1, 0) },
    { 100000, string.char(0, 4, 4, 160, 134, 1, 0) },
    { 0xFFFFFFFF, string.char(0, 4, 4, 255, 255, 255, 255) },
    { 0x100000000, string.char(0, 4, 8, 0, 0, 0, 0, 1, 0, 0, 0) },
  }

  for _, fixture in ipairs(fixtures) do
    local value, bytes = fixture[1], fixture[2]
    it("encodes canonical width for " .. value, function()
      local encoded = tw.new_twilic_codec():encode_value(tw.u64(value))
      assert.are.equal(bytes, encoded)
    end)
    it("decodes canonical width for " .. value, function()
      local decoded = tw.new_twilic_codec():decode_value(bytes)
      assert.is_true(tw.equal(tw.u64(value), decoded))
    end)
  end

  it("rejects a truncated four-byte value", function()
    assert.has_error(function()
      tw.new_twilic_codec():decode_value(string.char(0, 4, 4, 0, 0, 1))
    end)
  end)
end)
