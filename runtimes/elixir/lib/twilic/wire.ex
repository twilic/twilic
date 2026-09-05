defmodule Twilic.Wire do
  @moduledoc false
  import Bitwise
  alias Twilic.Errors

  defmodule Reader do
    defstruct input: <<>>, offset: 0, depth: 0, budget: 0
  end

  def encode_varuint(value), do: encode_varuint(value, <<>>)

  defp encode_varuint(value, acc) when value < 0x80, do: <<acc::binary, value>>

  defp encode_varuint(value, acc) do
    b = Bitwise.band(value, 0x7F)
    value = Bitwise.bsr(value, 7)
    b = if value != 0, do: Bitwise.bor(b, 0x80), else: b
    encode_varuint(value, <<acc::binary, b>>)
  end

  def encode_zigzag(value), do: Bitwise.bxor(Bitwise.bsl(value, 1), Bitwise.bsr(value, 63))
  def decode_zigzag(value), do: Bitwise.bxor(Bitwise.bsr(value, 1), -Bitwise.band(value, 1))

  def encode_bytes(data, acc) when is_binary(data) and is_binary(acc),
    do: acc <> encode_varuint(byte_size(data)) <> data

  def encode_string(value, acc) when is_binary(value) and is_binary(acc),
    do: encode_bytes(value, acc)

  def encode_bitmap(bits, acc) do
    acc = encode_varuint(length(bits), acc)

    {acc, current} =
      Enum.reduce(Enum.with_index(bits), {acc, 0}, fn {bit, i}, {acc, current} ->
        current = if bit, do: Bitwise.bor(current, Bitwise.bsl(1, rem(i, 8))), else: current

        if rem(i, 8) == 7 do
          {acc <> <<current>>, 0}
        else
          {acc, current}
        end
      end)

    if rem(length(bits), 8) != 0, do: acc <> <<current>>, else: acc
  end

  def new_reader(input),
    do: %Reader{input: input, offset: 0, budget: min(byte_size(input), 1024) * 1024}

  def claim_output(reader, count) do
    if not is_integer(count) or count < 0 or count > 1_048_576,
      do: raise(Errors.invalid_data("decode count limit exceeded"))

    if count > div(reader.budget, 8),
      do: raise(Errors.invalid_data("decode output ratio exceeded"))

    %{reader | budget: reader.budget - count * 8}
  end

  def read_count(reader, maximum \\ 1_048_576) do
    {count, reader} = read_varuint(reader)
    if count > maximum, do: raise(Errors.invalid_data("decode count limit exceeded"))
    {count, claim_output(reader, count)}
  end

  def enter_depth(reader) do
    if reader.depth >= 64, do: raise(Errors.invalid_data("decode depth limit exceeded"))
    %{reader | depth: reader.depth + 1}
  end

  def leave_depth(reader), do: %{reader | depth: reader.depth - 1}

  def read_u8(%Reader{input: input, offset: offset} = reader) do
    if offset >= byte_size(input), do: raise(Errors.unexpected_eof())
    {:binary.at(input, offset), %{reader | offset: offset + 1}}
  end

  def read_exact(n, %Reader{input: input, offset: offset} = r) do
    if n < 0 or n > byte_size(input) - offset, do: raise(Errors.unexpected_eof())
    slice = binary_part(input, offset, n)
    {slice, %{r | offset: offset + n}}
  end

  def read_varuint(reader) do
    read_varuint(reader, 0, 0)
  end

  defp read_varuint(reader, shift, result) when shift >= 64,
    do: raise(Errors.invalid_data("varuint too large"))

  defp read_varuint(reader, shift, result) do
    {b, reader} = read_u8(reader)

    if shift == 63 and Bitwise.band(b, 0x7E) != 0,
      do: raise(Errors.invalid_data("varuint too large"))

    result = Bitwise.bor(result, Bitwise.bsl(Bitwise.band(b, 0x7F), shift))

    if Bitwise.band(b, 0x80) == 0 do
      {result, reader}
    else
      read_varuint(reader, shift + 7, result)
    end
  end

  def read_bytes(reader) do
    {n, reader} = read_varuint(reader)
    read_exact(n, reader)
  end

  def read_string(reader) do
    {data, reader} = read_bytes(reader)

    if String.valid?(data) do
      {data, reader}
    else
      raise(Errors.utf8_error())
    end
  end

  def read_bitmap(reader) do
    {bit_count, reader} = read_count(reader)
    byte_count = div(bit_count + 7, 8)
    {raw, reader} = read_exact(byte_count, reader)

    bits =
      for i <- 0..(bit_count - 1)//1 do
        (bsr(:binary.at(raw, div(i, 8)), rem(i, 8)) &&& 1) == 1
      end

    {bits, reader}
  end

  def is_eof?(%Reader{input: input, offset: offset}), do: offset >= byte_size(input)

  def read_u64_le(reader) do
    {b, reader} = read_exact(8, reader)
    <<v::little-unsigned-integer-size(64)>> = b
    {v, reader}
  end

  def read_f64_le(reader) do
    {u, reader} = read_u64_le(reader)
    <<d::little-float-64>> = <<u::unsigned-integer-size(64)>>
    {d, reader}
  end

  def append_u64_le(acc, v) do
    acc <> <<v::little-unsigned-integer-size(64)>>
  end

  def append_f64_le(acc, v) do
    <<u::unsigned-integer-size(64)>> = <<v::little-float-64>>
    append_u64_le(acc, u)
  end
end
