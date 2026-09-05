defmodule Twilic.Errors do
  @moduledoc false

  defmodule TwilicError do
    defexception [:kind, :byte, :msg, :ref_kind, :ref_id]

    @impl true
    def message(%{kind: :err_unexpected_eof}), do: "unexpected end of input"

    def message(%{kind: :err_invalid_kind, byte: b}),
      do: "invalid message kind: 0x#{Integer.to_string(b, 16)}"

    def message(%{kind: :err_invalid_tag, byte: b}),
      do: "invalid value tag: 0x#{Integer.to_string(b, 16)}"

    def message(%{kind: :err_invalid_data, msg: msg}), do: "invalid data: #{msg}"
    def message(%{kind: :err_utf8}), do: "utf8 decode error"

    def message(%{kind: :err_unknown_reference, ref_kind: k, ref_id: id}),
      do: "unknown reference: #{k}=#{id}"

    def message(%{kind: :err_stateless_retry_required, ref_kind: k, ref_id: id}),
      do: "stateless retry required for reference: #{k}=#{id}"

    def message(_), do: "twilic error"
  end

  def unexpected_eof, do: %TwilicError{kind: :err_unexpected_eof}
  def invalid_kind(b), do: %TwilicError{kind: :err_invalid_kind, byte: b}
  def invalid_tag(b), do: %TwilicError{kind: :err_invalid_tag, byte: b}
  def invalid_data(msg), do: %TwilicError{kind: :err_invalid_data, msg: msg}
  def utf8_error, do: %TwilicError{kind: :err_utf8}

  def unknown_reference(kind, ref_id),
    do: %TwilicError{kind: :err_unknown_reference, ref_kind: kind, ref_id: ref_id}

  def stateless_retry_required(kind, ref_id),
    do: %TwilicError{kind: :err_stateless_retry_required, ref_kind: kind, ref_id: ref_id}
end
