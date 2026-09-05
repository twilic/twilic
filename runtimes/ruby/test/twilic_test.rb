# frozen_string_literal: true

require "test_helper"

class TwilicTest < Minitest::Test
  def test_v2_roundtrip_dynamic_value
    value = Twilic.map(
      "id" => Twilic.u64(1001),
      "name" => Twilic.string("alice"),
      "admin" => Twilic.bool(false),
      "scores" => Twilic.array([
        Twilic.u64(12), Twilic.u64(15), Twilic.u64(18), Twilic.u64(21)
      ])
    )
    encoded = Twilic.encode(value)
    decoded = Twilic.decode(encoded)
    assert Twilic.equal(value, decoded)
  end

  def test_codec_roundtrip_dynamic_value
    value = Twilic.map(
      "id" => Twilic.u64(1001),
      "name" => Twilic.string("alice"),
      "admin" => Twilic.bool(false),
      "scores" => Twilic.array([
        Twilic.u64(12), Twilic.u64(15), Twilic.u64(18), Twilic.u64(21)
      ])
    )
    codec = Twilic.new_twilic_codec
    encoded = codec.encode_value(value)
    decoded = codec.decode_value(encoded)
    assert Twilic.equal(value, decoded)
  end

  def test_session_patch_and_micro_batch
    enc = Twilic.new_session_encoder
    base = Twilic.map("id" => Twilic.u64(1), "name" => Twilic.string("alice"))
    nxt = Twilic.map("id" => Twilic.u64(1), "name" => Twilic.string("alicia"))
    refute_empty enc.encode(base)
    refute_empty enc.encode_patch(nxt)
    refute_empty enc.encode_micro_batch([base, nxt, base, nxt])
  end

  def test_unknown_reference_policy_supports_stateless_retry
    opts = Twilic.default_session_options
    opts = Twilic::SessionOptions.new(
      max_base_snapshots: opts.max_base_snapshots,
      enable_state_patch: opts.enable_state_patch,
      enable_template_batch: opts.enable_template_batch,
      enable_trained_dictionary: opts.enable_trained_dictionary,
      unknown_reference_policy: Twilic::UnknownReferencePolicy::STATELESS_RETRY
    )
    codec = Twilic.twilic_codec_with_options(opts)
    patch = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::STATE_PATCH,
      state_patch: Twilic::StatePatchMessage.new(
        base_ref: Twilic::BaseRef.id_ref(777),
        operations: [],
        literals: []
      )
    )
    raw = codec.encode_message(patch)
    decode_codec = Twilic.twilic_codec_with_options(opts)
    err = assert_raises(Twilic::TwilicError) { decode_codec.decode_message(raw) }
    assert_equal Twilic::ERR_STATELESS_RETRY_REQUIRED, err.kind
    assert_equal "base_id", err.ref_kind
    assert_equal 777, err.ref_id
  end
end
