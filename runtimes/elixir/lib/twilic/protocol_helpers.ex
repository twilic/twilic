defmodule Twilic.ProtocolHelpers do
  @moduledoc false
  import Bitwise
  alias Twilic.Model
  alias Twilic.Model.{Column, Message, PatchOperation, TypedVectorData, Value}
  alias Twilic.Session
  alias Twilic.Wire

  @element_bool 0
  @element_i64 1
  @element_u64 2
  @element_string 4
  @vector_plain 0
  @vector_direct_bitpack 1
  @vector_delta_bitpack 2
  @vector_for_bitpack 3
  @null_all_present 3

  def typed_vector_len(%TypedVectorData{kind: @element_bool, bools: bools}), do: length(bools)
  def typed_vector_len(%TypedVectorData{kind: @element_i64, i64s: i64s}), do: length(i64s)
  def typed_vector_len(%TypedVectorData{kind: @element_u64, u64s: u64s}), do: length(u64s)

  def typed_vector_len(%TypedVectorData{kind: @element_string, strings: strings}),
    do: length(strings)

  def typed_vector_len(%TypedVectorData{kind: 6, values: values}) when is_list(values),
    do: length(values)

  def typed_vector_len(_), do: 0

  def typed_vector_to_value(%{element_type: :bool, data: %{bools: bools}}),
    do: Model.new_array(Enum.map(bools, &Model.new_bool/1))

  def typed_vector_to_value(%{element_type: :i64, data: %{i64s: i64s}}),
    do: Model.new_array(Enum.map(i64s, &Model.new_i64/1))

  def typed_vector_to_value(%{element_type: :u64, data: %{u64s: u64s}}),
    do: Model.new_array(Enum.map(u64s, &Model.new_u64/1))

  def typed_vector_to_value(%{element_type: :string, data: %{strings: strings}}),
    do: Model.new_array(Enum.map(strings, &Model.new_string/1))

  def typed_vector_to_value(_), do: Model.new_array([])

  def entries_to_map(entries) do
    Enum.map(entries, fn %{key: %{literal: key}, value: value} ->
      normalized =
        cond do
          match?(%Value{}, value) -> value
          is_list(value) -> Model.new_array(value)
          true -> value
        end

      Model.entry(key, normalized)
    end)
  end

  def write_smallest_u64(value, acc) when value <= 0xFF,
    do: acc <> <<1, value>>

  def write_smallest_u64(value, acc) when value <= 0xFFFF,
    do: acc <> <<2, value &&& 0xFF, value >>> 8 &&& 0xFF>>

  def write_smallest_u64(value, acc) when value <= 0xFFFFFFFF,
    do:
      acc <>
        <<4, value &&& 0xFF, value >>> 8 &&& 0xFF, value >>> 16 &&& 0xFF, value >>> 24 &&& 0xFF>>

  def write_smallest_u64(value, acc), do: acc |> Kernel.<>(<<8>>) |> Wire.append_u64_le(value)

  def read_smallest_u64(reader) do
    {size, reader} = Wire.read_u8(reader)

    case size do
      1 ->
        Wire.read_u8(reader)

      2 ->
        {<<b0, b1>>, reader} = Wire.read_exact(2, reader)
        {b0 ||| bsl(b1, 8), reader}

      4 ->
        {b, reader} = Wire.read_exact(4, reader)
        <<v::little-unsigned-integer-size(32)>> = b
        {v, reader}

      8 ->
        Wire.read_u64_le(reader)

      _ ->
        raise Twilic.Errors.invalid_data("smallest u64 size")
    end
  end

  def supports_state_patch?(nil, _), do: false

  def supports_state_patch?(%Message{kind: base}, %Message{kind: current}) do
    base == current and base in [1, 2, 3, 4]
  end

  def supports_state_patch?(_, _), do: false

  def message_fields(%Message{kind: 1, array: array}) when is_list(array),
    do: Enum.map(array, &Model.clone/1)

  def message_fields(%Message{kind: 2, map: map}) when is_list(map),
    do: Enum.map(map, fn e -> Model.clone(e.value) end)

  def message_fields(%Message{kind: 3, shaped_object: %{values: values}}) when is_list(values),
    do: Enum.map(values, &Model.clone/1)

  def message_fields(%Message{kind: 4, schema_object: %{fields: fields}}) when is_list(fields),
    do: Enum.map(fields, &Model.clone/1)

  def message_fields(_), do: []

  def diff_message(prev, current) do
    a = message_fields(prev)
    b = message_fields(current)
    n = max(length(a), length(b))

    ops =
      Enum.map(0..(n - 1), fn i ->
        cond do
          i < length(a) and i < length(b) ->
            if Model.equal?(a |> Enum.at(i), b |> Enum.at(i)) do
              %PatchOperation{field_id: i, opcode: Model.patch_keep(), value: nil}
            else
              %PatchOperation{
                field_id: i,
                opcode: Model.patch_replace_scalar(),
                value: Enum.at(b, i)
              }
            end

          i < length(b) ->
            %PatchOperation{field_id: i, opcode: Model.patch_insert_field(), value: Enum.at(b, i)}

          true ->
            %PatchOperation{field_id: i, opcode: Model.patch_delete_field(), value: nil}
        end
      end)

    {ops, []}
  end

  def rebuild_message_like(%Message{kind: 1} = base, fields),
    do: Model.message(1, array: fields)

  def rebuild_message_like(%Message{kind: 2, map: map}, fields) do
    entries =
      Enum.with_index(fields)
      |> Enum.map(fn {value, i} ->
        if i >= length(map), do: raise(Twilic.Errors.invalid_data("patch map shape mismatch"))
        %{key: Enum.at(map, i).key, value: value}
      end)

    Model.message(2, map: entries)
  end

  def rebuild_message_like(%Message{kind: 3, shaped_object: so}, fields),
    do: Model.message(3, shaped_object: %{so | values: fields})

  def rebuild_message_like(%Message{kind: 4, schema_object: so}, fields),
    do: Model.message(4, schema_object: %{so | fields: fields})

  def rebuild_message_like(_, _),
    do: raise(Twilic.Errors.invalid_data("state patch reconstruction unsupported"))

  def apply_state_patch(state, base_ref, operations, _literals) do
    base =
      if base_ref.previous do
        if state.previous_message == nil,
          do: raise(Twilic.Errors.unknown_reference("previous", 0)),
          else: Model.clone_message(state.previous_message)
      else
        case Session.get_base_snapshot(state, base_ref.base_id) do
          {msg, true} -> msg
          _ -> raise(Twilic.Errors.unknown_reference("base_id", base_ref.base_id))
        end
      end

    fields = message_fields(base)

    fields =
      Enum.reduce(operations, fields, fn op, fields ->
        idx = op.field_id

        case op.opcode do
          0 ->
            fields

          opcode when opcode in [1, 2, 6, 7, 8] ->
            if op.value == nil,
              do: raise(Twilic.Errors.invalid_data("patch operation missing value"))

            cond do
              idx < length(fields) -> List.replace_at(fields, idx, Model.clone(op.value))
              idx == length(fields) -> fields ++ [Model.clone(op.value)]
              true -> raise(Twilic.Errors.invalid_data("patch field index out of range"))
            end

          5 ->
            if idx < 0 or idx >= length(fields),
              do: raise(Twilic.Errors.invalid_data("delete field index out of range"))

            List.delete_at(fields, idx)

          _ ->
            fields
        end
      end)

    rebuild_message_like(base, fields)
  end

  def encoded_size(message), do: estimate_message_size(message)

  def estimate_message_size(%Message{kind: 0, scalar: scalar}),
    do: 1 + estimate_value_size(scalar)

  def estimate_message_size(%Message{kind: 1, array: array}),
    do: 1 + varuint_size(length(array)) + Enum.sum(Enum.map(array, &estimate_value_size/1))

  def estimate_message_size(%Message{kind: 2, map: map}) do
    1 + varuint_size(length(map)) +
      Enum.sum(
        Enum.map(map, fn e -> encoded_key_ref_size(e.key) + estimate_value_size(e.value) end)
      )
  end

  def estimate_message_size(%Message{kind: 10, state_patch: sp}) do
    1 + 2 + varuint_size(length(sp.operations)) +
      Enum.sum(
        Enum.map(sp.operations, fn op ->
          varuint_size(op.field_id) + 2 + if(op.value, do: estimate_value_size(op.value), else: 0)
        end)
      )
  end

  def estimate_message_size(_), do: 16

  def estimate_column_size(%Column{} = column) do
    size = varuint_size(column.field_id) + 4

    case column.values.kind do
      @element_bool -> size + div(length(column.values.bools) + 7, 8) + 2
      @element_i64 -> size + length(column.values.i64s) * 4
      @element_u64 -> size + length(column.values.u64s) * 4
      @element_string -> size + Enum.sum(Enum.map(column.values.strings, &encoded_string_size/1))
      _ -> size
    end
  end

  def estimate_value_size(%Value{kind: :null}), do: 1
  def estimate_value_size(%Value{kind: :bool}), do: 1

  def estimate_value_size(%Value{kind: :i64, i64: n}),
    do: 2 + smallest_u64_size(Wire.encode_zigzag(n))

  def estimate_value_size(%Value{kind: :u64, u64: n}), do: 2 + smallest_u64_size(n)
  def estimate_value_size(%Value{kind: :f64}), do: 9
  def estimate_value_size(%Value{kind: :string, str: s}), do: 2 + encoded_string_size(s)

  def estimate_value_size(%Value{kind: :binary, bin: bin}),
    do: 1 + encoded_bytes_size(byte_size(bin))

  def estimate_value_size(%Value{kind: :array, arr: arr}),
    do: 1 + varuint_size(length(arr)) + Enum.sum(Enum.map(arr, &estimate_value_size/1))

  def estimate_value_size(%Value{kind: :map, map: map}) do
    1 + varuint_size(length(map)) +
      Enum.sum(
        Enum.map(map, fn e -> encoded_string_size(e.key) + estimate_value_size(e.value) end)
      )
  end

  def estimate_value_size(_), do: 1

  defp encoded_bytes_size(length), do: varuint_size(length) + length
  defp encoded_string_size(value), do: encoded_bytes_size(byte_size(value))

  defp encoded_key_ref_size(%{is_id: true, id: id}), do: 1 + varuint_size(id)
  defp encoded_key_ref_size(%{literal: literal, is_id: false}), do: encoded_string_size(literal)

  defp varuint_size(value) do
    Stream.unfold(value, fn
      v when v < 0x80 -> nil
      v -> {1, v >>> 7}
    end)
    |> Enum.count()
    |> Kernel.+(1)
  end

  defp smallest_u64_size(value) when value <= 0xFF, do: 1
  defp smallest_u64_size(value) when value <= 0xFFFF, do: 2
  defp smallest_u64_size(value) when value <= 0xFFFFFFFF, do: 4
  defp smallest_u64_size(_), do: 8

  def rows_from_values(values) do
    Enum.map(values, fn
      %Value{kind: :array, arr: arr} -> Enum.map(arr, &Model.clone/1)
      v -> [Model.clone(v)]
    end)
  end

  def rows_to_columns(rows) when rows == [], do: nil

  def rows_to_columns(rows) do
    width = rows |> Enum.map(&length/1) |> Enum.max()

    {column_values, column_presence} =
      Enum.reduce(0..(width - 1), {List.duplicate([], width), List.duplicate([], width)}, fn col,
                                                                                             {vals,
                                                                                              pres} ->
        {new_vals, new_pres} =
          Enum.reduce(rows, {vals, pres}, fn row, {vals, pres} ->
            value = if col < length(row), do: Enum.at(row, col), else: Model.new_null()
            col_vals = Enum.at(vals, col) ++ [Model.clone(value)]
            col_pres = Enum.at(pres, col) ++ [value.kind != :null]
            vals = List.replace_at(vals, col, col_vals)
            pres = List.replace_at(pres, col, col_pres)
            {vals, pres}
          end)

        {new_vals, new_pres}
      end)

    Enum.with_index(column_values)
    |> Enum.map(fn {col_values, field_id} ->
      present_bits = Enum.at(column_presence, field_id)
      {null_strategy, presence, has_presence} = column_null_strategy(col_values, present_bits)
      {codec, tvd} = infer_column_codec_and_values(strip_nulls(col_values))

      %Column{
        field_id: field_id,
        null_strategy: null_strategy,
        presence: presence,
        has_presence: has_presence,
        codec: codec,
        dictionary_id: nil,
        values: tvd
      }
    end)
  end

  def columns_from_map_values(values) when values == [], do: nil

  def columns_from_map_values(values) do
    if Enum.all?(values, &match?(%Value{kind: :map}, &1)) do
      build_columns_from_maps(values)
    else
      nil
    end
  end

  defp build_columns_from_maps(values) do
    key_order = []
    key_index = %{}
    column_values = []
    column_presence = []

    {key_order, key_index, column_values, column_presence} =
      Enum.with_index(values)
      |> Enum.reduce({key_order, key_index, column_values, column_presence}, fn {%Value{map: map},
                                                                                 row_idx},
                                                                                acc ->
        {key_order, key_index, column_values, column_presence} = acc
        present = Map.new(key_order, &{&1, false})

        {key_order, key_index, column_values, column_presence, present} =
          Enum.reduce(map, {key_order, key_index, column_values, column_presence, present}, fn
            %{key: key, value: entry_value}, state ->
              append_map_column(state, key, entry_value, row_idx)
          end)

        fill_missing_map_columns(key_order, key_index, column_values, column_presence, present)
      end)

    Enum.with_index(key_order)
    |> Enum.map(fn {_key, field_id} ->
      col_values = Enum.at(column_values, field_id)
      present_bits = Enum.at(column_presence, field_id)
      {null_strategy, presence, has_presence} = column_null_strategy(col_values, present_bits)
      {codec, tvd} = infer_column_codec_and_values(strip_nulls(col_values))

      %Column{
        field_id: field_id,
        null_strategy: null_strategy,
        presence: presence,
        has_presence: has_presence,
        codec: codec,
        dictionary_id: nil,
        values: tvd
      }
    end)
  end

  defp append_map_column(
         {key_order, key_index, column_values, column_presence, present},
         key,
         entry_value,
         row_idx
       ) do
    case Map.get(key_index, key) do
      nil ->
        idx = length(key_order)
        key_order = key_order ++ [key]
        key_index = Map.put(key_index, key, idx)
        column_values = column_values ++ [List.duplicate(Model.new_null(), row_idx)]
        column_presence = column_presence ++ [List.duplicate(false, row_idx)]

        column_values =
          List.replace_at(
            column_values,
            idx,
            Enum.at(column_values, idx) ++ [Model.clone(entry_value)]
          )

        column_presence =
          List.replace_at(column_presence, idx, Enum.at(column_presence, idx) ++ [true])

        present = Map.put(present, key, true)
        {key_order, key_index, column_values, column_presence, present}

      idx ->
        column_values =
          List.replace_at(
            column_values,
            idx,
            Enum.at(column_values, idx) ++ [Model.clone(entry_value)]
          )

        column_presence =
          List.replace_at(column_presence, idx, Enum.at(column_presence, idx) ++ [true])

        present = Map.put(present, key, true)
        {key_order, key_index, column_values, column_presence, present}
    end
  end

  defp fill_missing_map_columns(key_order, key_index, column_values, column_presence, present) do
    Enum.reduce(key_order, {key_order, key_index, column_values, column_presence}, fn key, acc ->
      if Map.get(present, key) do
        acc
      else
        {ko, ki, cv, cp} = acc
        idx = Map.fetch!(ki, key)

        {ko, ki, List.replace_at(cv, idx, Enum.at(cv, idx) ++ [Model.new_null()]),
         List.replace_at(cp, idx, Enum.at(cp, idx) ++ [false])}
      end
    end)
  end

  def column_null_strategy(values, present_bits) do
    null_count = Enum.count(values, &match?(%Value{kind: :null}, &1))

    if null_count == 0 do
      {@null_all_present, nil, false}
    else
      if null_count <= div(length(values), 4) do
        {2, Enum.map(present_bits, &(!&1)), true}
      else
        {1, present_bits, true}
      end
    end
  end

  def strip_nulls(values), do: Enum.reject(values, &match?(%Value{kind: :null}, &1))

  def infer_column_codec_and_values([]),
    do: {@vector_plain, %TypedVectorData{kind: 6, values: []}}

  def infer_column_codec_and_values(values) do
    cond do
      Enum.all?(values, &match?(%Value{kind: :i64}, &1)) ->
        data = Enum.map(values, & &1.i64)
        {select_integer_codec(data), %TypedVectorData{kind: @element_i64, i64s: data}}

      Enum.all?(values, &match?(%Value{kind: :u64}, &1)) ->
        data = Enum.map(values, & &1.u64)
        {select_u64_codec(data), %TypedVectorData{kind: @element_u64, u64s: data}}

      Enum.all?(values, &match?(%Value{kind: :bool}, &1)) ->
        data = Enum.map(values, & &1.bool)
        {@vector_direct_bitpack, %TypedVectorData{kind: @element_bool, bools: data}}

      Enum.all?(values, &match?(%Value{kind: :string}, &1)) ->
        data = Enum.map(values, & &1.str)
        {@vector_plain, %TypedVectorData{kind: @element_string, strings: data}}

      true ->
        {@vector_plain, %TypedVectorData{kind: 6, values: Enum.map(values, &Model.clone/1)}}
    end
  end

  def has_uniform_micro_batch_shape?([]), do: false

  def has_uniform_micro_batch_shape?([%Value{kind: :map, map: first} | rest]) do
    keys = Enum.map(first, & &1.key)

    Enum.all?(rest, fn %Value{kind: :map, map: map} ->
      length(map) == length(keys) and
        Enum.zip(keys, map) |> Enum.all?(fn {k, e} -> e.key == k end)
    end)
  end

  def has_uniform_micro_batch_shape?(_), do: false

  def select_u64_codec([]), do: @vector_plain

  def select_u64_codec(values) when length(values) < 4, do: @vector_direct_bitpack

  def select_u64_codec(values) do
    if Enum.all?(values, &(&1 <= 0x7FFF_FFFF_FFFF_FFFF)) do
      select_integer_codec(Enum.map(values, & &1))
    else
      spread = Enum.max(values) - Enum.min(values)
      if bit_width_u64(spread) <= 60, do: @vector_for_bitpack, else: @vector_direct_bitpack
    end
  end

  def select_integer_codec(values) when length(values) < 4, do: @vector_plain

  def select_integer_codec(values) do
    spread = Enum.max(values) - Enum.min(values)
    if bit_width_u64(spread) <= 60, do: @vector_for_bitpack, else: @vector_direct_bitpack
  end

  defp bit_width_u64(0), do: 1
  defp bit_width_u64(v) when v > 0, do: trunc(:math.log2(v)) + 1

  def template_descriptor_from_columns(template_id, columns) do
    %Model.TemplateDescriptor{
      template_id: template_id,
      field_ids: Enum.map(columns, & &1.field_id),
      null_strategies: Enum.map(columns, & &1.null_strategy),
      codecs: Enum.map(columns, & &1.codec)
    }
  end

  def find_template_id(templates, columns) do
    templates
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce({0, false}, fn id, default ->
      t = Map.fetch!(templates, id)

      match? =
        length(t.field_ids) == length(columns) and
          Enum.with_index(t.field_ids)
          |> Enum.all?(fn {fid, i} ->
            col = Enum.at(columns, i)
            fid == col.field_id and Enum.at(t.null_strategies, i) == col.null_strategy
          end)

      if match?, do: {id, true}, else: default
    end)
  end

  def diff_template_columns(previous, current) do
    current
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {col, i}, {mask, changed} ->
      changed? =
        i >= length(previous) or
          estimate_column_size(Enum.at(previous, i)) != estimate_column_size(col)

      mask = mask ++ [changed?]
      if changed?, do: {mask, changed ++ [col]}, else: {mask, changed}
    end)
  end

  def merge_template_columns(previous, changed_mask, changed) do
    {out, _idx} =
      Enum.reduce(Enum.with_index(changed_mask), {[], 0}, fn {bit, i}, {out, idx} ->
        if bit do
          col = Enum.at(changed, idx)

          if col == nil,
            do: raise(Twilic.Errors.invalid_data("template changed column count mismatch"))

          {out ++ [col], idx + 1}
        else
          if i >= length(previous),
            do: raise(Twilic.Errors.invalid_data("template reference out of range"))

          {out ++ [Enum.at(previous, i)], idx}
        end
      end)

    out
  end

  def reset_encode_shape_observation(state, keys) do
    sk = Twilic.Session.shape_key(keys)
    %{state | encode_shape_observations: Map.delete(state.encode_shape_observations, sk)}
  end
end
