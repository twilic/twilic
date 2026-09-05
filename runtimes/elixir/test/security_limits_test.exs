defmodule Twilic.SecurityLimitsTest do
  use ExUnit.Case
  alias Twilic.Wire
  alias Twilic.Errors.TwilicError

  test "budget persists through byte reads" do
    reader = Wire.new_reader(<<0>>)
    reader = Wire.claim_output(reader, 100)
    {_, reader} = Wire.read_u8(reader)
    assert_raise TwilicError, fn -> Wire.claim_output(reader, 100) end
  end

  test "depth and invalid lengths" do
    assert_raise TwilicError, fn -> Twilic.V2.decode(:binary.copy(<<0xA1>>, 70) <> <<0xC0>>) end
    assert_raise TwilicError, fn -> Wire.read_exact(-1, Wire.new_reader(<<0>>)) end
  end
end
