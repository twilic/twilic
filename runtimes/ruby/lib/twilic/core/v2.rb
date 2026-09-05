# frozen_string_literal: true

require "twilic/core/errors"
require "twilic/core/model"
require "twilic/core/wire"

module Twilic
  module Core
    module V2
      NULL_TAG = 0xC0
      FALSE_TAG = 0xC1
      TRUE_TAG = 0xC2
      F64_TAG = 0xC3
      U8_TAG = 0xC4
      U16_TAG = 0xC5
      U32_TAG = 0xC6
      U64_TAG = 0xC7
      I8_TAG = 0xC8
      I16_TAG = 0xC9
      I32_TAG = 0xCA
      I64_TAG = 0xCB
      BIN8_TAG = 0xCC
      BIN16_TAG = 0xCD
      BIN32_TAG = 0xCE
      STR8_TAG = 0xCF
      STR16_TAG = 0xD0
      STR32_TAG = 0xD1
      ARRAY16_TAG = 0xD2
      ARRAY32_TAG = 0xD3
      MAP16_TAG = 0xD4
      MAP32_TAG = 0xD5
      SHAPE_DEF_TAG = 0xD6
      KEY_REF_TAG = 0xD8
      STR_REF_TAG = 0xD9

      class EncodeState
        attr_accessor :key_ids, :str_ids, :shape_ids, :next_key_id, :next_str_id, :next_shape_id

        def initialize
          @key_ids = {}
          @str_ids = {}
          @shape_ids = {}
          @next_key_id = 0
          @next_str_id = 0
          @next_shape_id = 0
        end
      end

      class DecodeState
        attr_accessor :keys, :strings, :shapes

        def initialize
          @keys = []
          @strings = []
          @shapes = []
        end
      end

      module_function

      def encode_v2(value)
        out = +""
        state = EncodeState.new
        encode_v2_value(value, out, state)
        out
      end

      def decode_v2(bytes)
        reader = Wire::Reader.new(bytes)
        state = DecodeState.new
        value = decode_v2_value(reader, state)
        raise Errors.invalid_data("trailing bytes in v2 decode") unless reader.eof?

        value
      end

      def encode_v2_value(value, out, state)
        case value.kind
        when Model::ValueKind::NULL
          out << NULL_TAG.chr
        when Model::ValueKind::BOOL
          out << (value.bool ? TRUE_TAG : FALSE_TAG).chr
        when Model::ValueKind::I64
          encode_v2_i64(value.i64, out)
        when Model::ValueKind::U64
          encode_v2_u64(value.u64, out)
        when Model::ValueKind::F64
          out << F64_TAG.chr
          Wire.append_f64_le(out, value.f64)
        when Model::ValueKind::STRING
          if state.str_ids.key?(value.str)
            out << STR_REF_TAG.chr
            Wire.encode_varuint(state.str_ids[value.str], out)
          else
            encode_v2_string_literal(value.str, out)
            state.str_ids[value.str] = state.next_str_id
            state.next_str_id += 1
          end
        when Model::ValueKind::BINARY
          encode_v2_binary(value.bin, out)
        when Model::ValueKind::ARRAY
          encode_v2_array(value.arr, out, state)
        when Model::ValueKind::MAP
          encode_v2_map(value.map, out, state)
        else
          raise Errors.invalid_data("unsupported value kind")
        end
      end

      def encode_v2_array(values, out, state)
        shape_keys = detect_shape_keys(values)
        if shape_keys
          sk = shape_keys.join("\0")
          shape_id = state.shape_ids[sk]
          unless shape_id
            shape_id = state.next_shape_id
            state.next_shape_id += 1
            state.shape_ids[sk] = shape_id
          end
          write_v2_array_header(values.length, out)
          out << SHAPE_DEF_TAG.chr
          Wire.encode_varuint(shape_id, out)
          Wire.encode_varuint(shape_keys.length, out)
          shape_keys.each { |key| encode_v2_key(key, out, state) }
          values.each do |value|
            raise Errors.invalid_data("shape array row must be map") unless value.kind == Model::ValueKind::MAP

            value.map.each { |field| encode_v2_value(field.value, out, state) }
          end
          return
        end
        write_v2_array_header(values.length, out)
        values.each { |value| encode_v2_value(value, out, state) }
      end

      def encode_v2_map(entries, out, state)
        write_v2_map_header(entries.length, out)
        entries.each do |entry|
          encode_v2_key(entry.key, out, state)
          encode_v2_value(entry.value, out, state)
        end
      end

      def encode_v2_key(key, out, state)
        if state.key_ids.key?(key)
          out << KEY_REF_TAG.chr
          Wire.encode_varuint(state.key_ids[key], out)
          return
        end
        encode_v2_string_literal(key, out)
        state.key_ids[key] = state.next_key_id
        state.next_key_id += 1
      end

      def encode_v2_string_literal(value, out)
        bytes = value.b
        if bytes.bytesize <= 31
          out << (0x80 | bytes.bytesize).chr
        elsif bytes.bytesize <= 0xFF
          out << STR8_TAG.chr << bytes.bytesize.chr
        elsif bytes.bytesize <= 0xFFFF
          out << STR16_TAG.chr << [bytes.bytesize].pack("v")
        else
          out << STR32_TAG.chr << [bytes.bytesize].pack("V")
        end
        out << bytes
      end

      def encode_v2_binary(value, out)
        if value.bytesize <= 0xFF
          out << BIN8_TAG.chr << value.bytesize.chr
        elsif value.bytesize <= 0xFFFF
          out << BIN16_TAG.chr << [value.bytesize].pack("v")
        else
          out << BIN32_TAG.chr << [value.bytesize].pack("V")
        end
        out << value
      end

      def encode_v2_u64(value, out)
        if value <= 127
          out << value.chr
        elsif value <= 0xFF
          out << U8_TAG.chr << value.chr
        elsif value <= 0xFFFF
          out << U16_TAG.chr << [value].pack("v")
        elsif value <= 0xFFFFFFFF
          out << U32_TAG.chr << [value].pack("V")
        else
          out << U64_TAG.chr
          Wire.append_u64_le(out, value)
        end
      end

      def encode_v2_i64(value, out)
        if value >= -32 && value <= -1
          out << (value & 0xFF).chr
        elsif value >= 0 && value <= 127
          out << value.chr
        elsif value >= -128 && value <= 127
          out << I8_TAG.chr << [value].pack("c")
        elsif value >= -32_768 && value <= 32_767
          out << I16_TAG.chr << [value].pack("s<")
        elsif value >= -2_147_483_648 && value <= 2_147_483_647
          out << I32_TAG.chr << [value].pack("l<")
        else
          out << I64_TAG.chr
          Wire.append_u64_le(out, value & 0xFFFFFFFFFFFFFFFF)
        end
      end

      def write_v2_array_header(length, out)
        if length <= 15
          out << (0xA0 | length).chr
        elsif length <= 0xFFFF
          out << ARRAY16_TAG.chr << [length].pack("v")
        else
          out << ARRAY32_TAG.chr << [length].pack("V")
        end
      end

      def write_v2_map_header(length, out)
        if length <= 15
          out << (0xB0 | length).chr
        elsif length <= 0xFFFF
          out << MAP16_TAG.chr << [length].pack("v")
        else
          out << MAP32_TAG.chr << [length].pack("V")
        end
      end

      def detect_shape_keys(values)
        return nil if values.length < 2
        return nil unless values[0].kind == Model::ValueKind::MAP && !values[0].map.empty?

        keys = values[0].map.map(&:key)
        values[1..].each do |value|
          return nil unless value.kind == Model::ValueKind::MAP && value.map.length == keys.length

          value.map.each_with_index { |e, i| return nil unless e.key == keys[i] }
        end
        keys
      end

      def decode_v2_value(reader, state)
        tag = reader.read_u8
        decode_v2_value_from_tag(reader, state, tag)
      end

      def decode_v2_value_from_tag(reader, state, tag)
        case tag
        when 0..0x7F
          Model.u64_value(tag)
        when 0x80..0x9F
          length = tag & 0x1F
          s = reader.read_exact(length).force_encoding(Encoding::UTF_8)
          state.strings << s
          Model.string_value(s)
        when 0xA0..0xAF
          decode_v2_array_body(reader, state, tag & 0x0F)
        when 0xB0..0xBF
          decode_v2_map_body(reader, state, tag & 0x0F)
        when 0xE0..0xFF
          Model.i64_value(tag - 256)
        when NULL_TAG
          Model.null_value
        when FALSE_TAG
          Model.bool_value(false)
        when TRUE_TAG
          Model.bool_value(true)
        when F64_TAG
          Model.f64_value(reader.read_f64_le)
        when U8_TAG
          Model.u64_value(reader.read_u8)
        when U16_TAG
          Model.u64_value(reader.read_exact(2).unpack1("v"))
        when U32_TAG
          Model.u64_value(reader.read_exact(4).unpack1("V"))
        when U64_TAG
          Model.u64_value(reader.read_u64_le)
        when I8_TAG
          Model.i64_value(reader.read_exact(1).unpack1("c"))
        when I16_TAG
          Model.i64_value(reader.read_exact(2).unpack1("s<"))
        when I32_TAG
          Model.i64_value(reader.read_exact(4).unpack1("l<"))
        when I64_TAG
          Model.i64_value(reader.read_exact(8).unpack1("q<"))
        when BIN8_TAG
          Model.binary_value(reader.read_exact(reader.read_u8))
        when BIN16_TAG
          Model.binary_value(reader.read_exact(reader.read_exact(2).unpack1("v")))
        when BIN32_TAG
          Model.binary_value(reader.read_exact(reader.read_exact(4).unpack1("V")))
        when STR8_TAG, STR16_TAG, STR32_TAG
          decode_v2_string_tag(reader, state, tag)
        when ARRAY16_TAG
          decode_v2_array_body(reader, state, reader.read_exact(2).unpack1("v"))
        when ARRAY32_TAG
          decode_v2_array_body(reader, state, reader.read_exact(4).unpack1("V"))
        when MAP16_TAG
          decode_v2_map_body(reader, state, reader.read_exact(2).unpack1("v"))
        when MAP32_TAG
          decode_v2_map_body(reader, state, reader.read_exact(4).unpack1("V"))
        when STR_REF_TAG
          id = reader.read_varuint
          raise Errors.invalid_data("unknown str_ref id") if id >= state.strings.length

          Model.string_value(state.strings[id])
        else
          raise Errors.invalid_tag(tag)
        end
      end

      def decode_v2_string_tag(reader, state, tag)
        length = case tag
                 when STR8_TAG then reader.read_u8
                 when STR16_TAG then reader.read_exact(2).unpack1("v")
                 when STR32_TAG then reader.read_exact(4).unpack1("V")
                 else raise Errors.invalid_data("invalid string tag")
                 end
        s = reader.read_exact(length).force_encoding(Encoding::UTF_8)
        state.strings << s
        Model.string_value(s)
      end

      def decode_v2_array_body(reader, state, length)
        reader.claim_output(length)
        reader.with_depth { decode_v2_array_body_inner(reader, state, length) }
      end

      def decode_v2_array_body_inner(reader, state, length)
        return Model.array_value([]) if length.zero?

        first_tag = reader.read_u8
        if first_tag == SHAPE_DEF_TAG
          shape_id = reader.read_count(65535)
          key_count = reader.read_count(256)
          keys = Array.new(key_count) { decode_v2_key(reader, state) }
          while state.shapes.length <= shape_id
            state.shapes << nil
          end
          state.shapes[shape_id] = keys
          values = Array.new(length) do
            reader.claim_output(keys.length)
            row = keys.map do |key|
              val = decode_v2_value(reader, state)
              Model.entry(key, val)
            end
            Model.map_value(row)
          end
          return Model.array_value(values)
        end
        values = Array.new(length)
        values[0] = decode_v2_value_from_tag(reader, state, first_tag)
        (1...length).each { |i| values[i] = decode_v2_value(reader, state) }
        Model.array_value(values)
      end

      def decode_v2_map_body(reader, state, length)
        reader.claim_output(length)
        reader.with_depth { decode_v2_map_body_inner(reader, state, length) }
      end

      def decode_v2_map_body_inner(reader, state, length)
        entries = Array.new(length) do
          key = decode_v2_key(reader, state)
          value = decode_v2_value(reader, state)
          Model.entry(key, value)
        end
        Model.map_value(entries)
      end

      def decode_v2_key(reader, state)
        tag = reader.read_u8
        if tag == KEY_REF_TAG
          id = reader.read_varuint
          raise Errors.invalid_data("unknown key_ref id") if id >= state.keys.length

          return state.keys[id]
        end
        if (0x80..0x9F).cover?(tag)
          key = reader.read_exact(tag & 0x1F).force_encoding(Encoding::UTF_8)
          state.keys << key
          return key
        end
        if [STR8_TAG, STR16_TAG, STR32_TAG].include?(tag)
          v = decode_v2_value_from_tag(reader, state, tag)
          raise Errors.invalid_data("expected string key") unless v.kind == Model::ValueKind::STRING

          state.keys << v.str
          return v.str
        end
        raise Errors.invalid_data("map key must be key_ref or string")
      end
    end
  end
end
