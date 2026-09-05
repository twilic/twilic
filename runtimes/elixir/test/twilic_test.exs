defmodule TwilicTest do
  use ExUnit.Case, async: true

  alias Twilic.Model

  defp sample_value do
    Model.new_map([
      Model.entry("id", Model.new_u64(1001)),
      Model.entry("name", Model.new_string("alice")),
      Model.entry("admin", Model.new_bool(false)),
      Model.entry(
        "scores",
        Model.new_array([
          Model.new_u64(12),
          Model.new_u64(15),
          Model.new_u64(18),
          Model.new_u64(21)
        ])
      )
    ])
  end

  test "v2 roundtrip dynamic value" do
    value = sample_value()
    encoded = Twilic.encode(value)
    decoded = Twilic.decode(encoded)
    assert Model.equal?(decoded, value)
  end

  test "codec roundtrip dynamic value" do
    value = sample_value()
    codec = Twilic.new_twilic_codec()
    encoded = Twilic.Protocol.TwilicCodec.encode_value(codec, value)
    decoded = Twilic.Protocol.TwilicCodec.decode_value(codec, encoded)
    assert Model.equal?(decoded, value)
  end

  test "session encoder encode_batch smoke" do
    enc = Twilic.new_session_encoder()
    value = sample_value()
    {_enc, bytes} = Twilic.Protocol.SessionEncoder.encode(enc, value)
    assert byte_size(bytes) > 0
    {_enc, batch} = Twilic.Protocol.SessionEncoder.encode_batch(enc, [value, value])
    assert byte_size(batch) > 0
  end
end
