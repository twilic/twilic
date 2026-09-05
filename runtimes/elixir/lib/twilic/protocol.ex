defmodule Twilic.Protocol do
  @moduledoc false
  alias Twilic.Codec
  alias Twilic.Errors
  alias Twilic.Model
  alias Twilic.Model.{BaseRef, Column, Message, StatePatchMessage, TemplateBatchMessage, Value}
  alias Twilic.ProtocolHelpers
  alias Twilic.Session
  alias Twilic.Wire

  defmodule TwilicCodec do
    defstruct state: Session.new_state()

    def new(opts \\ nil) do
      state =
        case opts do
          nil -> Session.new_state()
          opts when is_map(opts) -> Session.new_state(opts)
        end

      %__MODULE__{state: state}
    end

    def encode_message(%__MODULE__{} = codec, %Message{} = message) do
      write_message(message, <<>>, codec)
    end

    def decode_message(%__MODULE__{} = codec, data) do
      reader = Wire.new_reader(data)
      {msg, reader, codec} = read_message(reader, codec)

      if Wire.is_eof?(reader),
        do: :ok,
        else: raise(Errors.invalid_data("trailing bytes in message"))

      codec = update_state_after_decode(codec, msg, byte_size(data))
      {codec, msg}
    end

    def encode_value(codec, value) do
      {_codec, data} = encode_value_pair(codec, value)
      data
    end

    def encode_value_pair(codec, value) do
      msg = message_for_value(codec, value) |> msg_map_to_message()
      data = encode_message(codec, msg)
      codec = put_previous_message(codec, msg, byte_size(data))
      {codec, data}
    end

    def msg_map_to_message(%{kind: k} = m) do
      fields =
        m
        |> Map.drop([:kind])
        |> Enum.filter(fn {_key, v} -> v != nil end)
        |> Enum.map(fn
          {:typed_vector, tv} -> {:typed_vector, normalize_typed_vector(tv)}
          other -> other
        end)

      Model.message(k, fields)
    end

    defp normalize_typed_vector(%{element_type: et, codec: c, data: data}) do
      %{
        element_type: et,
        codec: c,
        data: normalize_typed_vector_data(data)
      }
    end

    defp normalize_typed_vector_data(%{kind: :bool, bools: bools}),
      do: %Model.TypedVectorData{kind: 0, bools: bools}

    defp normalize_typed_vector_data(%{kind: :i64, i64s: i64s}),
      do: %Model.TypedVectorData{kind: 1, i64s: i64s}

    defp normalize_typed_vector_data(%{kind: :u64, u64s: u64s}),
      do: %Model.TypedVectorData{kind: 2, u64s: u64s}

    defp normalize_typed_vector_data(%Model.TypedVectorData{} = d), do: d

    def decode_value(codec, data) do
      {codec, value} = decode_value_pair(codec, data)
      value
    end

    def decode_value_pair(codec, data) do
      {codec, msg} = decode_message(codec, data)
      value = message_to_value(codec, msg)
      codec = put_previous_message(codec, msg, byte_size(data))
      {codec, value}
    end

    def message_for_value(codec, %Value{kind: :array, arr: arr}) do
      case try_make_typed_vector(arr) do
        {:ok, tv} -> %{kind: 5, typed_vector: tv}
        :error -> %{kind: 1, array: Enum.map(arr, &Model.clone/1)}
      end
    end

    def message_for_value(codec, %Value{kind: :map, map: map}) do
      keys = Enum.map(map, & &1.key)

      case Session.ShapeTable.get_id(codec.state.shape_table, keys) do
        {shape_id, true} -> shaped_message(codec, shape_id, map)
        _ -> map_message(codec, map)
      end
    end

    def message_for_value(_codec, value), do: %{kind: 0, scalar: Model.clone(value)}

    defp update_state_after_decode(codec, %Message{kind: 10, state_patch: sp}, size) do
      try do
        reconstructed =
          ProtocolHelpers.apply_state_patch(codec.state, sp.base_ref, sp.operations, sp.literals)

        %{
          codec
          | state: %{codec.state | previous_message: reconstructed, previous_message_size: size}
        }
      rescue
        e ->
          case e do
            %Errors.TwilicError{kind: :err_unknown_reference} -> reraise e, __STACKTRACE__
            _ -> codec
          end
      end
    end

    defp update_state_after_decode(codec, %Message{kind: 11, template_batch: tb}, _size) do
      full_cols =
        case Map.get(codec.state.template_columns, tb.template_id) do
          nil ->
            if Enum.all?(tb.changed_column_mask, & &1),
              do: tb.columns,
              else: raise(Errors.unknown_reference("template_id", tb.template_id))

          prev ->
            ProtocolHelpers.merge_template_columns(prev, tb.changed_column_mask, tb.columns)
        end

      state = %{
        codec.state
        | template_columns: Map.put(codec.state.template_columns, tb.template_id, full_cols),
          templates:
            Map.put(
              codec.state.templates,
              tb.template_id,
              ProtocolHelpers.template_descriptor_from_columns(tb.template_id, full_cols)
            )
      }

      %{codec | state: state}
    end

    defp update_state_after_decode(codec, msg, size) do
      cloned = Model.message(msg.kind, message_fields_map(msg))
      %{codec | state: %{codec.state | previous_message: cloned, previous_message_size: size}}
    end

    defp message_fields_map(%{kind: 0, scalar: s}), do: [scalar: s]
    defp message_fields_map(%{kind: 1, array: a}), do: [array: a]
    defp message_fields_map(%{kind: 2, map: m}), do: [map: m]
    defp message_fields_map(%{kind: 3, shaped_object: so}), do: [shaped_object: so]
    defp message_fields_map(%{kind: 4, schema_object: so}), do: [schema_object: so]
    defp message_fields_map(%{kind: 5, typed_vector: tv}), do: [typed_vector: tv]
    defp message_fields_map(%{kind: 6, row_batch: rb}), do: [row_batch: rb]
    defp message_fields_map(%{kind: 10, state_patch: sp}), do: [state_patch: sp]
    defp message_fields_map(%{kind: 11, template_batch: tb}), do: [template_batch: tb]
    defp message_fields_map(%{kind: 13, base_snapshot: bs}), do: [base_snapshot: bs]
    defp message_fields_map(_), do: []

    defp message_to_value(codec, %Message{kind: 0, scalar: scalar}), do: scalar
    defp message_to_value(codec, %Message{kind: 1, array: array}), do: Model.new_array(array)

    defp message_to_value(codec, %Message{kind: 2, map: map}),
      do: Model.new_map(ProtocolHelpers.entries_to_map(map))

    defp message_to_value(codec, %Message{
           kind: 3,
           shaped_object: %{shape_id: sid, values: values}
         }) do
      {keys, true} = Session.ShapeTable.get_keys(codec.state.shape_table, sid)
      entries = Enum.zip(keys, values) |> Enum.map(fn {k, v} -> Model.entry(k, v) end)
      Model.new_map(entries)
    end

    defp message_to_value(_codec, %Message{kind: 5, typed_vector: tv}),
      do: ProtocolHelpers.typed_vector_to_value(tv)

    defp message_to_value(codec, %Message{kind: 10, state_patch: sp}) do
      msg =
        ProtocolHelpers.apply_state_patch(codec.state, sp.base_ref, sp.operations, sp.literals)

      message_to_value(codec, msg)
    end

    defp message_to_value(codec, msg),
      do: message_to_value(codec, normalize_decoded_message(codec, msg))

    defp normalize_decoded_message(_codec, %Message{kind: kind} = msg)
         when kind in [0, 1, 2, 3, 5], do: msg

    defp normalize_decoded_message(codec, %Message{kind: 11, template_batch: tb}) do
      full_cols =
        case Map.get(codec.state.template_columns, tb.template_id) do
          nil ->
            if Enum.all?(tb.changed_column_mask, & &1),
              do: tb.columns,
              else: raise(Errors.unknown_reference("template_id", tb.template_id))

          prev ->
            ProtocolHelpers.merge_template_columns(prev, tb.changed_column_mask, tb.columns)
        end

      Model.message(6, row_batch: %{rows: columns_to_rows(full_cols, tb.count)})
    end

    defp normalize_decoded_message(_, msg),
      do:
        raise(
          Errors.invalid_data(
            "decode_value expects scalar/array/map/vector message: kind #{msg.kind}"
          )
        )

    defp columns_to_rows(columns, count) do
      Enum.map(0..(count - 1), fn row_idx ->
        Enum.map(columns, fn col -> column_value_at(col, row_idx) end)
      end)
    end

    defp column_value_at(%Column{values: %{kind: 1, i64s: data}}, idx),
      do: Model.new_i64(Enum.at(data, idx))

    defp column_value_at(%Column{values: %{kind: 2, u64s: data}}, idx),
      do: Model.new_u64(Enum.at(data, idx))

    defp column_value_at(%Column{values: %{kind: 4, strings: data}}, idx),
      do: Model.new_string(Enum.at(data, idx))

    defp column_value_at(%Column{values: %{kind: 0, bools: data}}, idx),
      do: Model.new_bool(Enum.at(data, idx))

    defp column_value_at(_, _), do: Model.new_null()

    defp put_previous_message(codec, %Message{} = msg, size) do
      cloned = Model.clone_message(msg)
      %{codec | state: %{codec.state | previous_message: cloned, previous_message_size: size}}
    end

    defp map_message(codec, entries) do
      map_entries =
        Enum.map(entries, fn %{key: key, value: value} ->
          {ref_id, ok} = Session.InternTable.get_id(codec.state.key_table, key)
          key_ref = if ok, do: Model.key_id(ref_id), else: Model.key_literal(key)

          {key_table, _} =
            if ok,
              do: {codec.state.key_table, ref_id},
              else: Session.InternTable.register(codec.state.key_table, key)

          codec = %{codec | state: %{codec.state | key_table: key_table}}
          %{key: key_ref, value: Model.clone(value), _codec: codec}
        end)

      # Note: key table updates discarded in current encode path for simplicity
      %{kind: 2, map: Enum.map(map_entries, fn e -> Map.drop(e, [:_codec]) end)}
    end

    defp shaped_message(codec, shape_id, entries) do
      {keys, _} = Session.ShapeTable.get_keys(codec.state.shape_table, shape_id)
      index = Map.new(entries, fn %{key: k, value: v} -> {k, v} end)

      values =
        Enum.map(keys, fn k ->
          case Map.get(index, k) do
            nil -> Model.new_null()
            v -> Model.clone(v)
          end
        end)

      %{kind: 3, shaped_object: %{shape_id: shape_id, values: values}}
    end

    defp try_make_typed_vector(values) when length(values) < 4, do: :error

    defp try_make_typed_vector(values) do
      cond do
        Enum.all?(values, &(&1.kind == :u64)) ->
          {:ok,
           %{
             element_type: :u64,
             codec: :direct_bitpack,
             data: %{kind: :u64, u64s: Enum.map(values, & &1.u64)}
           }}

        Enum.all?(values, &(&1.kind == :bool)) ->
          {:ok,
           %{
             element_type: :bool,
             codec: :direct_bitpack,
             data: %{kind: :bool, bools: Enum.map(values, & &1.bool)}
           }}

        true ->
          :error
      end
    end

    defp write_message(%Message{kind: 0, scalar: scalar}, acc, codec) do
      acc = acc <> <<0>>
      write_value(scalar, acc, codec)
    end

    defp write_message(%Message{kind: 1, array: array}, acc, codec) do
      acc = acc <> <<1>> <> Wire.encode_varuint(length(array))
      Enum.reduce(array, acc, fn v, acc -> write_value(v, acc, codec) end)
    end

    defp write_message(%Message{kind: 2, map: map}, acc, codec) do
      acc = acc <> <<2>> <> Wire.encode_varuint(length(map))

      Enum.reduce(map, acc, fn %{key: key, value: value}, acc ->
        acc = write_key_ref(key, acc, codec)
        write_value(value, acc, codec)
      end)
    end

    defp write_message(%Message{kind: 3, shaped_object: so}, acc, codec) do
      acc =
        acc
        |> Kernel.<>(<<3>>)
        |> Kernel.<>(Wire.encode_varuint(so.shape_id))
        |> Kernel.<>(<<0>>)
        |> Kernel.<>(Wire.encode_varuint(length(so.values)))

      Enum.reduce(so.values, acc, fn v, acc -> write_value(v, acc, codec) end)
    end

    defp write_message(%Message{kind: 4, schema_object: so}, acc, codec) do
      acc =
        acc
        |> Kernel.<>(<<4>>)
        |> Kernel.<>(Wire.encode_varuint(so.schema_id))
        |> Kernel.<>(if(so.has_presence, do: <<1>>, else: <<0>>))

      acc =
        if so.has_presence do
          Wire.encode_bitmap(so.presence, acc)
        else
          acc
        end

      acc = acc <> Wire.encode_varuint(length(so.fields))
      Enum.reduce(so.fields, acc, fn v, acc -> write_value(v, acc, codec) end)
    end

    defp write_message(%Message{kind: 5, typed_vector: tv}, acc, _codec) do
      acc = acc <> <<5>>
      write_typed_vector(tv, acc)
    end

    defp write_message(%Message{kind: 6, row_batch: %{rows: rows}}, acc, codec) do
      acc = acc <> <<6>> <> Wire.encode_varuint(length(rows))

      Enum.reduce(rows, acc, fn row, acc ->
        acc = acc <> Wire.encode_varuint(length(row))
        Enum.reduce(row, acc, fn v, acc -> write_value(v, acc, codec) end)
      end)
    end

    defp write_message(%Message{kind: 10, state_patch: sp}, acc, codec) do
      acc = acc <> <<10>>
      acc = write_base_ref(sp.base_ref, acc)
      acc = acc <> Wire.encode_varuint(length(sp.operations))

      acc =
        Enum.reduce(sp.operations, acc, fn op, acc ->
          acc = acc <> Wire.encode_varuint(op.field_id) <> <<op.opcode>>

          if op.value do
            acc <> <<1>> <> write_value(op.value, <<>>, codec)
          else
            acc <> <<0>>
          end
        end)

      (acc <> Wire.encode_varuint(length(sp.literals)))
      |> then(fn acc ->
        Enum.reduce(sp.literals, acc, fn lit, acc -> write_value(lit, acc, codec) end)
      end)
    end

    defp write_message(%Message{kind: 11, template_batch: tb}, acc, codec) do
      acc =
        acc
        |> Kernel.<>(<<11>>)
        |> Kernel.<>(Wire.encode_varuint(tb.template_id))
        |> Kernel.<>(Wire.encode_varuint(tb.count))
        |> then(&Wire.encode_bitmap(tb.changed_column_mask, &1))
        |> Kernel.<>(Wire.encode_varuint(length(tb.columns)))

      Enum.reduce(tb.columns, acc, fn col, acc -> write_column(col, acc, codec) end)
    end

    defp write_message(%Message{kind: 13, base_snapshot: bs}, acc, codec) do
      acc =
        acc
        |> Kernel.<>(<<13>>)
        |> Kernel.<>(Wire.encode_varuint(bs.base_id))
        |> Kernel.<>(Wire.encode_varuint(bs.schema_or_shape_ref))

      write_message(bs.payload, acc, codec)
    end

    defp write_base_ref(%BaseRef{previous: true}, acc), do: acc <> <<0>>

    defp write_base_ref(%BaseRef{previous: false, base_id: id}, acc),
      do: acc <> <<1>> <> Wire.encode_varuint(id)

    defp write_column(%Column{} = column, acc, codec) do
      acc = acc <> Wire.encode_varuint(column.field_id) <> <<column.null_strategy>>

      acc =
        if column.null_strategy in [1, 2] do
          if column.has_presence && column.presence,
            do: Wire.encode_bitmap(column.presence, acc),
            else: raise(Errors.invalid_data("missing column presence bitmap"))
        else
          acc
        end

      acc = acc <> <<column.codec>> <> <<0>> <> <<0>>

      tv = %{
        element_type: column_element_atom(column.values.kind),
        codec: vector_codec_atom(column.codec),
        data: column.values
      }

      write_typed_vector(tv, acc)
    end

    defp column_element_atom(0), do: :bool
    defp column_element_atom(1), do: :i64
    defp column_element_atom(2), do: :u64
    defp column_element_atom(4), do: :string
    defp column_element_atom(_), do: :value

    defp vector_codec_atom(0), do: :plain
    defp vector_codec_atom(1), do: :direct_bitpack
    defp vector_codec_atom(2), do: :delta_bitpack
    defp vector_codec_atom(3), do: :for_bitpack
    defp vector_codec_atom(4), do: :delta_for_bitpack
    defp vector_codec_atom(5), do: :delta_delta_bitpack
    defp vector_codec_atom(6), do: :rle
    defp vector_codec_atom(7), do: :patched_for
    defp vector_codec_atom(8), do: :simple8b
    defp vector_codec_atom(9), do: :xor_float
    defp vector_codec_atom(10), do: :dictionary
    defp vector_codec_atom(11), do: :string_ref
    defp vector_codec_atom(12), do: :prefix_delta
    defp vector_codec_atom(:plain), do: :plain
    defp vector_codec_atom(:direct_bitpack), do: :direct_bitpack
    defp vector_codec_atom(:delta_bitpack), do: :delta_bitpack
    defp vector_codec_atom(:for_bitpack), do: :for_bitpack
    defp vector_codec_atom(:delta_for_bitpack), do: :delta_for_bitpack
    defp vector_codec_atom(:delta_delta_bitpack), do: :delta_delta_bitpack
    defp vector_codec_atom(:rle), do: :rle
    defp vector_codec_atom(:patched_for), do: :patched_for
    defp vector_codec_atom(:simple8b), do: :simple8b
    defp vector_codec_atom(:xor_float), do: :xor_float
    defp vector_codec_atom(:dictionary), do: :dictionary
    defp vector_codec_atom(:string_ref), do: :string_ref
    defp vector_codec_atom(:prefix_delta), do: :prefix_delta
    defp vector_codec_atom(other), do: other

    defp write_value(%Value{kind: :null}, acc, _), do: acc <> <<0>>
    defp write_value(%Value{kind: :bool, bool: b}, acc, _), do: acc <> <<if(b, do: 2, else: 1)>>

    defp write_value(%Value{kind: :i64, i64: n}, acc, _) do
      acc = acc <> <<3>>
      ProtocolHelpers.write_smallest_u64(Wire.encode_zigzag(n), acc)
    end

    defp write_value(%Value{kind: :u64, u64: n}, acc, _) do
      acc = acc <> <<4>>
      ProtocolHelpers.write_smallest_u64(n, acc)
    end

    defp write_value(%Value{kind: :f64, f64: n}, acc, _) do
      acc = acc <> <<5>>
      Wire.append_f64_le(acc, n)
    end

    defp write_value(%Value{kind: :string, str: s}, acc, codec) do
      acc = acc <> <<6, 1>>
      acc = Wire.encode_string(s, acc)
      {string_table, _} = Session.InternTable.register(codec.state.string_table, s)
      _ = string_table
      acc
    end

    defp write_value(%Value{kind: :binary, bin: bin}, acc, _),
      do: Wire.encode_bytes(bin, acc <> <<7>>)

    defp write_value(%Value{kind: :array, arr: arr}, acc, codec) do
      acc = acc <> <<8>> <> Wire.encode_varuint(length(arr))
      Enum.reduce(arr, acc, fn v, acc -> write_value(v, acc, codec) end)
    end

    defp write_value(%Value{kind: :map, map: map}, acc, codec) do
      acc = acc <> <<9>> <> Wire.encode_varuint(length(map))

      Enum.reduce(map, acc, fn %{key: key, value: value}, acc ->
        acc = write_key_ref(Model.key_literal(key), acc, codec)
        write_value(value, acc, codec)
      end)
    end

    defp write_key_ref(%{is_id: true, id: id}, acc, _),
      do: acc <> <<1>> <> Wire.encode_varuint(id)

    defp write_key_ref(%{literal: literal, is_id: false}, acc, _codec) when is_binary(literal) do
      acc <> <<0>> <> Wire.encode_varuint(byte_size(literal)) <> literal
    end

    defp write_typed_vector(%{element_type: :bool, codec: codec, data: data}, acc) do
      acc = acc <> <<0>> <> Wire.encode_varuint(length(data.bools)) <> <<codec_index(codec)>>
      Wire.encode_bitmap(data.bools, acc)
    end

    defp write_typed_vector(%{element_type: :i64, codec: codec, data: data}, acc) do
      acc = acc <> <<1>> <> Wire.encode_varuint(length(data.i64s)) <> <<codec_index(codec)>>
      Codec.encode_i64_vector(data.i64s, codec, acc)
    end

    defp write_typed_vector(%{element_type: :u64, codec: codec, data: data}, acc) do
      acc = acc <> <<2>> <> Wire.encode_varuint(length(data.u64s)) <> <<codec_index(codec)>>
      Codec.encode_u64_vector(data.u64s, codec, acc)
    end

    defp write_typed_vector(%{element_type: :string, codec: :plain, data: data}, acc) do
      acc =
        acc
        |> Kernel.<>(<<4>>)
        |> Kernel.<>(Wire.encode_varuint(length(data.strings)))
        |> Kernel.<>(<<0>>)
        |> Kernel.<>(Wire.encode_varuint(length(data.strings)))

      Enum.reduce(data.strings, acc, fn s, acc -> Wire.encode_string(s, acc) end)
    end

    defp codec_index(:plain), do: 0
    defp codec_index(:direct_bitpack), do: 1
    defp codec_index(:delta_bitpack), do: 2
    defp codec_index(:for_bitpack), do: 3
    defp codec_index(n) when is_integer(n), do: n

    defp read_message(reader, codec) do
      {value, reader, codec} = read_message_inner(Wire.enter_depth(reader), codec)
      {value, Wire.leave_depth(reader), codec}
    end

    defp read_message_inner(reader, codec) do
      {kind_byte, reader} = Wire.read_u8(reader)

      case Model.message_kind_from_byte(kind_byte) do
        {:ok, 0} ->
          {scalar, reader, codec} = read_value(reader, codec)
          {Model.message(0, scalar: scalar), reader, codec}

        {:ok, 1} ->
          {n, reader} = Wire.read_count(reader)
          {array, reader, codec} = read_value_list(n, [], reader, codec)
          {Model.message(1, array: array), reader, codec}

        {:ok, 2} ->
          {n, reader} = Wire.read_count(reader)
          {map, reader, codec} = read_map_entries(n, [], reader, codec)
          {Model.message(2, map: map), reader, codec}

        {:ok, 3} ->
          {shape_id, reader} = Wire.read_count(reader, 65_535)
          {_, reader} = Wire.read_u8(reader)
          {n, reader} = Wire.read_count(reader)
          {values, reader, codec} = read_value_list(n, [], reader, codec)
          {Model.message(3, shaped_object: %{shape_id: shape_id, values: values}), reader, codec}

        {:ok, 4} ->
          {schema_id, reader} = Wire.read_varuint(reader)
          {flag, reader} = Wire.read_u8(reader)
          has_presence = flag == 1
          {presence, reader} = if has_presence, do: Wire.read_bitmap(reader), else: {nil, reader}
          {n, reader} = Wire.read_count(reader)
          {fields, reader, codec} = read_value_list(n, [], reader, codec)

          {Model.message(4,
             schema_object: %{
               schema_id: schema_id,
               presence: presence,
               has_presence: has_presence,
               fields: fields
             }
           ), reader, codec}

        {:ok, 5} ->
          {tv, reader} = read_typed_vector(reader)
          {Model.message(5, typed_vector: tv), reader, codec}

        {:ok, 6} ->
          {row_count, reader} = Wire.read_count(reader)
          {rows, reader, codec} = read_rows(row_count, [], reader, codec)
          {Model.message(6, row_batch: %{rows: rows}), reader, codec}

        {:ok, 10} ->
          {sp, reader, codec} = read_state_patch(reader, codec)
          {Model.message(10, state_patch: sp), reader, codec}

        {:ok, 11} ->
          {tb, reader, codec} = read_template_batch(reader, codec)
          {Model.message(11, template_batch: tb), reader, codec}

        {:ok, 12} ->
          {codec_byte, reader} = Wire.read_u8(reader)
          cs_codec = control_stream_codec_from_byte(codec_byte)
          {encoded, reader} = Wire.read_bytes(reader)
          payload = Twilic.ControlStream.decode_payload(cs_codec, encoded)

          {Model.message(12, control_stream: %{codec: cs_codec, payload: payload}), reader, codec}

        {:ok, 13} ->
          {bs, reader, codec} = read_base_snapshot(reader, codec)
          {Model.message(13, base_snapshot: bs), reader, codec}

        :error ->
          raise Errors.invalid_kind(kind_byte)
      end
    end

    defp read_state_patch(reader, codec) do
      {base_ref, reader} = read_base_ref(reader)
      {n, reader} = Wire.read_count(reader)
      {ops, reader, codec} = read_patch_ops(n, [], reader, codec)
      {lit_n, reader} = Wire.read_count(reader)
      {lits, reader, codec} = read_value_list(lit_n, [], reader, codec)
      {%StatePatchMessage{base_ref: base_ref, operations: ops, literals: lits}, reader, codec}
    end

    defp read_patch_ops(0, acc, reader, codec), do: {Enum.reverse(acc), reader, codec}

    defp read_patch_ops(n, acc, reader, codec) do
      {field_id, reader} = Wire.read_varuint(reader)
      {op_byte, reader} = Wire.read_u8(reader)
      opcode = Model.patch_opcode_from_byte(op_byte)
      if opcode == nil, do: raise(Errors.invalid_data("patch opcode"))
      {has_value, reader} = Wire.read_u8(reader)

      {value, reader, codec} =
        if has_value == 1 do
          read_value(reader, codec)
        else
          {nil, reader, codec}
        end

      op = %Model.PatchOperation{field_id: field_id, opcode: opcode, value: value}
      read_patch_ops(n - 1, [op | acc], reader, codec)
    end

    defp read_base_ref(reader) do
      {mode, reader} = Wire.read_u8(reader)

      case mode do
        0 ->
          {%BaseRef{previous: true, base_id: 0}, reader}

        1 ->
          {id, reader} = Wire.read_varuint(reader)
          {%BaseRef{previous: false, base_id: id}, reader}

        _ ->
          raise(Errors.invalid_data("base ref"))
      end
    end

    defp read_template_batch(reader, codec) do
      {template_id, reader} = Wire.read_varuint(reader)
      {count, reader} = Wire.read_count(reader)
      {mask, reader} = Wire.read_bitmap(reader)
      {col_n, reader} = Wire.read_count(reader)
      {changed_cols, reader, codec} = read_columns(col_n, [], reader, codec)

      {%TemplateBatchMessage{
         template_id: template_id,
         count: count,
         changed_column_mask: mask,
         columns: changed_cols
       }, reader, codec}
    end

    defp read_base_snapshot(reader, codec) do
      {base_id, reader} = Wire.read_varuint(reader)
      {schema_or_shape_ref, reader} = Wire.read_varuint(reader)
      {payload, reader, codec} = read_message(reader, codec)
      state = Session.register_base_snapshot(codec.state, base_id, payload)

      {%Model.BaseSnapshotMessage{
         base_id: base_id,
         schema_or_shape_ref: schema_or_shape_ref,
         payload: payload
       }, reader, %{codec | state: state}}
    end

    defp read_columns(0, acc, reader, codec), do: {Enum.reverse(acc), reader, codec}

    defp read_columns(n, acc, reader, codec) do
      {col, reader} = read_column(reader, codec)
      read_columns(n - 1, [col | acc], reader, codec)
    end

    defp read_column(reader, _codec) do
      {field_id, reader} = Wire.read_varuint(reader)
      {null_byte, reader} = Wire.read_u8(reader)
      null_strategy = Model.null_strategy_from_byte(null_byte)
      if null_strategy == nil, do: raise(Errors.invalid_data("null strategy"))

      {presence, has_presence, reader} =
        if null_strategy in [1, 2] do
          {bits, reader} = Wire.read_bitmap(reader)
          {bits, true, reader}
        else
          {nil, false, reader}
        end

      {codec_byte, reader} = Wire.read_u8(reader)
      codec = Model.vector_codec_from_byte(codec_byte)
      if codec == nil, do: raise(Errors.invalid_data("column codec"))
      {has_dict, reader} = Wire.read_u8(reader)
      if has_dict != 0, do: raise(Errors.invalid_data("dictionary not supported in elixir port"))
      {payload_mode, reader} = Wire.read_u8(reader)

      if payload_mode != 0,
        do: raise(Errors.invalid_data("trained dictionary block not supported"))

      {tv, reader} = read_typed_vector_for_column(reader, codec)

      col = %Column{
        field_id: field_id,
        null_strategy: null_strategy,
        presence: presence,
        has_presence: has_presence,
        codec: codec,
        dictionary_id: nil,
        values: tv.data
      }

      {col, reader}
    end

    defp read_typed_vector_for_column(reader, expected_codec) do
      {elem_byte, reader} = Wire.read_u8(reader)
      elem = Model.element_type_from_byte(elem_byte)
      if elem == nil, do: raise(Errors.invalid_data("vector element type"))
      {expected_len, reader} = Wire.read_count(reader)
      {codec_byte, reader} = Wire.read_u8(reader)
      if codec_byte != expected_codec, do: raise(Errors.invalid_data("column codec mismatch"))
      codec = vector_codec_atom(codec_byte)
      read_typed_vector_body(elem, expected_len, codec, reader)
    end

    defp read_typed_vector_body(0, expected_len, codec, reader) do
      {bools, reader} = Wire.read_bitmap(reader)

      if length(bools) != expected_len,
        do: raise(Errors.invalid_data("typed vector length mismatch"))

      {%{element_type: :bool, codec: codec, data: %Model.TypedVectorData{kind: 0, bools: bools}},
       reader}
    end

    defp read_typed_vector_body(1, expected_len, codec, reader) do
      {i64s, reader} = Codec.decode_i64_vector(reader, codec)

      if length(i64s) != expected_len,
        do: raise(Errors.invalid_data("typed vector length mismatch"))

      {%{element_type: :i64, codec: codec, data: %Model.TypedVectorData{kind: 1, i64s: i64s}},
       reader}
    end

    defp read_typed_vector_body(2, expected_len, codec, reader) do
      {u64s, reader} = Codec.decode_u64_vector(reader, codec)

      if length(u64s) != expected_len,
        do: raise(Errors.invalid_data("typed vector length mismatch"))

      {%{element_type: :u64, codec: codec, data: %Model.TypedVectorData{kind: 2, u64s: u64s}},
       reader}
    end

    defp read_typed_vector_body(4, expected_len, :plain, reader) do
      {n, reader} = Wire.read_count(reader)
      if n != expected_len, do: raise(Errors.invalid_data("typed vector length mismatch"))
      {strings, reader} = read_plain_strings(n, [], reader)

      {%{
         element_type: :string,
         codec: :plain,
         data: %Model.TypedVectorData{kind: 4, strings: strings}
       }, reader}
    end

    defp read_plain_strings(0, acc, reader), do: {Enum.reverse(acc), reader}

    defp read_plain_strings(n, acc, reader) when n > 0 do
      {s, reader} = Wire.read_string(reader)
      read_plain_strings(n - 1, [s | acc], reader)
    end

    defp read_rows(0, acc, reader, codec), do: {Enum.reverse(acc), reader, codec}

    defp read_rows(n, acc, reader, codec) do
      {field_count, reader} = Wire.read_count(reader)
      {row, reader, codec} = read_value_list(field_count, [], reader, codec)
      read_rows(n - 1, [row | acc], reader, codec)
    end

    defp read_map_entries(0, acc, reader, codec), do: {Enum.reverse(acc), reader, codec}

    defp read_map_entries(n, acc, reader, codec) do
      {key, reader, codec} = read_key_ref(reader, codec)
      field = key_ref_field_identity(key)
      {value, reader, codec} = read_value(reader, codec, field)
      read_map_entries(n - 1, [%{key: key, value: value} | acc], reader, codec)
    end

    defp read_value_list(0, acc, reader, codec), do: {Enum.reverse(acc), reader, codec}

    defp read_value_list(n, acc, reader, codec) do
      {v, reader, codec} = read_value(reader, codec)
      read_value_list(n - 1, [v | acc], reader, codec)
    end

    defp read_value(reader, codec, field_identity \\ nil) do
      {value, reader, codec} = read_value_inner(Wire.enter_depth(reader), codec, field_identity)
      {value, Wire.leave_depth(reader), codec}
    end

    defp read_value_inner(reader, codec, field_identity) do
      {tag, reader} = Wire.read_u8(reader)

      case tag do
        0 ->
          {Model.new_null(), reader, codec}

        1 ->
          {Model.new_bool(false), reader, codec}

        2 ->
          {Model.new_bool(true), reader, codec}

        3 ->
          {v, reader} = ProtocolHelpers.read_smallest_u64(reader)
          {Model.new_i64(Wire.decode_zigzag(v)), reader, codec}

        4 ->
          {v, reader} = ProtocolHelpers.read_smallest_u64(reader)
          {Model.new_u64(v), reader, codec}

        5 ->
          {d, reader} = Wire.read_f64_le(reader)
          {Model.new_f64(d), reader, codec}

        6 ->
          read_string_value(reader, codec, field_identity)

        7 ->
          {bin, reader} = Wire.read_bytes(reader)
          {Model.new_binary(bin), reader, codec}

        8 ->
          {n, reader} = Wire.read_count(reader)
          read_value_list(n, [], reader, codec)

        9 ->
          {n, reader} = Wire.read_count(reader)
          {entries, reader, codec} = read_map_entries(n, [], reader, codec)

          {Model.new_map(
             Enum.map(entries, fn %{key: %{literal: key}, value: value} ->
               Model.entry(key, value)
             end)
           ), reader, codec}

        _ ->
          raise Errors.invalid_tag(tag)
      end
    end

    defp read_string_value(reader, codec, _field_identity) do
      {mode, reader} = Wire.read_u8(reader)

      case mode do
        0 ->
          {Model.new_string(""), reader, codec}

        1 ->
          {s, reader} = Wire.read_string(reader)
          {string_table, _} = Session.InternTable.register(codec.state.string_table, s)
          codec = %{codec | state: %{codec.state | string_table: string_table}}
          {Model.new_string(s), reader, codec}

        2 ->
          {ref_id, reader} = Wire.read_varuint(reader)
          {s, ok} = Session.InternTable.get_value(codec.state.string_table, ref_id)
          if not ok, do: raise(Errors.unknown_reference("string_id", ref_id))
          {Model.new_string(s), reader, codec}

        3 ->
          {base_id, reader} = Wire.read_varuint(reader)
          {prefix_len, reader} = Wire.read_count(reader)
          {suffix, reader} = Wire.read_string(reader)
          {base, ok} = Session.InternTable.get_value(codec.state.string_table, base_id)
          if not ok, do: raise(Errors.unknown_reference("string_id", base_id))
          if prefix_len > byte_size(base), do: raise(Errors.invalid_data("prefix delta length"))
          s = String.slice(base, 0, prefix_len) <> suffix
          {string_table, _} = Session.InternTable.register(codec.state.string_table, s)
          codec = %{codec | state: %{codec.state | string_table: string_table}}
          {Model.new_string(s), reader, codec}

        _ ->
          raise Errors.invalid_data("string mode")
      end
    end

    defp key_ref_field_identity(%{literal: literal}), do: literal

    defp control_stream_codec_from_byte(0), do: :plain
    defp control_stream_codec_from_byte(1), do: :rle
    defp control_stream_codec_from_byte(2), do: :bitpack
    defp control_stream_codec_from_byte(3), do: :huffman
    defp control_stream_codec_from_byte(4), do: :fse

    defp control_stream_codec_from_byte(_),
      do: raise(Errors.invalid_data("control stream codec"))

    defp read_key_ref(reader, codec) do
      {mode, reader} = Wire.read_u8(reader)

      case mode do
        1 ->
          {ref_id, reader} = Wire.read_varuint(reader)
          {key, ok} = Session.InternTable.get_value(codec.state.key_table, ref_id)
          if not ok, do: raise(Errors.unknown_reference("key_id", ref_id))
          {Model.key_literal(key), reader, codec}

        0 ->
          {s, reader} = Wire.read_string(reader)
          {key_table, _} = Session.InternTable.register(codec.state.key_table, s)
          codec = %{codec | state: %{codec.state | key_table: key_table}}
          {Model.key_literal(s), reader, codec}

        _ ->
          raise(Errors.invalid_data("key ref mode"))
      end
    end

    defp read_typed_vector(reader) do
      {elem_byte, reader} = Wire.read_u8(reader)
      elem = Model.element_type_from_byte(elem_byte)
      if elem == nil, do: raise(Errors.invalid_data("vector element type"))
      {expected_len, reader} = Wire.read_count(reader)
      {codec_byte, reader} = Wire.read_u8(reader)
      codec = vector_codec_atom(codec_byte)
      read_typed_vector_body(elem, expected_len, codec, reader)
    end
  end

  defmodule SessionEncoder do
    defstruct codec: TwilicCodec.new()

    def new(opts \\ nil), do: %__MODULE__{codec: TwilicCodec.new(opts)}

    def encode(%__MODULE__{} = enc, value) do
      msg_map = TwilicCodec.message_for_value(enc.codec, value)
      current = msg_to_message(msg_map)
      codec = enc.codec

      {codec, data} =
        if Map.get(codec.state.options, :enable_state_patch, true) && codec.state.previous_message &&
             ProtocolHelpers.supports_state_patch?(codec.state.previous_message, current) do
          try_patch_encode(codec, msg_map, current)
        else
          full_encode_tuple(codec, msg_map)
        end

      {%{enc | codec: codec}, data}
    end

    defp msg_to_message(m), do: TwilicCodec.msg_map_to_message(m)

    defp try_patch_encode(codec, msg_map, current) do
      {ops, _} = ProtocolHelpers.diff_message(codec.state.previous_message, current)

      patch_msg =
        Model.message(10,
          state_patch: %StatePatchMessage{
            base_ref: %BaseRef{previous: true, base_id: 0},
            operations: ops,
            literals: []
          }
        )

      if ProtocolHelpers.encoded_size(patch_msg) < ProtocolHelpers.encoded_size(current) do
        data = TwilicCodec.encode_message(codec, patch_msg)

        reconstructed =
          ProtocolHelpers.apply_state_patch(
            codec.state,
            %BaseRef{previous: true, base_id: 0},
            ops,
            []
          )

        codec = %{
          codec
          | state: %{
              codec.state
              | previous_message: reconstructed,
                previous_message_size: byte_size(data)
            }
        }

        {codec, data}
      else
        full_encode_tuple(codec, msg_map)
      end
    end

    defp put_previous(codec, msg_map, size) do
      cloned = msg_map |> msg_to_message() |> Model.clone_message()
      %{codec | state: %{codec.state | previous_message: cloned, previous_message_size: size}}
    end

    def encode_with_schema(%__MODULE__{} = enc, schema, %Value{kind: :map} = value) do
      fields =
        Enum.map(schema.fields, fn f ->
          Enum.find_value(value.map, Model.new_null(), fn %{key: k, value: v} ->
            if k == f.name, do: Model.clone(v)
          end)
        end)

      msg = %{
        kind: 4,
        schema_object: %{
          schema_id: schema.schema_id,
          fields: fields,
          presence: nil,
          has_presence: false
        }
      }

      {codec, data} = full_encode_tuple(enc.codec, msg)
      {%{enc | codec: codec}, data}
    end

    def encode_with_schema(_, _, _),
      do: raise(Errors.invalid_data("encode_with_schema expects map value"))

    def encode_batch(%__MODULE__{} = enc, values) do
      rows =
        Enum.map(values, fn
          %Value{kind: :array, arr: arr} -> Enum.map(arr, &Model.clone/1)
          v -> [Model.clone(v)]
        end)

      msg = %{kind: 6, row_batch: %{rows: rows}}
      {codec, data} = full_encode_tuple(enc.codec, msg)
      {%{enc | codec: codec}, data}
    end

    def encode_patch(%__MODULE__{} = enc, value) do
      msg = TwilicCodec.message_for_value(enc.codec, value)
      current = msg_to_message(msg)
      prev = enc.codec.state.previous_message

      if prev == nil or not ProtocolHelpers.supports_state_patch?(prev, current) do
        {codec, data} = full_encode_tuple(enc.codec, msg)
        {%{enc | codec: codec}, data}
      else
        {ops, _} = ProtocolHelpers.diff_message(prev, current)

        patch_msg =
          Model.message(10,
            state_patch: %StatePatchMessage{
              base_ref: %BaseRef{previous: true, base_id: 0},
              operations: ops,
              literals: []
            }
          )

        if ProtocolHelpers.encoded_size(patch_msg) >= ProtocolHelpers.encoded_size(current) do
          {codec, data} = full_encode_tuple(enc.codec, msg)
          {%{enc | codec: codec}, data}
        else
          data = TwilicCodec.encode_message(enc.codec, patch_msg)

          reconstructed =
            ProtocolHelpers.apply_state_patch(
              enc.codec.state,
              %BaseRef{previous: true, base_id: 0},
              ops,
              []
            )

          codec = %{
            enc.codec
            | state: %{
                enc.codec.state
                | previous_message: reconstructed,
                  previous_message_size: byte_size(data)
              }
          }

          {%{enc | codec: codec}, data}
        end
      end
    end

    def encode_micro_batch(%__MODULE__{} = enc, values) do
      if values == [] or not enc.codec.state.options[:enable_template_batch] or
           not ProtocolHelpers.has_uniform_micro_batch_shape?(values) do
        encode_batch(enc, values)
      else
        columns =
          ProtocolHelpers.columns_from_map_values(values) ||
            ProtocolHelpers.rows_to_columns(ProtocolHelpers.rows_from_values(values))

        {template_id, ok} = ProtocolHelpers.find_template_id(enc.codec.state.templates, columns)

        {msg, state} =
          if not ok do
            {template_id, state} = Session.allocate_template_id(enc.codec.state)
            descriptor = ProtocolHelpers.template_descriptor_from_columns(template_id, columns)

            state = %{
              state
              | templates: Map.put(state.templates, template_id, descriptor),
                template_columns: Map.put(state.template_columns, template_id, columns)
            }

            mask = List.duplicate(true, length(columns))

            msg =
              Model.message(11,
                template_batch: %TemplateBatchMessage{
                  template_id: template_id,
                  count: length(values),
                  changed_column_mask: mask,
                  columns: columns
                }
              )

            {msg, state}
          else
            {mask, changed_cols} =
              ProtocolHelpers.diff_template_columns(
                Map.fetch!(enc.codec.state.template_columns, template_id),
                columns
              )

            state = %{
              enc.codec.state
              | template_columns: Map.put(enc.codec.state.template_columns, template_id, columns)
            }

            msg =
              Model.message(11,
                template_batch: %TemplateBatchMessage{
                  template_id: template_id,
                  count: length(values),
                  changed_column_mask: mask,
                  columns: changed_cols
                }
              )

            {msg, state}
          end

        data = TwilicCodec.encode_message(%{enc.codec | state: state}, msg)
        cloned = Model.clone_message(msg)

        codec = %{
          enc.codec
          | state: %{state | previous_message: cloned, previous_message_size: byte_size(data)}
        }

        {%{enc | codec: codec}, data}
      end
    end

    def decode_message(%__MODULE__{} = enc, bytes) do
      {codec, msg} = TwilicCodec.decode_message(enc.codec, bytes)
      {%{enc | codec: codec}, msg}
    end

    defp full_encode_tuple(codec, msg_map) do
      data = TwilicCodec.encode_message(codec, msg_to_message(msg_map))
      codec = put_previous(codec, msg_map, byte_size(data))
      {codec, data}
    end
  end
end
