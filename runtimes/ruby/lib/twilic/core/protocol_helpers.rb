# frozen_string_literal: true

module Twilic
  module Core
    module ProtocolHelpers
      module_function

      def column_null_strategy_local(values, present_bits)
        null_count = values.count { |v| v.kind == Model::ValueKind::NULL }
        return [Model::NullStrategy::ALL_PRESENT_ELIDED, nil, false] if null_count.zero?

        if null_count <= values.length / 4
          inverted = present_bits.map { |bit| !bit }
          return [Model::NullStrategy::INVERTED_PRESENCE_BITMAP, inverted, true]
        end
        [Model::NullStrategy::PRESENCE_BITMAP, present_bits.dup, true]
      end

      def strip_nulls_local(values)
        values.reject { |v| v.kind == Model::ValueKind::NULL }
      end

      def rows_to_columns(rows)
        return nil if rows.empty?

        width = rows.map(&:length).max
        column_values = Array.new(width) { [] }
        column_presence = Array.new(width) { [] }
        rows.each do |row|
          width.times do |col|
            value = col < row.length ? row[col].clone_value : Model.null_value
            column_values[col] << value
            column_presence[col] << (value.kind != Model::ValueKind::NULL)
          end
        end
        Array.new(width) do |col|
          null_strategy, presence, has_presence = column_null_strategy_local(
            column_values[col], column_presence[col]
          )
          codec, tvd = infer_column_codec_and_values(strip_nulls_local(column_values[col]))
          Model::Column.new(
            field_id: col, null_strategy: null_strategy, presence: presence,
            has_presence: has_presence, codec: codec, dictionary_id: nil, values: tvd
          )
        end
      end

      def infer_column_codec_and_values(values)
        return [Model::VectorCodec::PLAIN, Model::TypedVectorData.new(
          kind: Model::ElementType::VALUE, bools: [], i64s: [], u64s: [], f64s: [],
          strings: [], binary: [], values: nil
        )] if values.empty?

        kinds = values.map(&:kind)
        if kinds.all?(Model::ValueKind::I64)
          data = values.map(&:i64)
          return [select_integer_codec(data), typed_data_i64(data)]
        end
        if kinds.all?(Model::ValueKind::U64)
          data = values.map(&:u64)
          return [select_u64_codec(data), typed_data_u64(data)]
        end
        if kinds.all?(Model::ValueKind::F64)
          data = values.map(&:f64)
          return [select_float_codec(data), typed_data_f64(data)]
        end
        if kinds.all?(Model::ValueKind::BOOL)
          data = values.map(&:bool)
          return [Model::VectorCodec::DIRECT_BITPACK, typed_data_bool(data)]
        end
        if kinds.all?(Model::ValueKind::STRING)
          data = values.map(&:str)
          return [select_string_codec(data), typed_data_string(data)]
        end
        cloned = values.map(&:clone_value)
        [Model::VectorCodec::PLAIN, Model::TypedVectorData.new(
          kind: Model::ElementType::VALUE, bools: [], i64s: [], u64s: [], f64s: [],
          strings: [], binary: [], values: cloned
        )]
      end

      def typed_data_i64(data)
        Model::TypedVectorData.new(kind: Model::ElementType::I64, bools: [], i64s: data,
                                   u64s: [], f64s: [], strings: [], binary: [], values: [])
      end

      def typed_data_u64(data)
        Model::TypedVectorData.new(kind: Model::ElementType::U64, bools: [], i64s: [],
                                   u64s: data, f64s: [], strings: [], binary: [], values: [])
      end

      def typed_data_f64(data)
        Model::TypedVectorData.new(kind: Model::ElementType::F64, bools: [], i64s: [],
                                   u64s: [], f64s: data, strings: [], binary: [], values: [])
      end

      def typed_data_bool(data)
        Model::TypedVectorData.new(kind: Model::ElementType::BOOL, bools: data, i64s: [],
                                   u64s: [], f64s: [], strings: [], binary: [], values: [])
      end

      def typed_data_string(data)
        Model::TypedVectorData.new(kind: Model::ElementType::STRING, bools: [], i64s: [],
                                   u64s: [], f64s: [], strings: data, binary: [], values: [])
      end

      def select_integer_codec(values)
        return Model::VectorCodec::PLAIN if values.length < 4

        delta_vals = deltas(values)
        dd = deltas(delta_vals)
        non_zero_dd = (1...dd.length).count { |i| dd[i] != 0 }
        non_zero_ratio = dd.length > 1 ? non_zero_dd.to_f / (dd.length - 1) : 0.0
        delta_range_bits = bit_width_signed(delta_vals.min, delta_vals.max)
        return Model::VectorCodec::DELTA_DELTA_BITPACK if values.length >= 8 &&
          (non_zero_ratio <= 0.25 || delta_range_bits <= 2)

        repeated_ratio, avg_run = run_stats(values)
        return Model::VectorCodec::RLE if repeated_ratio >= 0.5 && avg_run >= 3.0

        range_bits = bit_width_signed(values.min, values.max)
        return Model::VectorCodec::FOR_BITPACK if range_bits <= 60

        monotonic = values.each_cons(2).all? { |a, b| b >= a }
        return Model::VectorCodec::DELTA_FOR_BITPACK if values.length >= 8 && monotonic &&
          delta_range_bits <= range_bits - 3

        max_abs_delta_bits = delta_vals.map { |v| bit_width_u64(abs64(v)) }.max
        return Model::VectorCodec::DELTA_BITPACK if max_abs_delta_bits <= 61

        max_bit_width = values.map { |v| bit_width_u64(abs64(v)) }.max
        return Model::VectorCodec::SIMPLE8B if values.length >= 8 && max_bit_width <= 16 && !monotonic
        return Model::VectorCodec::DIRECT_BITPACK if max_bit_width < 64

        Model::VectorCodec::PLAIN
      end

      def select_u64_codec(values)
        if values.all? { |v| v <= 0x7FFFFFFFFFFFFFFF }
          return select_integer_codec(values.map { |v| v & 0x7FFFFFFFFFFFFFFF })
        end
        return Model::VectorCodec::DIRECT_BITPACK if values.length < 4

        repeated_ratio, avg_run = run_stats_u64(values)
        return Model::VectorCodec::RLE if repeated_ratio >= 0.5 && avg_run >= 3.0

        return Model::VectorCodec::FOR_BITPACK if bit_width_u64(values.max - values.min) <= 60

        max_width = values.map { |v| bit_width_u64(v) }.max
        return Model::VectorCodec::SIMPLE8B if values.length >= 8 && max_width <= 16
        return Model::VectorCodec::DIRECT_BITPACK if max_width < 64

        Model::VectorCodec::PLAIN
      end

      def select_float_codec(values)
        return Model::VectorCodec::PLAIN if values.length < 4

        changes = 0
        prev = [values[0]].pack("E").unpack1("Q<")
        values.each_cons(2) do |_, cur|
          bits = [cur].pack("E").unpack1("Q<")
          changes += 1 if bits != prev
          prev = bits
        end
        changes * 2 <= values.length ? Model::VectorCodec::XOR_FLOAT : Model::VectorCodec::PLAIN
      end

      def select_string_codec(values)
        return Model::VectorCodec::PLAIN if values.empty?

        return Model::VectorCodec::DICTIONARY if values.uniq.length * 2 <= values.length

        prefix_gain = 0
        prev = ""
        values.each do |v|
          prefix_gain += common_prefix_len(prev.b, v.b)
          prev = v
        end
        return Model::VectorCodec::PREFIX_DELTA if prefix_gain > values.length * 2

        Model::VectorCodec::PLAIN
      end

      def deltas(values)
        values.each_with_index.map { |value, i| i.zero? ? value : value - values[i - 1] }
      end

      def run_stats(values)
        return [0.0, 0.0] if values.empty?

        runs = []
        run_len = 1
        (1...values.length).each do |i|
          if values[i] == values[i - 1]
            run_len += 1
          else
            runs << run_len
            run_len = 1
          end
        end
        runs << run_len
        repeated_items = runs.select { |r| r > 1 }.sum
        [repeated_items.to_f / values.length, runs.sum.to_f / runs.length]
      end

      def run_stats_u64(values)
        run_stats(values)
      end

      def bit_width_signed(min, max)
        range_val = max >= min ? max - min : min - max
        bit_width_u64(range_val)
      end

      def bit_width_u64(v)
        return 1 if v.zero?

        v.to_s(2).length
      end

      def abs64(v)
        v.negative? ? -v : v
      end

      def common_prefix_len(a, b)
        n = [a.bytesize, b.bytesize].min
        i = 0
        while i < n && a.getbyte(i) == b.getbyte(i)
          i += 1
        end
        i
      end

      def rle_encode_bytes(input)
        return nil if input.empty?

        out = +""
        i = 0
        while i < input.bytesize
          j = i + 1
          while j < input.bytesize && input.getbyte(j) == input.getbyte(i) && j - i < 255
            j += 1
          end
          out << (j - i).chr << input[i].chr
          i = j
        end
        out
      end

      def rle_decode_bytes(input)
        out = +""
        i = 0
        while i < input.bytesize
          raise Errors.invalid_data("rle payload") if i + 1 >= input.bytesize

          run = input.getbyte(i)
          b = input.getbyte(i + 1)
          run.times { out << b.chr }
          i += 2
        end
        out
      end

      def control_bitpack_encode_bytes(input)
        input.b.dup
      end

      def control_bitpack_decode_bytes(input)
        input.b.dup
      end

      def control_huffman_encode_bytes(input)
        input.dup
      end

      def control_huffman_decode_bytes(input)
        input.dup
      end

      def control_fse_encode_bytes(input)
        input.dup
      end

      def control_fse_decode_bytes(input)
        input.dup
      end

      def template_descriptor_from_columns(template_id, columns)
        Model::TemplateDescriptor.new(
          template_id: template_id,
          field_ids: columns.map(&:field_id),
          null_strategies: columns.map(&:null_strategy),
          codecs: columns.map(&:codec)
        )
      end

      def find_template_id(templates, columns)
        templates.keys.sort.each do |id|
          t = templates[id]
          next if t.field_ids.length != columns.length

          ok = t.field_ids.each_with_index.all? do |fid, i|
            fid == columns[i].field_id && t.null_strategies[i] == columns[i].null_strategy
          end
          return [id, true] if ok
        end
        [0, false]
      end

      def diff_template_columns(previous, current)
        mask = Array.new(current.length, false)
        changed = []
        current.each_with_index do |col, i|
          if i >= previous.length || estimate_column_size(previous[i]) != estimate_column_size(col)
            mask[i] = true
            changed << col
          end
        end
        [mask, changed]
      end

      def merge_template_columns(previous, changed_mask, changed)
        out = Array.new(changed_mask.length)
        idx = 0
        changed_mask.each_with_index do |bit, i|
          if bit
            raise Errors.invalid_data("template changed column count mismatch") if idx >= changed.length

            out[i] = changed[idx]
            idx += 1
          else
            raise Errors.invalid_data("template reference out of range") if i >= previous.length

            out[i] = previous[i]
          end
        end
        out
      end

      def diff_message(prev, current)
        a = message_fields(prev)
        b = message_fields(current)
        n = [a.length, b.length].max
        ops = []
        n.times do |i|
          if i < a.length && i < b.length
            if Model.equal(a[i], b[i])
              ops << Model::PatchOperation.new(field_id: i, opcode: Model::PatchOpcode::KEEP, value: nil)
            else
              ops << Model::PatchOperation.new(
                field_id: i, opcode: Model::PatchOpcode::REPLACE_SCALAR, value: b[i].clone_value
              )
            end
          elsif i < b.length
            ops << Model::PatchOperation.new(
              field_id: i, opcode: Model::PatchOpcode::INSERT_FIELD, value: b[i].clone_value
            )
          else
            ops << Model::PatchOperation.new(field_id: i, opcode: Model::PatchOpcode::DELETE_FIELD, value: nil)
          end
        end
        [ops, 0]
      end

      def message_fields(message)
        case message.kind
        when Model::MessageKind::ARRAY
          message.array.map(&:clone_value)
        when Model::MessageKind::MAP
          message.map.map { |e| e.value.clone_value }
        when Model::MessageKind::SHAPED_OBJECT
          message.shaped_object.values.map(&:clone_value)
        when Model::MessageKind::SCHEMA_OBJECT
          message.schema_object.fields.map(&:clone_value)
        else
          []
        end
      end

      def rebuild_message_like(base, fields)
        case base.kind
        when Model::MessageKind::ARRAY
          Model.message(kind: Model::MessageKind::ARRAY, array: fields)
        when Model::MessageKind::MAP
          entries = fields.each_with_index.map do |value, i|
            raise Errors.invalid_data("patch map shape mismatch") if i >= base.map.length

            Model::MessageMapEntry.new(key: base.map[i].key, value: value)
          end
          Model.message(kind: Model::MessageKind::MAP, map: entries)
        when Model::MessageKind::SHAPED_OBJECT
          s = base.shaped_object
          Model.message(kind: Model::MessageKind::SHAPED_OBJECT, shaped_object: Model::ShapedObjectMessage.new(
            shape_id: s.shape_id, presence: s.presence&.dup, has_presence: s.has_presence, values: fields
          ))
        when Model::MessageKind::SCHEMA_OBJECT
          s = base.schema_object
          Model.message(kind: Model::MessageKind::SCHEMA_OBJECT, schema_object: Model::SchemaObjectMessage.new(
            schema_id: s.schema_id, presence: s.presence&.dup, has_presence: s.has_presence, fields: fields
          ))
        else
          raise Errors.invalid_data("state patch reconstruction unsupported for this message kind")
        end
      end

      def estimate_message_size(message)
        case message.kind
        when Model::MessageKind::SCALAR
          1 + estimate_value_size(message.scalar)
        when Model::MessageKind::ARRAY
          1 + varuint_size(message.array.length) + message.array.sum { |v| estimate_value_size(v) }
        when Model::MessageKind::MAP
          1 + varuint_size(message.map.length) +
            message.map.sum { |e| encoded_key_ref_size(e.key) + estimate_value_size(e.value) }
        when Model::MessageKind::STATE_PATCH
          sp = message.state_patch
          1 + 2 + varuint_size(sp.operations.length) +
            sp.operations.sum do |op|
              varuint_size(op.field_id) + 2 + (op.value ? estimate_value_size(op.value) : 0)
            end
        else
          16
        end
      end

      def estimate_column_size(column)
        size = varuint_size(column.field_id) + 4
        case column.values.kind
        when Model::ElementType::BOOL
          size + column.values.bools.length / 8 + 2
        when Model::ElementType::I64
          size + column.values.i64s.length * 4
        when Model::ElementType::U64
          size + column.values.u64s.length * 4
        when Model::ElementType::F64
          size + column.values.f64s.length * 8
        when Model::ElementType::STRING
          size + column.values.strings.sum { |s| encoded_string_size(s) }
        else
          size
        end
      end

      def estimate_value_size(value)
        case value.kind
        when Model::ValueKind::NULL, Model::ValueKind::BOOL then 1
        when Model::ValueKind::I64 then 2 + smallest_u64_size(Wire.encode_zigzag(value.i64))
        when Model::ValueKind::U64 then 2 + smallest_u64_size(value.u64)
        when Model::ValueKind::F64 then 9
        when Model::ValueKind::STRING then 2 + encoded_string_size(value.str)
        when Model::ValueKind::BINARY then 1 + encoded_bytes_size(value.bin.bytesize)
        when Model::ValueKind::ARRAY
          1 + varuint_size(value.arr.length) + value.arr.sum { |v| estimate_value_size(v) }
        when Model::ValueKind::MAP
          1 + varuint_size(value.map.length) +
            value.map.sum { |e| encoded_string_size(e.key) + estimate_value_size(e.value) }
        else
          1
        end
      end

      def encoded_bytes_size(length)
        varuint_size(length) + length
      end

      def encoded_string_size(value)
        encoded_bytes_size(value.b.bytesize)
      end

      def encoded_key_ref_size(key)
        if key.is_id
          1 + varuint_size(key.id)
        else
          encoded_string_size(key.literal)
        end
      end

      def varuint_size(value)
        sz = 1
        while value >= 0x80
          value >>= 7
          sz += 1
        end
        sz
      end

      def smallest_u64_size(value)
        if value <= 0xFF then 1
        elsif value <= 0xFFFF then 2
        elsif value <= 0xFFFFFFFF then 4
        else 8
        end
      end

      def key_ref_field_identity(key, state)
        s = key_ref_string(key, state)
        s.empty? ? nil : s
      end

      def key_ref_string(key, state)
        if key.is_id
          s, ok = state.key_table.get_value(key.id)
          return s if ok

          return ""
        end
        key.literal
      end
    end
  end
end
