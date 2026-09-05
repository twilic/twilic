# frozen_string_literal: true

require "twilic/core/errors"

module Twilic
  module Core
    module Wire
      module_function

      def encode_varuint(value, out)
        if value < 0x80
          out << value.chr
          return
        end
        loop do
          b = value & 0x7F
          value >>= 7
          b |= 0x80 unless value.zero?
          out << b.chr
          break if value.zero?
        end
      end

      def encode_zigzag(value)
        ((value << 1) ^ (value >> 63)) & 0xFFFFFFFFFFFFFFFF
      end

      def decode_zigzag(value)
        ((value >> 1) ^ (-(value & 1))) & 0xFFFFFFFFFFFFFFFF
        v = (value >> 1) ^ (-(value & 1))
        v >= 0x8000000000000000 ? v - 0x10000000000000000 : v
      end

      def encode_bytes(bytes, out)
        encode_varuint(bytes.bytesize, out)
        out << bytes
      end

      def encode_string(value, out)
        encode_bytes(value.b, out)
      end

      def encode_bitmap(bits, out)
        encode_varuint(bits.length, out)
        current = 0
        bits.each_with_index do |bit, i|
          current |= (1 << (i % 8)) if bit
          if (i % 8) == 7
            out << current.chr
            current = 0
          end
        end
        out << current.chr unless bits.empty? || (bits.length % 8).zero?
      end

      class Reader
        attr_reader :offset

        def initialize(input)
          @input = input.b
          @offset = 0
          @depth = 0
          @budget = [input.bytesize, 1024].min * 1024
        end

        def claim_output(count)
          raise Errors.invalid_data("decode count limit exceeded") unless count.between?(0, 1 << 20)
          raise Errors.invalid_data("decode output ratio exceeded") if count > @budget / 8
          @budget -= count * 8
        end

        def read_count(maximum = 1 << 20)
          count = read_varuint
          raise Errors.invalid_data("decode count limit exceeded") if count > maximum
          claim_output(count)
          count
        end

        def with_depth
          raise Errors.invalid_data("decode depth limit exceeded") if @depth >= 64
          @depth += 1
          begin
            yield
          ensure
            @depth -= 1
          end
        end

        def position
          @offset
        end

        def eof?
          @offset >= @input.bytesize
        end

        def read_u8
          raise Errors.unexpected_eof if @offset >= @input.bytesize

          b = @input.getbyte(@offset)
          @offset += 1
          b
        end

        def read_exact(n)
          raise Errors.unexpected_eof if n < 0 || n > @input.bytesize - @offset

          slice = @input.byteslice(@offset, n)
          @offset += n
          slice
        end

        def read_varuint
          shift = 0
          result = 0
          loop do
            raise Errors.invalid_data("varuint too large") if shift >= 64

            b = read_u8
            raise Errors.invalid_data("varuint too large") if shift == 63 && (b & 0x7E) != 0
            result |= (b & 0x7F) << shift
            return result if (b & 0x80).zero?

            shift += 7
          end
        end

        def read_i64_zigzag
          encoded = read_varuint
          Wire.decode_zigzag(encoded)
        end

        def read_bytes
          n = read_varuint
          read_exact(n)
        end

        def read_string
          n = read_varuint
          bytes = read_exact(n)
          raise Errors.utf8_error unless bytes.valid_encoding? && bytes.force_encoding(Encoding::UTF_8).valid_encoding?

          bytes.force_encoding(Encoding::UTF_8)
        end

        def read_bitmap
          bit_count = read_count
          byte_count = (bit_count + 7) / 8
          bytes = read_exact(byte_count)
          bits = Array.new(bit_count)
          bit_count.times do |i|
            bits[i] = ((bytes.getbyte(i / 8) >> (i % 8)) & 1) == 1
          end
          bits
        end

        def read_u64_le
          b = read_exact(8)
          b.unpack1("Q<")
        end

        def read_f64_le
          [read_u64_le].pack("Q<").unpack1("E")
        end
      end

      def read_u64_le(reader)
        reader.read_u64_le
      end

      def read_f64_le(reader)
        reader.read_f64_le
      end

      def append_u64_le(out, v)
        out << [v].pack("Q<")
      end

      def append_f64_le(out, v)
        append_u64_le(out, [v].pack("E").unpack1("Q<"))
      end
    end
  end
end
