defmodule Twilic.Codec do
  @moduledoc false
  import Bitwise
  alias Twilic.Errors
  alias Twilic.Wire
  alias Twilic.Wire.Reader

  def encode_i64_vector(values, :rle, acc), do: encode_i64_rle(values, acc)
  def encode_i64_vector(values, :direct_bitpack, acc), do: encode_i64_direct_bitpack(values, acc)

  def encode_i64_vector(values, :delta_for_bitpack, acc) do
    deltas = deltas(values)

    if deltas == [] do
      acc <> Wire.encode_varuint(0)
    else
      min_value = Enum.min(deltas)
      acc = acc <> Wire.encode_varuint(Wire.encode_zigzag(min_value))
      shifted = Enum.map(deltas, &(&1 - min_value))
      encode_i64_direct_bitpack(shifted, acc)
    end
  end

  def encode_i64_vector(values, :delta_delta_bitpack, acc),
    do: encode_i64_delta_delta(values, acc)

  def encode_i64_vector(values, :for_bitpack, acc) do
    if values == [] do
      acc <> Wire.encode_varuint(0)
    else
      min_value = Enum.min(values)
      acc = acc <> Wire.encode_varuint(Wire.encode_zigzag(min_value))
      shifted = Enum.map(values, &(&1 - min_value))
      encode_i64_direct_bitpack(shifted, acc)
    end
  end

  def encode_i64_vector(values, :delta_bitpack, acc) do
    encode_i64_direct_bitpack(deltas(values), acc)
  end

  def encode_i64_vector(values, _, acc), do: encode_i64_plain(values, acc)

  def decode_i64_vector(reader, :rle), do: decode_i64_rle(reader)
  def decode_i64_vector(reader, :direct_bitpack), do: decode_i64_direct_bitpack(reader)

  def decode_i64_vector(reader, :delta_for_bitpack) do
    {encoded_min, reader} = Wire.read_varuint(reader)
    min_value = Wire.decode_zigzag(encoded_min)

    if Wire.is_eof?(reader) do
      {[], reader}
    else
      {shifted, reader} = decode_i64_direct_bitpack(reader)
      {undelta(Enum.map(shifted, &(&1 + min_value))), reader}
    end
  end

  def decode_i64_vector(reader, :delta_delta_bitpack), do: decode_i64_delta_delta(reader)

  def decode_i64_vector(reader, :for_bitpack) do
    {encoded_min, reader} = Wire.read_varuint(reader)
    min_value = Wire.decode_zigzag(encoded_min)

    if Wire.is_eof?(reader) do
      {[], reader}
    else
      {shifted, reader} = decode_i64_direct_bitpack(reader)
      {Enum.map(shifted, &(&1 + min_value)), reader}
    end
  end

  def decode_i64_vector(reader, :delta_bitpack) do
    {deltas, reader} = decode_i64_direct_bitpack(reader)
    {undelta(deltas), reader}
  end

  def decode_i64_vector(reader, :patched_for), do: decode_i64_patched_for(reader)
  def decode_i64_vector(reader, :simple8b), do: decode_i64_simple8b(reader)

  def decode_i64_vector(reader, codec)
      when codec in [:plain, :dictionary, :string_ref, :prefix_delta, :xor_float],
      do: decode_i64_plain(reader)

  def decode_i64_vector(_reader, codec),
    do: raise(Errors.invalid_data("unsupported vector codec: #{inspect(codec)}"))

  def encode_u64_vector(values, :rle, acc), do: encode_u64_rle(values, acc)
  def encode_u64_vector(values, :direct_bitpack, acc), do: encode_u64_direct_bitpack(values, acc)

  def encode_u64_vector(values, :for_bitpack, acc) do
    if values == [] do
      acc <> Wire.encode_varuint(0)
    else
      min_value = Enum.min(values)
      acc = acc <> Wire.encode_varuint(min_value)
      shifted = Enum.map(values, &(&1 - min_value))
      encode_u64_direct_bitpack(shifted, acc)
    end
  end

  def encode_u64_vector(values, _, acc), do: encode_u64_plain(values, acc)

  def decode_u64_vector(reader, :rle), do: decode_u64_rle(reader)
  def decode_u64_vector(reader, :direct_bitpack), do: decode_u64_direct_bitpack(reader)

  def decode_u64_vector(reader, :for_bitpack) do
    {min_value, reader} = Wire.read_varuint(reader)
    if Wire.is_eof?(reader), do: {[], reader}
    {shifted, reader} = decode_u64_direct_bitpack(reader)
    {Enum.map(shifted, &(&1 + min_value)), reader}
  end

  def decode_u64_vector(reader, _), do: decode_u64_plain(reader)

  defp encode_i64_plain(values, acc) do
    acc = acc <> Wire.encode_varuint(length(values))
    Enum.reduce(values, acc, fn v, acc -> acc <> Wire.encode_varuint(Wire.encode_zigzag(v)) end)
  end

  defp decode_i64_plain(reader) do
    {length, reader} = Wire.read_count(reader)

    Enum.reduce(1..length, {[], reader}, fn _, {acc, reader} ->
      {v, reader} = Wire.read_varuint(reader)
      {acc ++ [Wire.decode_zigzag(v)], reader}
    end)
  end

  defp encode_i64_direct_bitpack(values, acc) do
    acc = acc <> Wire.encode_varuint(length(values))

    if values == [] do
      acc <> <<0>>
    else
      encoded = Enum.map(values, &Wire.encode_zigzag/1)
      width = encoded |> Enum.map(&bit_width/1) |> Enum.max() |> max(1)
      acc = acc <> <<width>>
      pack_u64(encoded, width, acc)
    end
  end

  defp decode_i64_direct_bitpack(reader) do
    {length, reader} = Wire.read_count(reader)
    {width, reader} = Wire.read_u8(reader)
    if length == 0, do: {[], reader}
    if width == 0 or width > 64, do: raise(Errors.invalid_data("bitpack width"))

    {encoded, reader} = unpack_u64(reader, length, width)
    {Enum.map(encoded, &Wire.decode_zigzag/1), reader}
  end

  defp encode_i64_rle(values, acc) do
    runs = i64_rle_runs(values)
    acc = acc <> Wire.encode_varuint(length(runs))

    Enum.reduce(runs, acc, fn {val, count}, acc ->
      acc <> Wire.encode_varuint(Wire.encode_zigzag(val)) <> Wire.encode_varuint(count)
    end)
  end

  defp decode_i64_rle(reader) do
    {runs_len, reader} = Wire.read_count(reader)

    Enum.reduce(1..runs_len//1, {[], reader}, fn _, {acc, reader} ->
      {value, reader} = Wire.read_varuint(reader)
      {count, reader} = Wire.read_count(reader)
      value = Wire.decode_zigzag(value)
      {acc ++ List.duplicate(value, count), reader}
    end)
  end

  defp i64_rle_runs(values) do
    Enum.reduce(values, [], fn value, runs ->
      case runs do
        [{^value, count} | rest] -> [{value, count + 1} | rest]
        _ -> runs ++ [{value, 1}]
      end
    end)
  end

  defp encode_i64_delta_delta(values, acc) do
    acc = acc <> Wire.encode_varuint(length(values))

    case values do
      [] ->
        acc

      [first] ->
        acc <> Wire.encode_varuint(Wire.encode_zigzag(first))

      values ->
        [first, second | _] = values
        d1 = second - first

        acc =
          acc <>
            Wire.encode_varuint(Wire.encode_zigzag(first)) <>
            Wire.encode_varuint(Wire.encode_zigzag(d1))

        {dd, _} =
          Enum.reduce(1..(length(values) - 2), {[], d1}, fn i, {dd_acc, prev_delta} ->
            d = Enum.at(values, i + 1) - Enum.at(values, i)
            {dd_acc ++ [d - prev_delta], d}
          end)

        encode_i64_direct_bitpack(dd, acc)
    end
  end

  defp decode_i64_delta_delta(reader) do
    {count, reader} = Wire.read_count(reader)
    if count == 0, do: {[], reader}

    {first, reader} = Wire.read_varuint(reader)
    first = Wire.decode_zigzag(first)
    if count == 1, do: {[first], reader}

    {first_delta, reader} = Wire.read_varuint(reader)
    first_delta = Wire.decode_zigzag(first_delta)
    {dd, reader} = decode_i64_direct_bitpack(reader)

    if length(dd) != count - 2, do: raise(Errors.invalid_data("delta-delta length"))

    second = first + first_delta

    {out, _, _} =
      Enum.reduce(dd, {[first, second], first_delta, second}, fn ddv, {acc, prev_delta, prev} ->
        d = prev_delta + ddv
        nxt = prev + d
        {acc ++ [nxt], d, nxt}
      end)

    {out, reader}
  end

  defp decode_i64_patched_for(reader) do
    {count, reader} = Wire.read_count(reader)
    if count == 0, do: {[], reader}

    {base, reader} = Wire.read_varuint(reader)
    base = Wire.decode_zigzag(base)
    {_base_width, reader} = Wire.read_u8(reader)
    {values, reader} = read_patched_for_values(count, [], reader)
    {values, reader} = apply_patched_for_patches(values, reader)
    {Enum.map(values, &(&1 + base)), reader}
  end

  defp read_patched_for_values(0, acc, reader), do: {Enum.reverse(acc), reader}

  defp read_patched_for_values(n, acc, reader) when n > 0 do
    {v, reader} = Wire.read_varuint(reader)
    read_patched_for_values(n - 1, [v | acc], reader)
  end

  defp apply_patched_for_patches(values, reader) do
    {patch_count, reader} = Wire.read_count(reader)

    Enum.reduce(1..patch_count, {values, reader}, fn _, {vals, reader} ->
      {pos, reader} = Wire.read_varuint(reader)
      {patch, reader} = Wire.read_varuint(reader)

      vals =
        if pos < length(vals) do
          List.replace_at(vals, pos, patch)
        else
          vals
        end

      {vals, reader}
    end)
  end

  @simple8b_slots [
    {60, 1},
    {30, 2},
    {20, 3},
    {15, 4},
    {12, 5},
    {10, 6},
    {8, 7},
    {7, 8},
    {6, 10},
    {5, 12},
    {4, 15},
    {3, 20},
    {2, 30},
    {1, 60}
  ]

  defp decode_i64_simple8b(reader) do
    {word_count, reader} = Wire.read_count(reader)
    {words, reader} = read_simple8b_words(word_count, [], reader)
    values = Enum.flat_map(words, &decode_simple8b_word/1)
    {values, reader}
  end

  defp read_simple8b_words(0, acc, reader), do: {Enum.reverse(acc), reader}

  defp read_simple8b_words(n, acc, reader) when n > 0 do
    {word, reader} = Wire.read_u64_le(reader)
    read_simple8b_words(n - 1, [word | acc], reader)
  end

  defp decode_simple8b_word(word) do
    selector = Bitwise.bsr(word, 60)

    case Enum.at(@simple8b_slots, selector) do
      {count, width} ->
        mask = Bitwise.bsl(1, width) - 1

        for i <- 0..(count - 1) do
          shift = 60 - (i + 1) * width
          encoded = Bitwise.band(Bitwise.bsr(word, shift), mask)
          Wire.decode_zigzag(encoded)
        end

      _ ->
        raise(Errors.invalid_data("simple8b selector"))
    end
  end

  defp deltas(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, i} -> if i == 0, do: value, else: value - Enum.at(values, i - 1) end)
  end

  defp undelta([]), do: []

  defp undelta(values) do
    Enum.reduce(values, [], fn v, acc ->
      if acc == [], do: [v], else: acc ++ [List.last(acc) + v]
    end)
  end

  defp encode_u64_plain(values, acc) do
    acc = acc <> Wire.encode_varuint(length(values))
    Enum.reduce(values, acc, fn v, acc -> acc <> Wire.encode_varuint(v) end)
  end

  defp decode_u64_plain(reader) do
    {length, reader} = Wire.read_count(reader)

    Enum.reduce(1..length, {[], reader}, fn _, {acc, reader} ->
      {v, reader} = Wire.read_varuint(reader)
      {acc ++ [v], reader}
    end)
  end

  defp encode_u64_rle(values, acc) do
    runs = rle_runs(values)
    acc = acc <> Wire.encode_varuint(length(runs))

    Enum.reduce(runs, acc, fn {val, count}, acc ->
      acc <> Wire.encode_varuint(val) <> Wire.encode_varuint(count)
    end)
  end

  defp decode_u64_rle(reader) do
    {runs_len, reader} = Wire.read_count(reader)

    Enum.reduce(1..runs_len//1, {[], reader}, fn _, {acc, reader} ->
      {value, reader} = Wire.read_varuint(reader)
      {count, reader} = Wire.read_count(reader)
      {acc ++ List.duplicate(value, count), reader}
    end)
  end

  defp rle_runs(values) do
    Enum.reduce(values, [], fn value, runs ->
      case runs do
        [{^value, count} | rest] -> [{value, count + 1} | rest]
        _ -> runs ++ [{value, 1}]
      end
    end)
  end

  defp encode_u64_direct_bitpack(values, acc) do
    acc = acc <> Wire.encode_varuint(length(values))

    if values == [] do
      acc <> <<0>>
    else
      width = Enum.map(values, &bit_width/1) |> Enum.max()
      acc = acc <> <<width>>
      pack_u64(values, width, acc)
    end
  end

  defp decode_u64_direct_bitpack(reader) do
    {length, reader} = Wire.read_count(reader)
    {width, reader} = Wire.read_u8(reader)
    if length == 0, do: {[], reader}
    if width == 0 or width > 64, do: raise(Errors.invalid_data("bitpack width"))
    unpack_u64(reader, length, width)
  end

  defp bit_width(0), do: 1
  defp bit_width(v) when v > 0, do: floor(:math.log2(v)) + 1

  defp pack_u64(values, width, acc) do
    bits =
      for value <- values, bit <- 0..(width - 1) do
        Bitwise.band(Bitwise.bsr(value, bit), 1) == 1
      end

    acc <> bits_to_bytes(bits)
  end

  defp bits_to_bytes(bits) do
    pad = rem(8 - rem(length(bits), 8), 8)
    bits = bits ++ List.duplicate(false, pad)

    bits
    |> Enum.chunk_every(8)
    |> Enum.map(fn chunk ->
      Enum.reduce(Enum.with_index(chunk), 0, fn {bit, i}, byte ->
        if bit, do: Bitwise.bor(byte, Bitwise.bsl(1, i)), else: byte
      end)
    end)
    |> :binary.list_to_bin()
  end

  defp unpack_u64(reader, length, width) do
    total_bits = length * width
    byte_len = div(total_bits + 7, 8)
    {raw, reader} = Wire.read_exact(byte_len, reader)
    bits = bytes_to_bits(raw, total_bits)

    values =
      bits
      |> Enum.chunk_every(width)
      |> Enum.map(fn chunk ->
        Enum.with_index(chunk)
        |> Enum.reduce(0, fn {bit, i}, acc ->
          if bit, do: Bitwise.bor(acc, Bitwise.bsl(1, i)), else: acc
        end)
      end)

    {values, reader}
  end

  defp bytes_to_bits(raw, bit_count) do
    for i <- 0..(bit_count - 1) do
      (Bitwise.bsr(:binary.at(raw, div(i, 8)), rem(i, 8)) &&& 1) == 1
    end
  end
end
