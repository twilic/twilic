defmodule Twilic.Model do
  @moduledoc false

  @type map_entry :: %{key: String.t(), value: Value.t()}
  @type key_ref :: %{literal: String.t(), id: non_neg_integer(), is_id: boolean()}

  defmodule Value do
    @type t :: %__MODULE__{
            kind: atom(),
            bool: boolean(),
            i64: integer(),
            u64: non_neg_integer(),
            f64: float(),
            str: String.t(),
            bin: binary(),
            arr: [t()],
            map: [Twilic.Model.map_entry()]
          }
    defstruct kind: :null,
              bool: false,
              i64: 0,
              u64: 0,
              f64: 0.0,
              str: "",
              bin: <<>>,
              arr: [],
              map: []
  end

  defmodule Message do
    @type t :: %__MODULE__{
            kind: non_neg_integer(),
            scalar: Value.t() | nil,
            array: [Value.t()] | nil,
            map: [%{key: Twilic.Model.key_ref(), value: Value.t()}] | nil,
            shaped_object: map() | nil,
            schema_object: map() | nil,
            typed_vector: map() | nil,
            row_batch: map() | nil,
            column_batch: map() | nil,
            control: map() | nil,
            ext: map() | nil,
            state_patch: StatePatchMessage.t() | nil,
            template_batch: TemplateBatchMessage.t() | nil,
            control_stream: map() | nil,
            base_snapshot: BaseSnapshotMessage.t() | nil
          }
    defstruct kind: 0,
              scalar: nil,
              array: nil,
              map: nil,
              shaped_object: nil,
              schema_object: nil,
              typed_vector: nil,
              row_batch: nil,
              column_batch: nil,
              control: nil,
              ext: nil,
              state_patch: nil,
              template_batch: nil,
              control_stream: nil,
              base_snapshot: nil
  end

  defmodule BaseRef do
    @type t :: %__MODULE__{previous: boolean(), base_id: non_neg_integer()}
    defstruct previous: true, base_id: 0
  end

  defmodule PatchOperation do
    @type t :: %__MODULE__{
            field_id: non_neg_integer(),
            opcode: non_neg_integer(),
            value: Value.t() | nil
          }
    defstruct field_id: 0, opcode: 0, value: nil
  end

  defmodule StatePatchMessage do
    @type t :: %__MODULE__{
            base_ref: BaseRef.t(),
            operations: [PatchOperation.t()],
            literals: [Value.t()]
          }
    defstruct base_ref: %BaseRef{previous: true, base_id: 0},
              operations: [],
              literals: []
  end

  defmodule TemplateBatchMessage do
    @type t :: %__MODULE__{
            template_id: non_neg_integer(),
            count: non_neg_integer(),
            changed_column_mask: [boolean()],
            columns: [Column.t()]
          }
    defstruct template_id: 0, count: 0, changed_column_mask: [], columns: []
  end

  defmodule BaseSnapshotMessage do
    @type t :: %__MODULE__{
            base_id: non_neg_integer(),
            schema_or_shape_ref: non_neg_integer(),
            payload: Message.t()
          }
    defstruct base_id: 0, schema_or_shape_ref: 0, payload: %Message{}
  end

  defmodule TypedVectorData do
    @type t :: %__MODULE__{
            kind: non_neg_integer(),
            bools: [boolean()],
            i64s: [integer()],
            u64s: [non_neg_integer()],
            f64s: [float()],
            strings: [String.t()],
            binary: [binary()],
            values: [Value.t()] | nil
          }
    defstruct kind: 0,
              bools: [],
              i64s: [],
              u64s: [],
              f64s: [],
              strings: [],
              binary: [],
              values: nil
  end

  defmodule Column do
    @type t :: %__MODULE__{
            field_id: non_neg_integer(),
            null_strategy: non_neg_integer(),
            presence: [boolean()] | nil,
            has_presence: boolean(),
            codec: non_neg_integer(),
            dictionary_id: non_neg_integer() | nil,
            values: TypedVectorData.t()
          }
    defstruct field_id: 0,
              null_strategy: 3,
              presence: nil,
              has_presence: false,
              codec: 0,
              dictionary_id: nil,
              values: %TypedVectorData{}
  end

  defmodule TemplateDescriptor do
    @type t :: %__MODULE__{
            template_id: non_neg_integer(),
            field_ids: [non_neg_integer()],
            null_strategies: [non_neg_integer()],
            codecs: [non_neg_integer()]
          }
    defstruct template_id: 0, field_ids: [], null_strategies: [], codecs: []
  end

  def message(kind, fields \\ []) do
    struct(Message, Keyword.put(fields, :kind, kind))
  end

  def base_ref_previous, do: %BaseRef{previous: true, base_id: 0}
  def base_ref_id(id), do: %BaseRef{previous: false, base_id: id}

  @patch_keep 0
  @patch_replace_scalar 1
  @patch_delete_field 5
  @patch_insert_field 6

  def patch_keep, do: @patch_keep
  def patch_replace_scalar, do: @patch_replace_scalar
  def patch_delete_field, do: @patch_delete_field
  def patch_insert_field, do: @patch_insert_field

  def patch_opcode_from_byte(b) when b in 0..8, do: b
  def patch_opcode_from_byte(_), do: nil

  def null_strategy_from_byte(b) when b in 0..3, do: b
  def null_strategy_from_byte(_), do: nil

  def vector_codec_from_byte(b) when b in 0..12, do: b
  def vector_codec_from_byte(_), do: nil

  def element_type_from_byte(b) when b in 0..6, do: b
  def element_type_from_byte(_), do: nil

  def new_null, do: struct(Value, kind: :null)
  def new_bool(b), do: struct(Value, kind: :bool, bool: b)
  def new_i64(n), do: struct(Value, kind: :i64, i64: n)
  def new_u64(n), do: struct(Value, kind: :u64, u64: n)
  def new_f64(n), do: struct(Value, kind: :f64, f64: n)
  def new_string(s), do: struct(Value, kind: :string, str: s)
  def new_binary(b), do: struct(Value, kind: :binary, bin: b)
  def new_array(items), do: struct(Value, kind: :array, arr: Enum.map(items, &clone/1))

  def entry(key, value), do: %{key: key, value: clone(value)}

  def new_map(entries),
    do:
      struct(Value,
        kind: :map,
        map: Enum.map(entries, fn e -> %{key: e.key, value: clone(e.value)} end)
      )

  def clone(values) when is_list(values) do
    case values do
      [%Value{} | _] -> new_array(values)
      _ -> values
    end
  end

  def clone(%Value{kind: :binary, bin: bin} = v), do: %{v | bin: bin}

  def clone(%Value{kind: :array, arr: arr}),
    do: %Value{kind: :array, arr: Enum.map(arr, &clone/1)}

  def clone(%Value{kind: :map, map: map}),
    do: %Value{kind: :map, map: Enum.map(map, fn e -> %{key: e.key, value: clone(e.value)} end)}

  def clone(%Value{} = v),
    do: %Value{
      kind: v.kind,
      bool: v.bool,
      i64: v.i64,
      u64: v.u64,
      f64: v.f64,
      str: v.str,
      bin: v.bin,
      arr: v.arr,
      map: v.map
    }

  def clone_message(%Message{} = msg) do
    %Message{
      kind: msg.kind,
      scalar: if(msg.scalar, do: clone(msg.scalar), else: nil),
      array: if(msg.array, do: Enum.map(msg.array, &clone/1), else: nil),
      map:
        if(msg.map,
          do:
            Enum.map(msg.map, fn %{key: key, value: value} ->
              %{key: key, value: clone(value)}
            end),
          else: nil
        ),
      shaped_object:
        if(msg.shaped_object,
          do: %{msg.shaped_object | values: Enum.map(msg.shaped_object.values, &clone/1)},
          else: nil
        ),
      schema_object:
        if(msg.schema_object,
          do: %{msg.schema_object | fields: Enum.map(msg.schema_object.fields, &clone/1)},
          else: nil
        ),
      typed_vector: if(msg.typed_vector, do: clone_typed_vector_msg(msg.typed_vector), else: nil),
      row_batch:
        if(msg.row_batch,
          do: %{rows: Enum.map(msg.row_batch.rows, fn row -> Enum.map(row, &clone/1) end)},
          else: nil
        ),
      column_batch:
        if(msg.column_batch,
          do: %{
            count: msg.column_batch.count,
            columns: Enum.map(msg.column_batch.columns, &clone_column/1)
          },
          else: nil
        ),
      state_patch:
        if(msg.state_patch,
          do: %StatePatchMessage{
            base_ref: msg.state_patch.base_ref,
            operations:
              Enum.map(msg.state_patch.operations, fn op ->
                %PatchOperation{
                  field_id: op.field_id,
                  opcode: op.opcode,
                  value: if(op.value, do: clone(op.value), else: nil)
                }
              end),
            literals: Enum.map(msg.state_patch.literals, &clone/1)
          },
          else: nil
        ),
      template_batch:
        if(msg.template_batch,
          do: %TemplateBatchMessage{
            template_id: msg.template_batch.template_id,
            count: msg.template_batch.count,
            changed_column_mask: msg.template_batch.changed_column_mask,
            columns: Enum.map(msg.template_batch.columns, &clone_column/1)
          },
          else: nil
        ),
      base_snapshot:
        if(msg.base_snapshot,
          do: %BaseSnapshotMessage{
            base_id: msg.base_snapshot.base_id,
            schema_or_shape_ref: msg.base_snapshot.schema_or_shape_ref,
            payload: clone_message(msg.base_snapshot.payload)
          },
          else: nil
        ),
      control: msg.control,
      ext: msg.ext,
      control_stream: msg.control_stream
    }
  end

  defp clone_typed_vector_msg(tv) do
    %{
      element_type: tv.element_type,
      codec: tv.codec,
      data: clone_typed_vector_data(tv.data)
    }
  end

  defp clone_typed_vector_data(%{kind: :bool, bools: bools}),
    do: %TypedVectorData{kind: 0, bools: bools}

  defp clone_typed_vector_data(%{kind: :i64, i64s: i64s}),
    do: %TypedVectorData{kind: 1, i64s: i64s}

  defp clone_typed_vector_data(%{kind: :u64, u64s: u64s}),
    do: %TypedVectorData{kind: 2, u64s: u64s}

  defp clone_typed_vector_data(%{kind: kind, i64s: i64s}) when kind == 1,
    do: %TypedVectorData{kind: 1, i64s: i64s}

  defp clone_typed_vector_data(%TypedVectorData{} = d) do
    %TypedVectorData{
      kind: d.kind,
      bools: d.bools,
      i64s: d.i64s,
      u64s: d.u64s,
      f64s: d.f64s,
      strings: d.strings,
      binary: Enum.map(d.binary, & &1),
      values: if(d.values, do: Enum.map(d.values, &clone/1), else: nil)
    }
  end

  def clone_column(%Column{} = c) do
    %Column{
      field_id: c.field_id,
      null_strategy: c.null_strategy,
      presence: if(c.presence, do: c.presence, else: nil),
      has_presence: c.has_presence,
      codec: c.codec,
      dictionary_id: c.dictionary_id,
      values: clone_typed_vector_data(c.values)
    }
  end

  def equal?(a, b) do
    a.kind == b.kind and equal_kind(a, b)
  end

  defp equal_kind(%{kind: :null}, %{kind: :null}), do: true
  defp equal_kind(%{kind: :bool, bool: a}, %{kind: :bool, bool: b}), do: a == b
  defp equal_kind(%{kind: :i64, i64: a}, %{kind: :i64, i64: b}), do: a == b
  defp equal_kind(%{kind: :u64, u64: a}, %{kind: :u64, u64: b}), do: a == b
  defp equal_kind(%{kind: :f64, f64: a}, %{kind: :f64, f64: b}), do: a == b
  defp equal_kind(%{kind: :string, str: a}, %{kind: :string, str: b}), do: a == b
  defp equal_kind(%{kind: :binary, bin: a}, %{kind: :binary, bin: b}), do: a == b

  defp equal_kind(%{kind: :array, arr: a}, %{kind: :array, arr: b}) do
    length(a) == length(b) and Enum.zip(a, b) |> Enum.all?(fn {x, y} -> equal?(x, y) end)
  end

  defp equal_kind(%{kind: :map, map: a}, %{kind: :map, map: b}) do
    length(a) == length(b) and
      Enum.zip(a, b)
      |> Enum.all?(fn {%{key: ka, value: va}, %{key: kb, value: vb}} ->
        ka == kb and equal?(va, vb)
      end)
  end

  defp equal_kind(_, _), do: false

  def key_literal(s), do: %{literal: s, id: 0, is_id: false}
  def key_id(id), do: %{literal: "", id: id, is_id: true}

  def message_kind_from_byte(b) when b in 0..13, do: {:ok, b}
  def message_kind_from_byte(_), do: :error
end
