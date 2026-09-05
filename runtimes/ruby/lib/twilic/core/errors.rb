# frozen_string_literal: true

module Twilic
  module Core
    module Errors
      UNEXPECTED_EOF = :unexpected_eof
      INVALID_KIND = :invalid_kind
      INVALID_TAG = :invalid_tag
      INVALID_DATA = :invalid_data
      UTF8 = :utf8
      UNKNOWN_REFERENCE = :unknown_reference
      STATELESS_RETRY_REQUIRED = :stateless_retry_required

      class TwilicError < StandardError
        attr_reader :kind, :byte, :msg, :ref_kind, :ref_id

        def initialize(kind, byte: nil, msg: nil, ref_kind: nil, ref_id: nil)
          @kind = kind
          @byte = byte
          @msg = msg
          @ref_kind = ref_kind
          @ref_id = ref_id
          super(message)
        end

        def message
          case kind
          when UNEXPECTED_EOF
            "unexpected end of input"
          when INVALID_KIND
            format("invalid message kind: 0x%02x", byte)
          when INVALID_TAG
            format("invalid value tag: 0x%02x", byte)
          when INVALID_DATA
            "invalid data: #{msg}"
          when UTF8
            "utf8 decode error"
          when UNKNOWN_REFERENCE
            "unknown reference: #{ref_kind}=#{ref_id}"
          when STATELESS_RETRY_REQUIRED
            "stateless retry required for reference: #{ref_kind}=#{ref_id}"
          else
            "twilic error"
          end
        end
      end

      module_function

      def unexpected_eof
        TwilicError.new(UNEXPECTED_EOF)
      end

      def invalid_kind(byte)
        TwilicError.new(INVALID_KIND, byte: byte)
      end

      def invalid_tag(byte)
        TwilicError.new(INVALID_TAG, byte: byte)
      end

      def invalid_data(msg)
        TwilicError.new(INVALID_DATA, msg: msg)
      end

      def utf8_error
        TwilicError.new(UTF8)
      end

      def unknown_reference(kind, id)
        TwilicError.new(UNKNOWN_REFERENCE, ref_kind: kind, ref_id: id)
      end

      def stateless_retry_required(kind, id)
        TwilicError.new(STATELESS_RETRY_REQUIRED, ref_kind: kind, ref_id: id)
      end

      def stateless_retry?(err)
        err.is_a?(TwilicError) && err.kind == STATELESS_RETRY_REQUIRED
      end

      def unknown_reference?(err)
        err.is_a?(TwilicError) && err.kind == UNKNOWN_REFERENCE
      end
    end
  end
end
