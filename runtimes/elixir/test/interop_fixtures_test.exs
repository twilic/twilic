defmodule Twilic.InteropFixturesTest do
  use ExUnit.Case, async: false

  alias Twilic.InteropFixtures
  alias Twilic.Model
  alias Twilic.Protocol.TwilicCodec

  @tag :interop
  test "codec encode decode roundtrip" do
    frames = InteropFixtures.parse_interop_frames(InteropFixtures.emit_interop_fixtures())
    codec = TwilicCodec.new()

    for %InteropFixtures.Frame{stream: "codec", label: label, bytes: bytes} <- frames do
      InteropFixtures.assert_interop_codec_decode(codec, label, bytes)

      if expects_codec_value?(label) do
        iso = InteropFixtures.replay_codec_state(frames, label)
        got = TwilicCodec.decode_value(iso, bytes)
        reencoded = TwilicCodec.encode_value(iso, got)
        roundtrip = TwilicCodec.decode_value(iso, reencoded)
        assert Model.equal?(roundtrip, got), "#{label}: roundtrip value mismatch"
      end
    end
  end

  @tag :interop
  test "session encode decode roundtrip" do
    frames = InteropFixtures.parse_interop_frames(InteropFixtures.emit_interop_fixtures())
    codec = TwilicCodec.new()
    session_count = Enum.count(frames, &(&1.stream == "session"))
    assert session_count > 0

    for %InteropFixtures.Frame{stream: "session", label: label, bytes: bytes} <- frames do
      InteropFixtures.assert_interop_session_decode(codec, label, bytes)
    end
  end

  @tag :interop
  @tag :rust
  test "decode rust server frames" do
    rust_root = rust_root()

    if is_nil(rust_root) do
      :ok
    else
      manifest = Path.join([rust_root, "scripts", "rust-server-fixtures", "Cargo.toml"])

      if not File.exists?(manifest) do
        :ok
      else
        {output, 0} =
          System.cmd("cargo", ["run", "--quiet", "--manifest-path", manifest],
            cd: Path.dirname(manifest),
            stderr_to_stdout: true
          )

        frames = InteropFixtures.parse_interop_frames(output)
        codec_stream = TwilicCodec.new()
        session_stream = TwilicCodec.new()

        for %InteropFixtures.Frame{stream: stream, label: label, bytes: bytes} <- frames do
          case stream do
            "codec" ->
              InteropFixtures.assert_interop_codec_decode(codec_stream, label, bytes)

            "session" ->
              InteropFixtures.assert_interop_session_decode(session_stream, label, bytes)
          end
        end

        assert length(frames) > 0
      end
    end
  end

  @tag :interop
  @tag :rust
  test "rust decodes elixir frames with same values" do
    elixir_root = File.cwd!()
    check = Path.join([elixir_root, "scripts", "rust-client-check", "Cargo.toml"])

    if File.exists?(check) and rust_root() != nil do
      fixtures = InteropFixtures.emit_interop_fixtures()

      tmp =
        Path.join(
          System.tmp_dir!(),
          "twilic-elixir-fixtures-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(tmp, fixtures)

      try do
        {output, 0} =
          System.cmd(
            "sh",
            ["-c", "cargo run --quiet --manifest-path #{inspect(check)} < #{inspect(tmp)}"],
            cd: elixir_root,
            stderr_to_stdout: true
          )

        assert output =~ "value checks passed for"
      after
        File.rm(tmp)
      end
    end
  end

  defp expects_codec_value?(label) do
    label == "scalar_string" or String.starts_with?(label, "map_two_fields_") or
      String.starts_with?(label, "map_three_fields_") or String.starts_with?(label, "bulk_map_")
  end

  defp rust_root do
    env = System.get_env("TWILIC_RUST_DIR") || System.get_env("TWILIC_RUST_ROOT")

    cond do
      is_binary(env) and File.exists?(Path.join(env, "Cargo.toml")) ->
        env

      File.exists?(Path.expand("../../rust/Cargo.toml", __DIR__)) ->
        Path.expand("../../rust", __DIR__)

      true ->
        nil
    end
  end
end
