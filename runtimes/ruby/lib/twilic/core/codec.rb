# frozen_string_literal: true

require "twilic/core/errors"
require "twilic/core/model"
require "twilic/core/wire"

module Twilic
  module Core
    module Codec
      MAX_U64 = 0xFFFFFFFFFFFFFFFF
      MAX_I64 = 0x7FFFFFFFFFFFFFFF
      MIN_I64 = -0x8000000000000000

      SIMPLE8B_SLOTS = [
        { count: 60, width: 1 },
        { count: 30, width: 2 },
        { count: 20, width: 3 },
        { count: 15, width: 4 },
        { count: 12, width: 5 },
        { count: 10, width: 6 },
        { count: 8, width: 7 },
        { count: 7, width: 8 },
        { count: 6, width: 10 },
        { count: 5, width: 12 },
        { count: 4, width: 15 },
        { count: 3, width: 20 },
        { count: 2, width: 30 },
        { count: 1, width: 60 }
      ].freeze

      module_function

      def encode_i64_vector(values, codec, out)
        case codec
        when Model::VectorCodec::RLE
          encode_i64_rle(values, out)
        when Model::VectorCodec::DIRECT_BITPACK
          encode_i64_direct_bitpack(values, out)
        when Model::VectorCodec::DELTA_BITPACK
          deltas = delta(values)
          encode_i64_direct_bitpack(deltas, out)
        when Model::VectorCodec::FOR_BITPACK
          if values.empty?
            Wire.encode_varuint(0, out)
            return
          end
          min_value = values[0]
          values[1..].each do |v|
            min_value = v if v < min_value
          end
          Wire.encode_varuint(Wire.encode_zigzag(min_value), out)
          shifted = values.map { |v| v - min_value }
          encode_i64_direct_bitpack(shifted, out)
        when Model::VectorCodec::DELTA_FOR_BITPACK
          deltas = delta(values)
          if deltas.empty?
            Wire.encode_varuint(0, out)
            return
          end
          min_value = deltas[0]
          deltas[1..].each do |v|
            min_value = v if v < min_value
          end
          Wire.encode_varuint(Wire.encode_zigzag(min_value), out)
          shifted = deltas.map { |v| v - min_value }
          encode_i64_direct_bitpack(shifted, out)
        when Model::VectorCodec::DELTA_DELTA_BITPACK
          encode_i64_delta_delta(values, out)
        when Model::VectorCodec::PATCHED_FOR
          encode_i64_patched_for(values, out)
        when Model::VectorCodec::SIMPLE8B
          encode_i64_simple8b(values, out)
        when Model::VectorCodec::PLAIN, Model::VectorCodec::DICTIONARY, Model::VectorCodec::STRING_REF,
             Model::VectorCodec::PREFIX_DELTA, Model::VectorCodec::XOR_FLOAT
          encode_i64_plain(values, out)
        end
      end

      def decode_i64_vector(reader, codec)
        case codec
        when Model::VectorCodec::RLE
          decode_i64_rle(reader)
        when Model::VectorCodec::DIRECT_BITPACK
          decode_i64_direct_bitpack(reader)
        when Model::VectorCodec::DELTA_BITPACK
          values = decode_i64_direct_bitpack(reader)
          undelta(values)
        when Model::VectorCodec::FOR_BITPACK
          encoded_min = reader.read_varuint
          min_value = Wire.decode_zigzag(encoded_min)
          return [] if reader.eof?

          shifted = decode_i64_direct_bitpack(reader)
          shifted.map { |v| v + min_value }
        when Model::VectorCodec::DELTA_FOR_BITPACK
          encoded_min = reader.read_varuint
          min_value = Wire.decode_zigzag(encoded_min)
          return [] if reader.eof?

          shifted = decode_i64_direct_bitpack(reader)
          deltas = shifted.map { |v| v + min_value }
          undelta(deltas)
        when Model::VectorCodec::DELTA_DELTA_BITPACK
          decode_i64_delta_delta(reader)
        when Model::VectorCodec::PATCHED_FOR
          decode_i64_patched_for(reader)
        when Model::VectorCodec::SIMPLE8B
          decode_i64_simple8b(reader)
        when Model::VectorCodec::PLAIN, Model::VectorCodec::DICTIONARY, Model::VectorCodec::STRING_REF,
             Model::VectorCodec::PREFIX_DELTA, Model::VectorCodec::XOR_FLOAT
          decode_i64_plain(reader)
        else
          raise Errors.invalid_data("unsupported vector codec")
        end
      end

      def encode_u64_vector(values, codec, out)
        case codec
        when Model::VectorCodec::RLE
          encode_u64_rle(values, out)
        when Model::VectorCodec::DIRECT_BITPACK
          encode_u64_direct_bitpack(values, out)
        when Model::VectorCodec::FOR_BITPACK
          if values.empty?
            Wire.encode_varuint(0, out)
            return
          end
          min_value = values[0]
          values[1..].each do |v|
            min_value = v if v < min_value
          end
          Wire.encode_varuint(min_value, out)
          shifted = values.map { |v| v - min_value }
          encode_u64_direct_bitpack(shifted, out)
        when Model::VectorCodec::PLAIN
          encode_u64_plain(values, out)
        when Model::VectorCodec::SIMPLE8B
          encode_u64_simple8b(values, out)
        when Model::VectorCodec::DICTIONARY, Model::VectorCodec::STRING_REF, Model::VectorCodec::PREFIX_DELTA,
             Model::VectorCodec::XOR_FLOAT, Model::VectorCodec::DELTA_BITPACK, Model::VectorCodec::DELTA_FOR_BITPACK,
             Model::VectorCodec::DELTA_DELTA_BITPACK, Model::VectorCodec::PATCHED_FOR
          encode_u64_plain(values, out)
        end
      end

      def decode_u64_vector(reader, codec)
        case codec
        when Model::VectorCodec::RLE
          decode_u64_rle(reader)
        when Model::VectorCodec::DIRECT_BITPACK
          decode_u64_direct_bitpack(reader)
        when Model::VectorCodec::FOR_BITPACK
          min_value = reader.read_varuint
          return [] if reader.eof?

          shifted = decode_u64_direct_bitpack(reader)
          out = []
          shifted.each do |v|
            sum, ok = checked_add_u64(v, min_value)
            raise Errors.invalid_data("u64 FOR overflow") unless ok

            out << sum
          end
          out
        when Model::VectorCodec::PLAIN
          decode_u64_plain(reader)
        when Model::VectorCodec::SIMPLE8B
          decode_u64_simple8b(reader)
        when Model::VectorCodec::DICTIONARY, Model::VectorCodec::STRING_REF, Model::VectorCodec::PREFIX_DELTA,
             Model::VectorCodec::XOR_FLOAT, Model::VectorCodec::DELTA_BITPACK, Model::VectorCodec::DELTA_FOR_BITPACK,
             Model::VectorCodec::DELTA_DELTA_BITPACK, Model::VectorCodec::PATCHED_FOR
          decode_u64_plain(reader)
        else
          raise Errors.invalid_data("unsupported vector codec")
        end
      end

      def encode_f64_vector(values, codec, out)
        if codec == Model::VectorCodec::XOR_FLOAT
          encode_xor_float(values, out)
          return
        end
        Wire.encode_varuint(values.length, out)
        values.each { |v| Wire.append_f64_le(out, v) }
      end

      def decode_f64_vector(reader, codec)
        return decode_xor_float(reader) if codec == Model::VectorCodec::XOR_FLOAT

        length = reader.read_count
        out = []
        length.times do
          out << Wire.read_f64_le(reader)
        end
        out
      end

      def encode_u64_plain(values, out)
        Wire.encode_varuint(values.length, out)
        values.each { |value| Wire.encode_varuint(value, out) }
      end

      def decode_u64_plain(reader)
        length = reader.read_count
        out = []
        length.times do
          out << reader.read_varuint
        end
        out
      end

      def encode_u64_rle(values, out)
        runs = []
        values.each do |value|
          if !runs.empty? && runs[-1][:value] == value
            runs[-1][:count] += 1
          else
            runs << { value: value, count: 1 }
          end
        end
        Wire.encode_varuint(runs.length, out)
        runs.each do |run|
          Wire.encode_varuint(run[:value], out)
          Wire.encode_varuint(run[:count], out)
        end
      end

      def decode_u64_rle(reader)
        runs_len = reader.read_count
        out = []
        runs_len.times do
          value = reader.read_varuint
          count = reader.read_count
          count.times { out << value }
        end
        out
      end

      def encode_u64_direct_bitpack(values, out)
        Wire.encode_varuint(values.length, out)
        if values.empty?
          out << 0.chr
          return
        end
        width = 1
        values.each do |v|
          bw = bit_width(v)
          width = bw if bw > width
        end
        out << width.chr
        pack_u64_values(values, width, out)
      end

      def decode_u64_direct_bitpack(reader)
        length = reader.read_count
        width = reader.read_u8
        return [] if length.zero?

        raise Errors.invalid_data("bitpack width") if width.zero? || width > 64

        unpack_u64_values(reader, length, width)
      end

      def encode_i64_plain(values, out)
        Wire.encode_varuint(values.length, out)
        values.each { |value| Wire.encode_varuint(Wire.encode_zigzag(value), out) }
      end

      def decode_i64_plain(reader)
        length = reader.read_count
        out = []
        length.times do
          v = reader.read_varuint
          out << Wire.decode_zigzag(v)
        end
        out
      end

      def encode_i64_simple8b(values, out)
        encoded = values.map { |v| Wire.encode_zigzag(v) }
        encode_u64_simple8b_inner(encoded, out)
      end

      def decode_i64_simple8b(reader)
        encoded = decode_u64_simple8b_inner(reader)
        encoded.map { |v| Wire.decode_zigzag(v) }
      end

      def encode_u64_simple8b(values, out)
        encode_u64_simple8b_inner(values, out)
      end

      def decode_u64_simple8b(reader)
        decode_u64_simple8b_inner(reader)
      end

      def encode_u64_simple8b_inner(values, out)
        Wire.encode_varuint(values.length, out)
        return if values.empty?

        max_value = 0
        values.each { |v| max_value = v if v > max_value }
        if max_value > ((1 << 60) - 1)
          out << 0.chr
          values.each { |value| Wire.encode_varuint(value, out) }
          return
        end

        out << 1.chr
        idx = 0
        while idx < values.length
          zero_run = 0
          while idx + zero_run < values.length && values[idx + zero_run].zero? && zero_run < 240
            zero_run += 1
          end
          if zero_run >= 120
            take = zero_run >= 240 ? 240 : 120
            word = (take == 240 ? 0 : (1 << 60))
            Wire.append_u64_le(out, word)
            idx += take
            next
          end

          packed = false
          SIMPLE8B_SLOTS.each_with_index do |slot, selector_idx|
            next if idx + slot[:count] > values.length

            max_encodable = (1 << slot[:width]) - 1
            all_fit = true
            values[idx, slot[:count]].each do |value|
              if value > max_encodable
                all_fit = false
                break
              end
            end
            next unless all_fit

            selector = selector_idx + 2
            payload = 0
            shift = 0
            values[idx, slot[:count]].each do |value|
              payload |= (value << shift)
              shift += slot[:width]
            end
            word = (selector << 60) | payload
            Wire.append_u64_le(out, word & MAX_U64)
            idx += slot[:count]
            packed = true
            break
          end
          next if packed

          selector = 15
          word = (selector << 60) | (values[idx] & ((1 << 60) - 1))
          Wire.append_u64_le(out, word & MAX_U64)
          idx += 1
        end
      end

      def decode_u64_simple8b_inner(reader)
        length = reader.read_count
        return [] if length.zero?

        mode = reader.read_u8
        if mode.zero?
          out = []
          length.times do
            out << reader.read_varuint
          end
          return out
        end
        raise Errors.invalid_data("simple8b mode") unless mode == 1

        out = []
        while out.length < length
          packed = Wire.read_u64_le(reader)
          selector = packed >> 60
          payload = packed & ((1 << 60) - 1)
          if selector == 0 || selector == 1
            count = selector == 1 ? 120 : 240
            remain = length - out.length
            limit = remain < count ? remain : count
            limit.times { out << 0 }
          elsif selector >= 2 && selector <= 15
            if selector == 15
              count = 1
              width = 60
            else
              slot = SIMPLE8B_SLOTS[selector - 2]
              count = slot[:count]
              width = slot[:width]
            end
            mask = (1 << width) - 1
            shift = 0
            remain = length - out.length
            limit = remain < count ? remain : count
            limit.times do
              out << ((payload >> shift) & mask)
              shift += width
            end
          else
            raise Errors.invalid_data("simple8b selector")
          end
        end
        out
      end

      def delta(values)
        out = []
        prev = 0
        values.each_with_index do |value, i|
          out << (i.zero? ? value : (value - prev))
          prev = value
        end
        out
      end

      def undelta(values)
        out = []
        prev = 0
        values.each_with_index do |value, i|
          if i.zero?
            out << value
            prev = value
            next
          end
          next_value, ok = checked_add_i64(prev, value)
          raise Errors.invalid_data("delta overflow") unless ok

          out << next_value
          prev = next_value
        end
        out
      end

      def encode_i64_rle(values, out)
        runs = []
        values.each do |value|
          if !runs.empty? && runs[-1][:value] == value
            runs[-1][:count] += 1
          else
            runs << { value: value, count: 1 }
          end
        end
        Wire.encode_varuint(runs.length, out)
        runs.each do |run|
          Wire.encode_varuint(Wire.encode_zigzag(run[:value]), out)
          Wire.encode_varuint(run[:count], out)
        end
      end

      def decode_i64_rle(reader)
        runs_len = reader.read_count
        out = []
        runs_len.times do
          value_encoded = reader.read_varuint
          value = Wire.decode_zigzag(value_encoded)
          count = reader.read_count
          count.times { out << value }
        end
        out
      end

      def encode_i64_patched_for(values, out)
        if values.empty?
          Wire.encode_varuint(0, out)
          return
        end
        base = values[0]
        values[1..].each do |v|
          base = v if v < base
        end
        shifted = values.map { |v| v - base }
        Wire.encode_varuint(shifted.length, out)
        Wire.encode_varuint(Wire.encode_zigzag(base), out)

        max_value = 0
        shifted.each { |value| max_value = value if value > max_value }
        bw = bit_width(max_value & MAX_U64)
        base_width = bw > 2 ? bw - 2 : 0
        out << base_width.chr

        patch_positions = []
        main_values = []
        shifted.each_with_index do |value, idx|
          if bit_width(value & MAX_U64) > base_width
            patch_positions << { pos: idx, value: value }
            main = 0
            if base_width.positive?
              mask = (1 << base_width) - 1
              main = value & mask
              main = 0 if main.negative?
            end
            main_values << main
          else
            main_values << value
          end
        end
        main_values.each do |value|
          Wire.encode_varuint(value & MAX_U64, out)
        end
        Wire.encode_varuint(patch_positions.length, out)
        patch_positions.each do |patch|
          Wire.encode_varuint(patch[:pos], out)
          Wire.encode_varuint(patch[:value] & MAX_U64, out)
        end
      end

      def decode_i64_patched_for(reader)
        length = reader.read_count
        return [] if length.zero?

        base_encoded = reader.read_varuint
        base = Wire.decode_zigzag(base_encoded)
        reader.read_u8
        values = []
        length.times do
          v = reader.read_varuint
          values << u64_to_i64(v)
        end
        patch_count = reader.read_count
        patch_count.times do
          pos = reader.read_varuint
          patch = reader.read_varuint
          values[pos] = u64_to_i64(patch) if pos < values.length
        end
        values.map { |v| v + base }
      end

      def encode_xor_float(values, out)
        Wire.encode_varuint(values.length, out)
        return if values.empty?

        first_bits = f64_to_u64(values[0])
        Wire.append_u64_le(out, first_bits)
        prev = first_bits
        values[1..].each do |value|
          bits_value = f64_to_u64(value)
          x = prev ^ bits_value
          if x.zero?
            out << 0.chr
          else
            out << 1.chr
            leading = leading_zeros64(x)
            trailing = trailing_zeros64(x)
            width = 64 - (leading + trailing)
            Wire.encode_varuint(leading, out)
            Wire.encode_varuint(trailing, out)
            Wire.encode_varuint(width, out)
            payload = if width == 64
                        x
                      else
                        (x >> trailing) & ((1 << width) - 1)
                      end
            Wire.encode_varuint(payload, out)
          end
          prev = bits_value
        end
      end

      def decode_xor_float(reader)
        length = reader.read_count
        return [] if length.zero?

        first_bits = Wire.read_u64_le(reader)
        out = [u64_to_f64(first_bits)]
        prev = first_bits
        (length - 1).times do
          flag = reader.read_u8
          bits_value = prev
          unless flag.zero?
            leading = reader.read_varuint
            trailing = reader.read_varuint
            width = reader.read_varuint
            payload = reader.read_varuint
            raise Errors.invalid_data("xor-float bit widths") if leading + trailing + width > 64

            x = width == 64 ? payload : (payload << trailing)
            bits_value = prev ^ x
          end
          out << u64_to_f64(bits_value)
          prev = bits_value
        end
        out
      end

      def encode_i64_direct_bitpack(values, out)
        Wire.encode_varuint(values.length, out)
        if values.empty?
          out << 0.chr
          return
        end
        encoded = []
        width = 1
        values.each do |v|
          enc = Wire.encode_zigzag(v)
          encoded << enc
          bw = bit_width(enc)
          width = bw if bw > width
        end
        out << width.chr
        pack_u64_values(encoded, width, out)
      end

      def decode_i64_direct_bitpack(reader)
        length = reader.read_count
        width = reader.read_u8
        return [] if length.zero?

        raise Errors.invalid_data("bitpack width") if width.zero? || width > 64

        encoded = unpack_u64_values(reader, length, width)
        encoded.map { |v| Wire.decode_zigzag(v) }
      end

      def encode_i64_delta_delta(values, out)
        Wire.encode_varuint(values.length, out)
        return if values.empty?

        Wire.encode_varuint(Wire.encode_zigzag(values[0]), out)
        return if values.length == 1

        d1 = values[1] - values[0]
        Wire.encode_varuint(Wire.encode_zigzag(d1), out)
        dd = []
        prev_delta = d1
        (1...(values.length - 1)).each do |i|
          d = values[i + 1] - values[i]
          dd << (d - prev_delta)
          prev_delta = d
        end
        encode_i64_direct_bitpack(dd, out)
      end

      def decode_i64_delta_delta(reader)
        length = reader.read_count
        return [] if length.zero?

        first_encoded = reader.read_varuint
        first = Wire.decode_zigzag(first_encoded)
        return [first] if length == 1

        first_delta_encoded = reader.read_varuint
        first_delta = Wire.decode_zigzag(first_delta_encoded)
        dd = decode_i64_direct_bitpack(reader)
        raise Errors.invalid_data("delta-delta length") if dd.length != length - 2

        out = [first]
        prev = first
        second, ok = checked_add_i64(prev, first_delta)
        raise Errors.invalid_data("delta-delta overflow") unless ok

        out << second
        prev = second
        prev_delta = first_delta
        dd.each do |ddv|
          d, ok = checked_add_i64(prev_delta, ddv)
          raise Errors.invalid_data("delta-delta overflow") unless ok

          nxt, ok = checked_add_i64(prev, d)
          raise Errors.invalid_data("delta-delta overflow") unless ok

          out << nxt
          prev = nxt
          prev_delta = d
        end
        out
      end

      def pack_u64_values(values, width, out)
        total_bits = values.length * width
        byte_len = (total_bits + 7) / 8
        bytes = Array.new(byte_len, 0)
        bit_pos = 0
        values.each do |value|
          written = 0
          while written < width
            byte_idx = bit_pos / 8
            bit_off = bit_pos % 8
            room = 8 - bit_off
            take = width - written
            take = room if take > room
            mask = (1 << take) - 1
            part = (value >> written) & mask
            bytes[byte_idx] |= (part << bit_off)
            bit_pos += take
            written += take
          end
        end
        out << bytes.pack("C*")
      end

      def unpack_u64_values(reader, length, width)
        total_bits = length * width
        byte_len = (total_bits + 7) / 8
        bytes = reader.read_exact(byte_len)
        out = []
        bit_pos = 0
        length.times do
          value = 0
          written = 0
          while written < width
            byte_idx = bit_pos / 8
            raise Errors.invalid_data("bitpack underflow") if byte_idx >= bytes.bytesize

            bit_off = bit_pos % 8
            room = 8 - bit_off
            take = width - written
            take = room if take > room
            mask = (1 << take) - 1
            part = (bytes.getbyte(byte_idx) >> bit_off) & mask
            value |= (part << written)
            bit_pos += take
            written += take
          end
          out << value
        end
        out
      end

      def bit_width(v)
        v &= MAX_U64
        return 1 if v.zero?

        64 - leading_zeros64(v)
      end

      def checked_add_u64(a, b)
        sum = a + b
        [sum & MAX_U64, sum <= MAX_U64]
      end

      def checked_add_i64(a, b)
        sum = a + b
        return [0, false] if (b.positive? && sum < a) || (b.negative? && sum > a)
        return [0, false] if sum < MIN_I64 || sum > MAX_I64

        [sum, true]
      end

      def u64_to_i64(v)
        (v & (1 << 63)).zero? ? v : (v - (1 << 64))
      end

      def f64_to_u64(value)
        [value].pack("E").unpack1("Q<")
      end

      def u64_to_f64(bits)
        [bits].pack("Q<").unpack1("E")
      end

      def leading_zeros64(v)
        return 64 if v.zero?

        64 - v.bit_length
      end

      def trailing_zeros64(v)
        return 64 if v.zero?

        (v & -v).bit_length - 1
      end
    end
  end
end
