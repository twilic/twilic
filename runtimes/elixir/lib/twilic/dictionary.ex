defmodule Twilic.Dictionary do
  @moduledoc false
  alias Twilic.Errors
  alias Twilic.Wire

  def decode_trained_dictionary_payload(payload) do
    reader = Wire.new_reader(payload)
    {n, reader} = Wire.read_count(reader)

    {values, reader} =
      Enum.reduce(1..n, {[], reader}, fn _, {acc, reader} ->
        {s, reader} = Wire.read_string(reader)
        {acc ++ [s], reader}
      end)

    if Wire.is_eof?(reader),
      do: values,
      else: raise(Errors.invalid_data("trained dictionary payload trailing bytes"))
  end

  def dictionary_payload_hash(payload) do
    Enum.reduce(:binary.bin_to_list(payload), 0xCBF29CE484222325, fn b, h ->
      h = Bitwise.bxor(h, b)
      Bitwise.band(h * 0x100000001B3, 0xFFFFFFFFFFFFFFFF)
    end)
  end

  def apply_dictionary_references(_state), do: :ok
end
