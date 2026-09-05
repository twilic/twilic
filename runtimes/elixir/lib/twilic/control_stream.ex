defmodule Twilic.ControlStream do
  @moduledoc false
  import Bitwise
  alias Twilic.Errors
  alias Twilic.Wire

  def codec_from_byte(0), do: :plain
  def codec_from_byte(1), do: :rle
  def codec_from_byte(2), do: :bitpack
  def codec_from_byte(3), do: :huffman
  def codec_from_byte(4), do: :fse
  def codec_from_byte(_), do: nil

  def decode_payload(:plain, encoded), do: encoded
  def decode_payload(:rle, encoded), do: rle_decode_bytes(encoded)
  def decode_payload(:bitpack, encoded), do: control_bitpack_decode_bytes(encoded)
  def decode_payload(:huffman, encoded), do: decode_via_rust(:huffman, encoded)
  def decode_payload(:fse, encoded), do: decode_via_rust(:fse, encoded)

  def decode_payload(codec, _encoded),
    do: raise(Errors.invalid_data("control stream codec #{inspect(codec)}"))

  defp decode_via_rust(codec, encoded) do
    helper = rust_helper_path()

    unless File.exists?(helper) do
      raise(Errors.invalid_data("control stream rust helper not built: #{helper}"))
    end

    {hex, 0} =
      System.cmd(helper, [Atom.to_string(codec), Base.encode16(encoded, case: :lower)],
        stderr_to_stdout: true
      )

    case Base.decode16(String.trim(hex), case: :lower) do
      {:ok, bin} -> bin
      :error -> raise(Errors.invalid_data("control stream rust helper output"))
    end
  end

  defp rust_helper_path do
    env = System.get_env("TWILIC_CONTROL_STREAM_DECODE")

    cond do
      is_binary(env) and env != "" ->
        env

      File.exists?(
        priv = Path.join([Application.app_dir(:twilic, "priv"), "control_stream_decode"])
      ) ->
        priv

      true ->
        Path.expand(
          "scripts/control-stream-decode/target/release/control_stream_decode",
          File.cwd!()
        )
    end
  end

  defp rle_decode_bytes(input) do
    do_rle(input, 0, byte_size(input), <<>>)
  end

  defp do_rle(_input, i, len, acc) when i >= len, do: acc

  defp do_rle(_input, i, len, _acc) when i + 2 > len,
    do: raise(Errors.invalid_data("rle payload"))

  defp do_rle(input, i, len, acc) do
    run = :binary.at(input, i)
    byte = :binary.at(input, i + 1)
    do_rle(input, i + 2, len, acc <> :binary.copy(<<byte>>, run))
  end

  defp control_bitpack_decode_bytes(input) do
    reader = Wire.new_reader(input)
    {mode, reader} = Wire.read_u8(reader)

    case mode do
      0 ->
        n = byte_size(input) - reader.offset
        {body, _} = Wire.read_exact(n, reader)
        body

      w when w in [1, 2, 4] ->
        {len, reader} = Wire.read_count(reader)
        n = byte_size(input) - reader.offset
        {packed, _} = Wire.read_exact(n, reader)
        unpack_fixed_width_u8(packed, len, w)

      _ ->
        raise(Errors.invalid_data("control stream bitpack mode"))
    end
  end

  defp unpack_fixed_width_u8(bytes, len, width) do
    unpack_bits(bytes, len, width, 0, 0, 0, <<>>)
  end

  defp unpack_bits(bytes, 0, _width, _acc, _bits, idx, out) do
    trailing =
      if idx < byte_size(bytes), do: binary_part(bytes, idx, byte_size(bytes) - idx), else: <<>>

    if trailing != <<>> and :binary.bin_to_list(trailing) |> Enum.any?(&(&1 != 0)) do
      raise(Errors.invalid_data("control stream bitpack trailing bytes"))
    end

    out
  end

  defp unpack_bits(bytes, left, width, acc, acc_bits, idx, out) when acc_bits >= width do
    mask = (1 <<< width) - 1
    value = acc &&& mask
    unpack_bits(bytes, left - 1, width, acc >>> width, acc_bits - width, idx, out <> <<value>>)
  end

  defp unpack_bits(bytes, left, width, acc, acc_bits, idx, out) do
    if idx >= byte_size(bytes), do: raise(Errors.invalid_data("control stream bitpack underflow"))
    b = :binary.at(bytes, idx)
    unpack_bits(bytes, left, width, acc ||| b <<< acc_bits, acc_bits + 8, idx + 1, out)
  end
end
