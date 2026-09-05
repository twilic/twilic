# frozen_string_literal: true

require "digest"

module Twilic
  module Core
    module Dictionary
      module_function

      def decode_trained_dictionary_payload(payload)
        reader = Wire::Reader.new(payload)
        n = reader.read_count
        values = []
        n.times do
          values << reader.read_string
        end
        raise Errors.invalid_data("trained dictionary payload trailing bytes") unless reader.eof?

        values
      end

      def encode_trained_dictionary_block(values, dictionary)
        if values.empty?
          out = +""
          out << "\x00"
          Wire.encode_varuint(0, out)
          return [out, true]
        end
        by_value = {}
        dictionary.each_with_index { |v, idx| by_value[v] = idx }
        ids = values.map do |value|
          id = by_value[value]
          return [nil, false] unless id

          id
        end
        raw = +""
        raw << "\x00"
        Wire.encode_varuint(ids.length, raw)
        ids.each { |id| Wire.encode_varuint(id, raw) }
        max_id = ids.max || 0
        bit_width = max_id.zero? ? 0 : (64 - max_id.to_s(2).length)
        packed = +""
        pack_fixed_width_u64(ids, bit_width, packed)
        bitpacked = +""
        bitpacked << "\x01"
        Wire.encode_varuint(ids.length, bitpacked)
        bitpacked << bit_width.chr
        bitpacked << packed
        return [bitpacked, true] if bitpacked.bytesize < raw.bytesize

        [raw, true]
      end

      def decode_trained_dictionary_block(block, dictionary)
        reader = Wire::Reader.new(block)
        mode = reader.read_u8
        n = reader.read_count
        ids = case mode
              when 0
                Array.new(n) { reader.read_varuint }
              when 1
                bit_width = reader.read_u8
                remaining = block.bytesize - reader.position
                packed = reader.read_exact(remaining)
                unpack_fixed_width_u64(packed, n, bit_width)
              else
                raise Errors.invalid_data("trained dictionary block mode")
              end
        raise Errors.invalid_data("trained dictionary block trailing bytes") unless reader.eof?

        ids.map do |id|
          raise Errors.invalid_data("trained dictionary block id") if id >= dictionary.length

          dictionary[id]
        end
      end

      WideU128 = Data.define(:lo, :hi)

      def wide_from_u64(v)
        WideU128.new(lo: v, hi: 0)
      end

      def wide_mask(width)
        if width == 64
          WideU128.new(lo: 0xFFFFFFFFFFFFFFFF, hi: 0xFFFFFFFFFFFFFFFF)
        elsif width.zero?
          WideU128.new(lo: 0, hi: 0)
        elsif width <= 64
          WideU128.new(lo: (1 << width) - 1, hi: 0)
        else
          WideU128.new(lo: 0xFFFFFFFFFFFFFFFF, hi: (1 << (width - 64)) - 1)
        end
      end

      def pack_fixed_width_u64(values, width, out)
        raise Errors.invalid_data("fixed-width u64 bit width") if width > 64

        if width.zero?
          values.each do |value|
            raise Errors.invalid_data("fixed-width u64 value overflow") unless value.zero?
          end
          return
        end
        acc = WideU128.new(lo: 0, hi: 0)
        acc_bits = 0
        values.each do |value|
          raise Errors.invalid_data("fixed-width u64 value overflow") if width < 64 && (value >> width) != 0

          acc = wide_or(acc, wide_shl(wide_from_u64(value), acc_bits))
          acc_bits += width
          while acc_bits >= 8
            out << (acc.lo & 0xFF).chr
            acc = wide_shr(acc, 8)
            acc_bits -= 8
          end
        end
        out << (acc.lo & 0xFF).chr if acc_bits.positive?
      end

      def unpack_fixed_width_u64(bytes, count, width)
        raise Errors.invalid_data("fixed-width u64 bit width") if width > 64

        if width.zero?
          bytes.each { |b| raise Errors.invalid_data("fixed-width u64 trailing bytes") unless b.zero? }
          return Array.new(count, 0)
        end
        out = []
        acc = WideU128.new(lo: 0, hi: 0)
        acc_bits = 0
        idx = 0
        mask = wide_mask(width)
        count.times do
          while acc_bits < width
            raise Errors.invalid_data("fixed-width u64 underflow") if idx >= bytes.bytesize

            acc = wide_or(acc, wide_shl(wide_from_u64(bytes.getbyte(idx)), acc_bits))
            idx += 1
            acc_bits += 8
          end
          out << wide_and(acc, mask).lo
          acc = wide_shr(acc, width)
          acc_bits -= width
        end
        raise Errors.invalid_data("fixed-width u64 trailing bytes") unless wide_zero?(acc)
        while idx < bytes.bytesize
          raise Errors.invalid_data("fixed-width u64 trailing bytes") unless bytes.getbyte(idx).zero?

          idx += 1
        end
        out
      end

      def wide_zero?(w)
        w.lo.zero? && w.hi.zero?
      end

      def wide_and(a, m)
        WideU128.new(lo: a.lo & m.lo, hi: a.hi & m.hi)
      end

      def wide_or(a, b)
        WideU128.new(lo: a.lo | b.lo, hi: a.hi | b.hi)
      end

      def wide_shl(w, n)
        return w if n.zero?
        return WideU128.new(lo: 0, hi: 0) if n >= 128

        if n < 64
          hi = ((w.hi << n) | (w.lo >> (64 - n))) & 0xFFFFFFFFFFFFFFFF
          lo = (w.lo << n) & 0xFFFFFFFFFFFFFFFF
          WideU128.new(lo: lo, hi: hi)
        else
          n -= 64
          WideU128.new(lo: 0, hi: (w.lo << n) & 0xFFFFFFFFFFFFFFFF)
        end
      end

      def wide_shr(w, n)
        return w if n.zero?
        return WideU128.new(lo: 0, hi: 0) if n >= 128

        if n < 64
          lo = ((w.lo >> n) | (w.hi << (64 - n))) & 0xFFFFFFFFFFFFFFFF
          hi = w.hi >> n
          WideU128.new(lo: lo, hi: hi)
        else
          n -= 64
          WideU128.new(lo: w.hi >> n, hi: 0)
        end
      end

      def apply_dictionary_references(state, columns)
        columns.each_with_index do |column, i|
          next unless column.values.kind == Model::ElementType::STRING

          values = column.values.strings
          next if values.length < 16

          unique = values.uniq
          next if unique.length.to_f / values.length > 0.5

          codec = column.codec
          next unless codec == Model::VectorCodec::DICTIONARY || codec == Model::VectorCodec::STRING_REF

          dict_id = state.allocate_dictionary_id
          payload = +""
          keys = unique.sort
          Wire.encode_varuint(keys.length, payload)
          keys.each { |item| Wire.encode_string(item, payload) }
          profile = Session::DictionaryProfile.new(
            version: 1,
            hash: dictionary_payload_hash(payload),
            expires_at: 0,
            fallback: state.options.unknown_reference_policy == Session::UnknownReferencePolicy::STATELESS_RETRY ?
              Session::DictionaryFallback::STATELESS_RETRY : Session::DictionaryFallback::FAIL_FAST
          )
          state.dictionaries[dict_id] = payload
          state.dictionary_profiles[dict_id] = profile
          columns[i] = column.with(dictionary_id: dict_id)
        end
      end

      def dictionary_payload_hash(payload)
        h = 0xCBF29CE484222325
        payload.each_byte do |b|
          h ^= b
          h = (h * 0x00000100000001B1) & 0xFFFFFFFFFFFFFFFF
        end
        h
      end
    end
  end
end
