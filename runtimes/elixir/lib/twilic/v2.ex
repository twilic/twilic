defmodule Twilic.V2 do
  @moduledoc false
  import Bitwise
  alias Twilic.Errors
  alias Twilic.Model
  alias Twilic.Model.Value
  alias Twilic.Wire
  alias Twilic.Wire.Reader

  @null_tag 0xC0
  @false_tag 0xC1
  @true_tag 0xC2
  @f64_tag 0xC3
  @u8_tag 0xC4
  @u16_tag 0xC5
  @u32_tag 0xC6
  @u64_tag 0xC7
  @i8_tag 0xC8
  @i16_tag 0xC9
  @i32_tag 0xCA
  @i64_tag 0xCB
  @bin8_tag 0xCC
  @bin16_tag 0xCD
  @bin32_tag 0xCE
  @str8_tag 0xCF
  @str16_tag 0xD0
  @str32_tag 0xD1
  @array16_tag 0xD2
  @array32_tag 0xD3
  @map16_tag 0xD4
  @map32_tag 0xD5
  @shape_def_tag 0xD6
  @key_ref_tag 0xD8
  @str_ref_tag 0xD9

  def encode(value) do
    state = %{
      key_ids: %{},
      str_ids: %{},
      shape_ids: %{},
      next_key_id: 0,
      next_str_id: 0,
      next_shape_id: 0
    }

    {acc, _} = encode_value(value, <<>>, state)
    acc
  end

  def decode(data) do
    reader = Wire.new_reader(data)
    state = %{keys: [], strings: [], shapes: []}
    {value, reader} = decode_value(reader, state)

    if Wire.is_eof?(reader),
      do: value,
      else: raise(Errors.invalid_data("trailing bytes in v2 decode"))
  end

  defp shape_key(keys), do: Enum.join(keys, <<0>>)

  defp encode_value(%Value{kind: :null}, acc, state), do: {acc <> <<@null_tag>>, state}

  defp encode_value(%Value{kind: :bool, bool: b}, acc, state),
    do: {acc <> <<if(b, do: @true_tag, else: @false_tag)>>, state}

  defp encode_value(%Value{kind: :i64, i64: n}, acc, state), do: {encode_i64(n, acc), state}
  defp encode_value(%Value{kind: :u64, u64: n}, acc, state), do: {encode_u64(n, acc), state}

  defp encode_value(%Value{kind: :f64, f64: n}, acc, state),
    do: {acc |> Kernel.<>(<<@f64_tag>>) |> Wire.append_f64_le(n), state}

  defp encode_value(%Value{kind: :string, str: s}, acc, state) do
    case Map.get(state.str_ids, s) do
      nil ->
        str_id = state.next_str_id
        state = %{state | str_ids: Map.put(state.str_ids, s, str_id), next_str_id: str_id + 1}
        {encode_string_literal(s, acc), state}

      ref_id ->
        {acc <> <<@str_ref_tag>> <> Wire.encode_varuint(ref_id), state}
    end
  end

  defp encode_value(%Value{kind: :binary, bin: bin}, acc, state),
    do: {encode_binary(bin, acc), state}

  defp encode_value(%Value{kind: :array, arr: arr}, acc, state), do: encode_array(arr, acc, state)
  defp encode_value(%Value{kind: :map, map: map}, acc, state), do: encode_map(map, acc, state)

  defp encode_string_literal(value, acc) do
    raw = value
    length = byte_size(raw)

    acc =
      cond do
        length <= 31 ->
          acc <> <<0x80 ||| length>>

        length <= 0xFF ->
          acc <> <<@str8_tag, length>>

        length <= 0xFFFF ->
          acc <> <<@str16_tag, length &&& 0xFF, length >>> 8 &&& 0xFF>>

        true ->
          acc <>
            <<@str32_tag, length &&& 0xFF, length >>> 8 &&& 0xFF, length >>> 16 &&& 0xFF,
              length >>> 24 &&& 0xFF>>
      end

    acc <> raw
  end

  defp encode_binary(value, acc) do
    length = byte_size(value)

    acc =
      cond do
        length <= 0xFF ->
          acc <> <<@bin8_tag, length>>

        length <= 0xFFFF ->
          acc <> <<@bin16_tag, length &&& 0xFF, length >>> 8 &&& 0xFF>>

        true ->
          acc <>
            <<@bin32_tag, length &&& 0xFF, length >>> 8 &&& 0xFF, length >>> 16 &&& 0xFF,
              length >>> 24 &&& 0xFF>>
      end

    acc <> value
  end

  defp encode_u64(value, acc) when value <= 127, do: acc <> <<value>>
  defp encode_u64(value, acc) when value <= 0xFF, do: acc <> <<@u8_tag, value>>

  defp encode_u64(value, acc) when value <= 0xFFFF,
    do: acc <> <<@u16_tag, value &&& 0xFF, value >>> 8 &&& 0xFF>>

  defp encode_u64(value, acc) when value <= 0xFFFFFFFF,
    do:
      acc <>
        <<@u32_tag, value &&& 0xFF, value >>> 8 &&& 0xFF, value >>> 16 &&& 0xFF,
          value >>> 24 &&& 0xFF>>

  defp encode_u64(value, acc), do: acc |> Kernel.<>(<<@u64_tag>>) |> Wire.append_u64_le(value)

  defp encode_i64(value, acc) when value >= -32 and value <= -1,
    do: acc <> <<Bitwise.band(value, 0xFF)>>

  defp encode_i64(value, acc) when value >= 0 and value <= 127, do: acc <> <<value>>

  defp encode_i64(value, acc) when value >= -128 and value <= 127,
    do: acc <> <<@i8_tag, Bitwise.band(value, 0xFF)>>

  defp encode_i64(value, acc) when value >= -32768 and value <= 32767,
    do: acc <> <<@i16_tag, value::little-signed-integer-size(16)>>

  defp encode_i64(value, acc) when value >= -2_147_483_648 and value <= 2_147_483_647,
    do: acc <> <<@i32_tag, value::little-signed-integer-size(32)>>

  defp encode_i64(value, acc),
    do:
      acc
      |> Kernel.<>(<<@i64_tag>>)
      |> Wire.append_u64_le(Bitwise.band(value, 0xFFFFFFFFFFFFFFFF))

  defp write_array_header(length, acc) when length <= 15, do: acc <> <<0xA0 ||| length>>

  defp write_array_header(length, acc) when length <= 0xFFFF,
    do: acc <> <<@array16_tag, length &&& 0xFF, length >>> 8 &&& 0xFF>>

  defp write_array_header(length, acc),
    do:
      acc <>
        <<@array32_tag, length &&& 0xFF, length >>> 8 &&& 0xFF, length >>> 16 &&& 0xFF,
          length >>> 24 &&& 0xFF>>

  defp write_map_header(length, acc) when length <= 15, do: acc <> <<0xB0 ||| length>>

  defp write_map_header(length, acc) when length <= 0xFFFF,
    do: acc <> <<@map16_tag, length &&& 0xFF, length >>> 8 &&& 0xFF>>

  defp write_map_header(length, acc),
    do:
      acc <>
        <<@map32_tag, length &&& 0xFF, length >>> 8 &&& 0xFF, length >>> 16 &&& 0xFF,
          length >>> 24 &&& 0xFF>>

  defp detect_shape_keys(values) when length(values) < 2, do: nil

  defp detect_shape_keys([%Value{kind: :map, map: first} | rest]) when first != [] do
    check_shape_keys(Enum.map(first, & &1.key), rest)
  end

  defp detect_shape_keys(_), do: nil

  defp check_shape_keys(keys, rest) do
    if Enum.all?(rest, fn %Value{kind: :map, map: map} ->
         length(map) == length(keys) and
           Enum.zip(map, keys) |> Enum.all?(fn {e, k} -> e.key == k end)
       end) do
      keys
    else
      nil
    end
  end

  defp encode_key(key, acc, state) do
    case Map.get(state.key_ids, key) do
      nil ->
        acc = encode_string_literal(key, acc)
        id = state.next_key_id
        {acc, %{state | key_ids: Map.put(state.key_ids, key, id), next_key_id: id + 1}}

      ref_id ->
        {acc <> <<@key_ref_tag>> <> Wire.encode_varuint(ref_id), state}
    end
  end

  defp encode_map(entries, acc, state) do
    acc = write_map_header(length(entries), acc)

    Enum.reduce(entries, {acc, state}, fn %{key: key, value: value}, {acc, state} ->
      {acc, state} = encode_key(key, acc, state)
      encode_value(value, acc, state)
    end)
  end

  defp encode_array(values, acc, state) do
    case detect_shape_keys(values) do
      nil ->
        acc = write_array_header(length(values), acc)

        Enum.reduce(values, {acc, state}, fn v, {acc, state} ->
          encode_value(v, acc, state)
        end)

      shape_keys ->
        sk = shape_key(shape_keys)

        {shape_id, state} =
          case Map.get(state.shape_ids, sk) do
            nil ->
              id = state.next_shape_id
              {id, %{state | shape_ids: Map.put(state.shape_ids, sk, id), next_shape_id: id + 1}}

            id ->
              {id, state}
          end

        acc = write_array_header(length(values), acc)

        acc =
          acc <>
            <<@shape_def_tag>> <>
            Wire.encode_varuint(shape_id) <> Wire.encode_varuint(length(shape_keys))

        {acc, state} =
          Enum.reduce(shape_keys, {acc, state}, fn key, {acc, state} ->
            encode_key(key, acc, state)
          end)

        Enum.reduce(values, {acc, state}, fn %Value{kind: :map, map: map}, {acc, state} ->
          Enum.reduce(map, {acc, state}, fn %{value: v}, {acc, state} ->
            encode_value(v, acc, state)
          end)
        end)
    end
  end

  defp decode_value(reader, state) do
    {tag, reader} = Wire.read_u8(reader)
    decode_value_from_tag(reader, state, tag)
  end

  defp decode_value_from_tag(reader, state, tag) when tag <= 0x7F,
    do: {Model.new_u64(tag), reader}

  defp decode_value_from_tag(reader, state, tag) when tag >= 0x80 and tag <= 0x9F do
    length = tag &&& 0x1F
    {raw, reader} = Wire.read_exact(length, reader)
    s = raw
    state = %{state | strings: state.strings ++ [s]}
    {Model.new_string(s), reader}
  end

  defp decode_value_from_tag(reader, state, tag) when tag >= 0xA0 and tag <= 0xAF,
    do: decode_array_body(reader, state, tag &&& 0x0F)

  defp decode_value_from_tag(reader, state, tag) when tag >= 0xB0 and tag <= 0xBF,
    do: decode_map_body(reader, state, tag &&& 0x0F)

  defp decode_value_from_tag(reader, state, tag) when tag >= 0xE0,
    do: {Model.new_i64(if(tag < 128, do: tag, else: tag - 256)), reader}

  defp decode_value_from_tag(reader, state, @null_tag), do: {Model.new_null(), reader}
  defp decode_value_from_tag(reader, state, @false_tag), do: {Model.new_bool(false), reader}
  defp decode_value_from_tag(reader, state, @true_tag), do: {Model.new_bool(true), reader}

  defp decode_value_from_tag(reader, state, @f64_tag),
    do: Wire.read_f64_le(reader) |> then(&{Model.new_f64(elem(&1, 0)), elem(&1, 1)})

  defp decode_value_from_tag(reader, state, @u8_tag) do
    {b, reader} = Wire.read_u8(reader)
    {Model.new_u64(b), reader}
  end

  defp decode_value_from_tag(reader, state, @u16_tag) do
    {<<b0, b1>>, reader} = Wire.read_exact(2, reader)
    {Model.new_u64(b0 ||| Bitwise.bsl(b1, 8)), reader}
  end

  defp decode_value_from_tag(reader, state, @u32_tag) do
    {b, reader} = Wire.read_exact(4, reader)
    <<v::little-unsigned-integer-size(32)>> = b
    {Model.new_u64(v), reader}
  end

  defp decode_value_from_tag(reader, state, @u64_tag) do
    {v, reader} = Wire.read_u64_le(reader)
    {Model.new_u64(v), reader}
  end

  defp decode_value_from_tag(reader, state, @i8_tag) do
    {b, reader} = Wire.read_u8(reader)
    {Model.new_i64(if(b < 128, do: b, else: b - 256)), reader}
  end

  defp decode_value_from_tag(reader, state, @i16_tag) do
    {b, reader} = Wire.read_exact(2, reader)
    <<v::little-signed-integer-size(16)>> = b
    {Model.new_i64(v), reader}
  end

  defp decode_value_from_tag(reader, state, @i32_tag) do
    {b, reader} = Wire.read_exact(4, reader)
    <<v::little-signed-integer-size(32)>> = b
    {Model.new_i64(v), reader}
  end

  defp decode_value_from_tag(reader, state, @i64_tag) do
    {u, reader} = Wire.read_u64_le(reader)
    {Model.new_i64(u), reader}
  end

  defp decode_value_from_tag(reader, state, @bin8_tag) do
    {n, reader} = Wire.read_u8(reader)
    {bin, reader} = Wire.read_exact(n, reader)
    {Model.new_binary(bin), reader}
  end

  defp decode_value_from_tag(reader, state, @bin16_tag) do
    {<<b0, b1>>, reader} = Wire.read_exact(2, reader)
    n = b0 ||| Bitwise.bsl(b1, 8)
    {bin, reader} = Wire.read_exact(n, reader)
    {Model.new_binary(bin), reader}
  end

  defp decode_value_from_tag(reader, state, @bin32_tag) do
    {b, reader} = Wire.read_exact(4, reader)
    <<n::little-unsigned-integer-size(32)>> = b
    {bin, reader} = Wire.read_exact(n, reader)
    {Model.new_binary(bin), reader}
  end

  defp decode_value_from_tag(reader, state, tag) when tag in [@str8_tag, @str16_tag, @str32_tag],
    do: decode_string_tag(reader, state, tag)

  defp decode_value_from_tag(reader, state, @array16_tag) do
    {<<b0, b1>>, reader} = Wire.read_exact(2, reader)
    decode_array_body(reader, state, b0 ||| Bitwise.bsl(b1, 8))
  end

  defp decode_value_from_tag(reader, state, @array32_tag) do
    {b, reader} = Wire.read_exact(4, reader)
    <<n::little-unsigned-integer-size(32)>> = b
    decode_array_body(reader, state, n)
  end

  defp decode_value_from_tag(reader, state, @map16_tag) do
    {<<b0, b1>>, reader} = Wire.read_exact(2, reader)
    decode_map_body(reader, state, b0 ||| Bitwise.bsl(b1, 8))
  end

  defp decode_value_from_tag(reader, state, @map32_tag) do
    {b, reader} = Wire.read_exact(4, reader)
    <<n::little-unsigned-integer-size(32)>> = b
    decode_map_body(reader, state, n)
  end

  defp decode_value_from_tag(reader, state, @str_ref_tag) do
    {ref_id, reader} = Wire.read_varuint(reader)

    if ref_id >= length(state.strings),
      do: raise(Errors.invalid_data("unknown str_ref id"))

    {Model.new_string(Enum.at(state.strings, ref_id)), reader}
  end

  defp decode_value_from_tag(_, _, tag), do: raise(Errors.invalid_tag(tag))

  defp decode_string_tag(reader, state, @str8_tag) do
    {length, reader} = Wire.read_u8(reader)
    read_string_payload(reader, state, length)
  end

  defp decode_string_tag(reader, state, @str16_tag) do
    {<<b0, b1>>, reader} = Wire.read_exact(2, reader)
    read_string_payload(reader, state, b0 ||| Bitwise.bsl(b1, 8))
  end

  defp decode_string_tag(reader, state, @str32_tag) do
    {b, reader} = Wire.read_exact(4, reader)
    <<length::little-unsigned-integer-size(32)>> = b
    read_string_payload(reader, state, length)
  end

  defp read_string_payload(reader, state, length) do
    {raw, reader} = Wire.read_exact(length, reader)
    s = raw
    state = %{state | strings: state.strings ++ [s]}
    {Model.new_string(s), reader}
  end

  defp decode_key(reader, state) do
    {tag, reader} = Wire.read_u8(reader)

    cond do
      tag == @key_ref_tag ->
        {ref_id, reader} = Wire.read_varuint(reader)
        if ref_id >= length(state.keys), do: raise(Errors.invalid_data("unknown key_ref id"))
        {Enum.at(state.keys, ref_id), reader, state}

      tag >= 0x80 and tag <= 0x9F ->
        {key_bytes, reader} = Wire.read_exact(tag &&& 0x1F, reader)
        key = key_bytes
        state = %{state | keys: state.keys ++ [key]}
        {key, reader, state}

      tag in [@str8_tag, @str16_tag, @str32_tag] ->
        {v, reader} = decode_string_tag(reader, state, tag)
        if v.kind != :string, do: raise(Errors.invalid_data("expected string key"))
        state = %{state | keys: state.keys ++ [v.str]}
        {v.str, reader, state}

      true ->
        raise(Errors.invalid_data("map key must be key_ref or string"))
    end
  end

  defp decode_map_body(reader, state, length) do
    reader = Wire.claim_output(reader, length)
    {value, reader} = decode_map_body_inner(Wire.enter_depth(reader), state, length)
    {value, Wire.leave_depth(reader)}
  end

  defp decode_map_body_inner(reader, state, length) do
    {entries, reader, _} =
      Enum.reduce(1..length//1, {[], reader, state}, fn _, {entries, reader, state} ->
        {key, reader, state} = decode_key(reader, state)
        {value, reader} = decode_value(reader, state)
        {entries ++ [Model.entry(key, value)], reader, state}
      end)

    {Model.new_map(entries), reader}
  end

  defp decode_array_body(reader, state, 0), do: {Model.new_array([]), reader}

  defp decode_array_body(reader, state, length) do
    reader = Wire.claim_output(reader, length)
    {value, reader} = decode_array_body_inner(Wire.enter_depth(reader), state, length)
    {value, Wire.leave_depth(reader)}
  end

  defp decode_array_body_inner(reader, state, length) do
    {first_tag, reader} = Wire.read_u8(reader)

    if first_tag == @shape_def_tag do
      {shape_id, reader} = Wire.read_count(reader, 65_535)
      {key_count, reader} = Wire.read_count(reader, 256)

      {keys, reader, state} =
        Enum.reduce(1..key_count//1, {[], reader, state}, fn _, {keys, reader, state} ->
          {key, reader, state} = decode_key(reader, state)
          {keys ++ [key], reader, state}
        end)

      shapes =
        state.shapes
        |> Enum.map(& &1)
        |> then(fn shapes ->
          pad = max(0, shape_id + 1 - length(shapes))
          shapes ++ List.duplicate(nil, pad)
        end)
        |> List.replace_at(shape_id, keys)

      state = %{state | shapes: shapes}

      {values, reader} =
        Enum.reduce(1..length//1, {[], reader}, fn _, {values, reader} ->
          reader = Wire.claim_output(reader, Kernel.length(keys))

          {row_entries, reader, state} =
            Enum.reduce(keys, {[], reader, state}, fn key, {row, reader, state} ->
              {value, reader} = decode_value(reader, state)
              {row ++ [Model.entry(key, value)], reader, state}
            end)

          {values ++ [Model.new_map(row_entries)], reader}
        end)

      {Model.new_array(values), reader}
    else
      {first, reader} = decode_value_from_tag(reader, state, first_tag)

      {rest, reader} =
        Enum.reduce(1..(length - 1)//1, {[], reader}, fn _, {acc, reader} ->
          {v, reader} = decode_value(reader, state)
          {acc ++ [v], reader}
        end)

      {Model.new_array([first | rest]), reader}
    end
  end
end
