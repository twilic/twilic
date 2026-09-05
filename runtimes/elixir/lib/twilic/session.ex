defmodule Twilic.Session do
  @moduledoc false

  defmodule InternTable do
    defstruct by_value: %{}, by_id: []

    def get_id(%__MODULE__{by_value: by_value}, value) do
      case Map.get(by_value, value) do
        nil -> {0, false}
        ref_id -> {ref_id, true}
      end
    end

    def get_value(%__MODULE__{by_id: by_id}, ref_id) when ref_id < length(by_id),
      do: {Enum.at(by_id, ref_id), true}

    def get_value(_, _), do: {"", false}

    def register(%__MODULE__{by_value: by_value, by_id: by_id} = t, value) do
      case Map.get(by_value, value) do
        nil ->
          ref_id = length(by_id)
          {%{t | by_value: Map.put(by_value, value, ref_id), by_id: by_id ++ [value]}, ref_id}

        ref_id ->
          {t, ref_id}
      end
    end

    def clear(_), do: %__MODULE__{}
  end

  defmodule ShapeTable do
    defstruct by_keys: %{}, by_id: %{}, observations: %{}, next_id: 0

    def get_id(%__MODULE__{by_keys: by_keys}, keys) do
      case Map.get(by_keys, Twilic.Session.shape_key(keys)) do
        nil -> {0, false}
        ref_id -> {ref_id, true}
      end
    end

    def get_keys(%__MODULE__{by_id: by_id}, ref_id) do
      case Map.get(by_id, ref_id) do
        nil -> {[], false}
        keys -> {keys, true}
      end
    end

    def register(%__MODULE__{} = t, keys) do
      sk = Twilic.Session.shape_key(keys)

      case Map.get(t.by_keys, sk) do
        nil ->
          ref_id = t.next_id

          {%{
             t
             | by_id: Map.put(t.by_id, ref_id, keys),
               by_keys: Map.put(t.by_keys, sk, ref_id),
               next_id: ref_id + 1
           }, ref_id}

        ref_id ->
          {t, ref_id}
      end
    end

    def observe(%__MODULE__{observations: observations} = t, keys) do
      sk = Twilic.Session.shape_key(keys)
      count = Map.get(observations, sk, 0) + 1
      {%{t | observations: Map.put(observations, sk, count)}, count}
    end

    def clear(_), do: %__MODULE__{}
  end

  defmodule BaseSnapshotEntry do
    defstruct id: 0, message: nil
  end

  defstruct options: %{},
            key_table: nil,
            string_table: nil,
            shape_table: nil,
            encode_shape_observations: %{},
            base_snapshots: [],
            templates: %{},
            template_columns: %{},
            schemas: %{},
            previous_message: nil,
            previous_message_size: nil,
            next_base_id: 0,
            next_template_id: 0

  def default_options do
    %{
      max_base_snapshots: 8,
      enable_state_patch: true,
      enable_template_batch: true,
      enable_trained_dictionary: true,
      unknown_reference_policy: :fail_fast
    }
  end

  def new_state(opts \\ default_options()) do
    %__MODULE__{
      options: opts,
      key_table: %InternTable{},
      string_table: %InternTable{},
      shape_table: %ShapeTable{},
      encode_shape_observations: %{},
      base_snapshots: [],
      templates: %{},
      template_columns: %{}
    }
  end

  def shape_key(keys), do: Enum.join(keys, <<0>>)

  def register_base_snapshot(%__MODULE__{} = state, base_id, message) do
    entry = %BaseSnapshotEntry{id: base_id, message: Twilic.Model.clone_message(message)}
    filtered = Enum.reject(state.base_snapshots, &(&1.id == base_id)) ++ [entry]
    max = Map.get(state.options, :max_base_snapshots, 8)

    trimmed =
      if length(filtered) > max do
        Enum.take(filtered, -max)
      else
        filtered
      end

    %{state | base_snapshots: trimmed}
  end

  def get_base_snapshot(%__MODULE__{base_snapshots: entries}, base_id) do
    case Enum.find(entries, &(&1.id == base_id)) do
      nil -> {nil, false}
      %{message: msg} -> {Twilic.Model.clone_message(msg), true}
    end
  end

  def allocate_base_id(%__MODULE__{} = state) do
    id = state.next_base_id
    {id, %{state | next_base_id: id + 1}}
  end

  def allocate_template_id(%__MODULE__{} = state) do
    id = state.next_template_id
    {id, %{state | next_template_id: id + 1}}
  end

  def reset_tables(%__MODULE__{} = state) do
    %{
      state
      | key_table: %InternTable{},
        string_table: %InternTable{},
        shape_table: %ShapeTable{},
        encode_shape_observations: %{}
    }
  end

  def reset_state(state) do
    state
    |> reset_tables()
    |> then(fn s ->
      %{
        s
        | base_snapshots: [],
          templates: %{},
          template_columns: %{},
          schemas: %{},
          previous_message: nil,
          previous_message_size: nil,
          next_base_id: 0,
          next_template_id: 0
      }
    end)
  end
end
