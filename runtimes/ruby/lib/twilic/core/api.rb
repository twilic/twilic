# frozen_string_literal: true

require "twilic/core/v2"
require "twilic/core/protocol"

module Twilic
  module Core
    module API
      module_function

      def encode(value)
        V2.encode_v2(value)
      end

      def decode(bytes)
        V2.decode_v2(bytes)
      end

      def encode_with_schema(schema, value)
        enc = Protocol::SessionEncoder.new(Session::SessionOptions.default)
        enc.encode_with_schema(schema, value)
      end

      def encode_batch(values)
        enc = Protocol::SessionEncoder.new(Session::SessionOptions.default)
        enc.encode_batch(values)
      end
    end
  end
end
