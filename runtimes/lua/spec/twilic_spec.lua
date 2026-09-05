local tw = require("twilic")
local model = require("twilic.core.model")
local session = require("twilic.core.session")
local H = require("spec.test_helpers")

describe("twilic", function()
  it("v2 roundtrip dynamic value", function()
    local value = tw.map({
      id = tw.u64(1001),
      name = tw.string("alice"),
      admin = tw.bool(false),
      scores = tw.array({
        tw.u64(12),
        tw.u64(15),
        tw.u64(18),
        tw.u64(21),
      }),
    })
    local encoded = tw.encode(value)
    local decoded = tw.decode(encoded)
    assert.is_true(tw.equal(value, decoded))
  end)

  it("codec roundtrip dynamic value", function()
    local value = tw.map({
      id = tw.u64(1001),
      name = tw.string("alice"),
      admin = tw.bool(false),
      scores = tw.array({
        tw.u64(12),
        tw.u64(15),
        tw.u64(18),
        tw.u64(21),
      }),
    })
    local codec = tw.new_twilic_codec()
    local encoded = codec:encode_value(value)
    local decoded = codec:decode_value(encoded)
    assert.is_true(tw.equal(value, decoded))
  end)

  it("session patch and micro batch", function()
    local enc = tw.new_session_encoder()
    local base = tw.map({ id = tw.u64(1), name = tw.string("alice") })
    local nxt = tw.map({ id = tw.u64(1), name = tw.string("alicia") })
    assert.is_true(#enc:encode(base) > 0)
    assert.is_true(#enc:encode_patch(nxt) > 0)
    assert.is_true(#enc:encode_micro_batch({ base, nxt, base, nxt }) > 0)
  end)

  it("unknown reference policy supports stateless retry", function()
    local opts = tw.default_session_options()
    opts.unknown_reference_policy = session.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY
    local codec = tw.twilic_codec_with_options(opts)
    local patch = model.message({
      kind = model.MESSAGE_KIND_STATE_PATCH,
      state_patch = {
        base_ref = model.base_ref_id(777),
        operations = {},
        literals = {},
      },
    })
    local raw = codec:encode_message(patch)
    local decode_codec = tw.twilic_codec_with_options(opts)
    local err = H.assert_raises_twilic(function()
      decode_codec:decode_message(raw)
    end, tw.ERR_STATELESS_RETRY_REQUIRED)
    assert.are.equal("base_id", err.ref_kind)
    assert.are.equal(777, err.ref_id)
  end)
end)
