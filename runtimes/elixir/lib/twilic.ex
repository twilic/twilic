defmodule Twilic do
  @moduledoc """
  Native Elixir Twilic v2 SDK (ported from twilic-dart).
  """

  alias Twilic.Model
  alias Twilic.Protocol
  alias Twilic.V2

  defdelegate new_null(), to: Model
  defdelegate new_bool(b), to: Model
  defdelegate new_i64(n), to: Model
  defdelegate new_u64(n), to: Model
  defdelegate new_f64(n), to: Model
  defdelegate new_string(s), to: Model
  defdelegate new_binary(b), to: Model
  defdelegate new_array(items), to: Model
  defdelegate entry(key, value), to: Model
  defdelegate new_map(entries), to: Model
  defdelegate equal?(a, b), to: Model, as: :equal?

  def encode(value), do: V2.encode(value)
  def decode(data), do: V2.decode(data)

  def encode_with_schema(schema, value) do
    Protocol.SessionEncoder.new()
    |> Protocol.SessionEncoder.encode_with_schema(schema, value)
  end

  def encode_batch(values) do
    Protocol.SessionEncoder.new()
    |> Protocol.SessionEncoder.encode_batch(values)
  end

  def new_twilic_codec, do: Protocol.TwilicCodec.new()
  def new_session_encoder, do: Protocol.SessionEncoder.new()
end
