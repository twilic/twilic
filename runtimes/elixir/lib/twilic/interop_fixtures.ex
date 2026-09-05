defmodule Twilic.InteropFixtures do
  @moduledoc false
  alias Twilic.Model
  alias Twilic.Model.Value
  alias Twilic.Protocol
  alias Twilic.Protocol.{SessionEncoder, TwilicCodec}

  defmodule Frame do
    defstruct [:stream, :label, :hex, :bytes]
  end

  def interop_id_name_map(id, name) do
    Model.new_map([
      Model.entry("id", Model.new_u64(id)),
      Model.entry("name", Model.new_string(name))
    ])
  end

  def interop_id_name_role_map(id, name, role) do
    Model.new_map([
      Model.entry("id", Model.new_u64(id)),
      Model.entry("name", Model.new_string(name)),
      Model.entry("role", Model.new_string(role))
    ])
  end

  def interop_make_i64_array(length, start) do
    Enum.map(0..(length - 1), fn i -> Model.new_i64(start + i) end)
  end

  def interop_make_user_rows(names) do
    Enum.with_index(names)
    |> Enum.map(fn {name, i} ->
      Model.new_map([
        Model.entry("id", Model.new_u64(i + 1)),
        Model.entry("name", Model.new_string(name))
      ])
    end)
  end

  def reset_encode_shape_observation(codec, keys) do
    state = Twilic.ProtocolHelpers.reset_encode_shape_observation(codec.state, keys)
    %{codec | state: state}
  end

  def emit_interop_fixtures do
    codec = TwilicCodec.new()
    out = []

    out =
      emit_interop_value(out, "codec", "scalar_string", codec, Model.new_string("alpha"))

    map_two = interop_id_name_map(1, "alice")
    out = emit_interop_value(out, "codec", "map_two_fields_first", codec, map_two)
    codec = reset_encode_shape_observation(codec, ["id", "name"])
    out = emit_interop_value(out, "codec", "map_two_fields_second", codec, map_two)

    map_three = interop_id_name_role_map(1, "alice", "admin")
    out = emit_interop_value(out, "codec", "map_three_fields_first", codec, map_three)
    codec = reset_encode_shape_observation(codec, ["id", "name", "role"])
    out = emit_interop_value(out, "codec", "map_three_fields_second", codec, map_three)

    out =
      Enum.reduce(0..7, out, fn i, out ->
        emit_interop_value(
          out,
          "codec",
          "bulk_map_#{i}",
          codec,
          interop_id_name_map(10 + i, "user-#{i}")
        )
      end)

    base_snapshot =
      Model.message(13,
        base_snapshot: %Model.BaseSnapshotMessage{
          base_id: 77,
          schema_or_shape_ref: 0,
          payload: Model.message(0, scalar: Model.new_i64(42))
        }
      )

    out = emit_interop_message(out, "codec", "base_snapshot", codec, base_snapshot)

    enc = SessionEncoder.new()

    base_array = Model.new_array(interop_make_i64_array(100, 0))
    {enc, base_bytes} = SessionEncoder.encode(enc, base_array)
    out = emit_interop_frame(out, "session", "session_base_array", base_bytes)

    one_change_arr = interop_make_i64_array(100, 0)
    one_change_arr = List.replace_at(one_change_arr, 0, Model.new_i64(10_000))
    one_change = Model.new_array(one_change_arr)
    {enc, one_patch} = SessionEncoder.encode_patch(enc, one_change)
    out = emit_interop_frame(out, "session", "session_patch_one_change", one_patch)

    {enc, out} =
      Enum.reduce(0..3, {enc, out}, fn step, {enc, out} ->
        iter_arr = interop_make_i64_array(100, 0)
        iter_arr = List.replace_at(iter_arr, step, Model.new_i64(20_000 + step))
        iterative = Model.new_array(iter_arr)
        {enc, bytes} = SessionEncoder.encode_patch(enc, iterative)
        {enc, emit_interop_frame(out, "session", "session_patch_iter_#{step}", bytes)}
      end)

    many_arr =
      interop_make_i64_array(100, 0)
      |> Enum.with_index()
      |> Enum.map(fn {v, idx} ->
        if idx < 12, do: Model.new_i64(10_000 + idx), else: v
      end)

    many_change = Model.new_array(many_arr)
    {enc, many_patch} = SessionEncoder.encode_patch(enc, many_change)
    out = emit_interop_frame(out, "session", "session_patch_many_changes", many_patch)

    rows1 = interop_make_user_rows(["a", "b", "c", "d"])
    {enc, micro_first} = SessionEncoder.encode_micro_batch(enc, rows1)
    out = emit_interop_frame(out, "session", "session_micro_batch_first", micro_first)

    rows2 = interop_make_user_rows(["aa", "bb", "cc", "dd"])
    {_enc, micro_second} = SessionEncoder.encode_micro_batch(enc, rows2)
    emit_interop_frame(out, "session", "session_micro_batch_second", micro_second)

    IO.iodata_to_binary(out)
  end

  def emit_interop_value(out, stream, label, codec, %Value{} = value) do
    {_codec, bytes} = TwilicCodec.encode_value_pair(codec, value)
    emit_interop_frame(out, stream, label, bytes)
  end

  def emit_interop_message(out, stream, label, codec, message) do
    bytes = TwilicCodec.encode_message(codec, message)
    emit_interop_frame(out, stream, label, bytes)
  end

  def emit_interop_frame(out, stream, label, bytes) do
    hex = Base.encode16(bytes, case: :lower)
    [out, stream, ?|, label, ?|, hex, ?\n]
  end

  def parse_interop_frames(input) when is_binary(input) do
    input
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> Enum.reduce({[], 0}, fn line, {frames, line_no} ->
      line = String.trim(line)

      if line == "" do
        {frames, line_no + 1}
      else
        case parse_interop_frame_line(line) do
          {:ok, stream, label, hex} ->
            bytes = decode_interop_hex(hex)
            frame = %Frame{stream: stream, label: label, hex: hex, bytes: bytes}
            {[frame | frames], line_no + 1}

          {:error, reason} ->
            raise ArgumentError, "line #{line_no + 1}: #{reason}"
        end
      end
    end)
    |> then(fn {frames, _} ->
      frames = Enum.reverse(frames)
      if frames == [], do: raise(ArgumentError, "no fixture frames found")
      frames
    end)
  end

  def parse_interop_frame_line(line) do
    case String.split(line, "|", parts: 3) do
      [stream, label, hex] when stream != "" and label != "" -> {:ok, stream, label, hex}
      _ -> {:error, "invalid frame"}
    end
  end

  def decode_interop_hex(hex) when rem(byte_size(hex), 2) == 0 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> raise(ArgumentError, "invalid hex")
    end
  end

  def decode_interop_hex(_), do: raise(ArgumentError, "invalid hex length")

  def assert_interop_codec_decode(%TwilicCodec{} = codec, label, frame) do
    cond do
      label == "base_snapshot" ->
        {codec, msg} = TwilicCodec.decode_message(codec, frame)
        true = msg.kind == 13
        true = msg.base_snapshot.base_id == 77
        true = msg.base_snapshot.payload.kind == 0
        true = msg.base_snapshot.payload.scalar.i64 == 42
        codec

      interop_expect_control_stream_codec(label) != nil ->
        {codec, msg} = TwilicCodec.decode_message(codec, frame)
        true = msg.kind == 12
        true = msg.control_stream != nil
        true = byte_size(msg.control_stream.payload) > 0
        codec

      true ->
        case interop_expect_codec_value(label) do
          nil ->
            raise ArgumentError, "no codec expectation for label #{label}"

          want ->
            {codec, got} = TwilicCodec.decode_value_pair(codec, frame)

            unless Model.equal?(got, want) do
              raise ArgumentError, "decoded value mismatch for #{label}"
            end

            codec
        end
    end
  end

  def assert_interop_session_decode(%TwilicCodec{} = codec, label, frame) do
    case label do
      "session_base_array" ->
        want = Model.new_array(interop_make_i64_array(100, 0))
        {codec, got} = TwilicCodec.decode_value_pair(codec, frame)

        unless Model.equal?(got, want),
          do: raise(ArgumentError, "session_base_array value mismatch")

        codec

      "session_patch_one_change" ->
        {codec, msg} = TwilicCodec.decode_message(codec, frame)

        unless msg.kind in [10, 5, 1],
          do: raise(ArgumentError, "unexpected message kind for session_patch_one_change")

        codec

      "session_patch_many_changes" ->
        {codec, msg} = TwilicCodec.decode_message(codec, frame)
        unless msg.kind in [10, 5, 1], do: raise(ArgumentError, "expected patch or array message")
        codec

      "session_micro_batch_first" ->
        {codec, msg} = TwilicCodec.decode_message(codec, frame)

        unless msg.kind == 11 and msg.template_batch.count == 4,
          do: raise(ArgumentError, "expected template batch with 4 rows")

        codec

      "session_micro_batch_second" ->
        {codec, msg} = TwilicCodec.decode_message(codec, frame)

        unless msg.kind == 11 and msg.template_batch.count == 4,
          do: raise(ArgumentError, "expected template batch with 4 rows")

        codec

      _ ->
        if String.starts_with?(label, "session_patch_iter_") do
          {codec, msg} = TwilicCodec.decode_message(codec, frame)

          unless msg.kind in [10, 5, 1],
            do: raise(ArgumentError, "expected patch or array message")

          codec
        else
          raise ArgumentError, "no session expectation for label #{label}"
        end
    end
  end

  def decode_rust_server_frames(input) when is_binary(input) do
    frames = parse_interop_frames(input)
    codec_stream = TwilicCodec.new()
    session_stream = TwilicCodec.new()

    {codec_stream, session_stream} =
      Enum.reduce(frames, {codec_stream, session_stream}, fn %Frame{
                                                               stream: stream,
                                                               label: label,
                                                               bytes: bytes
                                                             },
                                                             {codec_acc, session_acc} ->
        case stream do
          "codec" -> {assert_interop_codec_decode(codec_acc, label, bytes), session_acc}
          "session" -> {codec_acc, assert_interop_session_decode(session_acc, label, bytes)}
          other -> raise(ArgumentError, "unknown stream #{other}")
        end
      end)

    _codec_stream = codec_stream
    _session_stream = session_stream

    IO.puts("Elixir client decode and value checks passed for #{length(frames)} Rust frames")
  end

  defp interop_expect_codec_value("scalar_string"), do: Model.new_string("alpha")
  defp interop_expect_codec_value("map_two_fields_" <> _), do: interop_id_name_map(1, "alice")

  defp interop_expect_codec_value("map_three_fields_" <> _),
    do: interop_id_name_role_map(1, "alice", "admin")

  defp interop_expect_codec_value("bulk_map_" <> rest) do
    idx = String.to_integer(rest)
    interop_id_name_map(10 + idx, "user-#{idx}")
  end

  defp interop_expect_codec_value(_), do: nil

  defp interop_expect_control_stream_codec(label) do
    case label do
      "control_stream_bitpack" -> :bitpack
      "control_stream_huffman" -> :huffman
      "control_stream_fse" -> :fse
      _ -> nil
    end
  end

  def replay_codec_state(frames, stop_label) do
    iso = TwilicCodec.new()

    frames
    |> Enum.take_while(fn %Frame{stream: "codec", label: label} -> label != stop_label end)
    |> Enum.each(fn %Frame{stream: "codec", label: label, bytes: bytes} ->
      cond do
        label == "base_snapshot" ->
          TwilicCodec.decode_message(iso, bytes)

        interop_expect_control_stream_codec(label) != nil ->
          TwilicCodec.decode_message(iso, bytes)

        interop_expect_codec_value(label) != nil ->
          TwilicCodec.decode_value(iso, bytes)

        true ->
          :ok
      end
    end)

    iso
  end
end
