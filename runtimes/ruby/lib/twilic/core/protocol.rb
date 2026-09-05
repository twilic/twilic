# frozen_string_literal: true

require "twilic/core/model"
require "twilic/core/wire"
require "twilic/core/codec"
require "twilic/core/session"
require "twilic/core/dictionary"
require "twilic/core/errors"
require "twilic/core/v2"

module Twilic
  module Core
    module Protocol

      def self.new_twilic_codec
        TwilicCodec.new
      end

      def self.twilic_codec_with_options(options)
        TwilicCodec.new(options)
      end

      TAG_NULL = 0
      TAG_BOOL_FALSE = 1
      TAG_BOOL_TRUE = 2
      TAG_I64 = 3
      TAG_U64 = 4
      TAG_F64 = 5
      TAG_STRING = 6
      TAG_BINARY = 7
      TAG_ARRAY = 8
      TAG_MAP = 9

      class TwilicCodec
        attr_accessor :state

        def initialize(options = nil)
          @state = options ? Session::MutableSessionState.new(options) : Session::MutableSessionState.new
          @state.key_table = Session::MutableInternTable.new
          @state.string_table = Session::MutableInternTable.new
          @state.shape_table = Session::MutableShapeTable.new
        end

        def self.new_twilic_codec
          new
        end

        def self.twilic_codec_with_options(options)
          new(options)
        end

        def encode_message(message)
          out = +""
          write_message(message, out)
          out
        end

        def decode_message(bytes)
          reader = Wire::Reader.new(bytes)
          msg = read_message(reader)
          raise Errors.invalid_data("trailing bytes in message") unless reader.eof?

          case msg.kind
          when Model::MessageKind::CONTROL
            # control does not update previous message body
          when Model::MessageKind::STATE_PATCH
            begin
              reconstructed = apply_state_patch(
                msg.state_patch.base_ref,
                msg.state_patch.operations,
                msg.state_patch.literals
              )
              @state.previous_message = reconstructed
              @state.previous_message_size = bytes.bytesize
            rescue StandardError => e
              raise e if Errors.unknown_reference?(e) || Errors.stateless_retry?(e)
            end
          when Model::MessageKind::TEMPLATE_BATCH
            if @state.previous_message.nil?
              @state.previous_message = msg.clone_message
              @state.previous_message_size = bytes.bytesize
            end
          else
            @state.previous_message = msg.clone_message
            @state.previous_message_size = bytes.bytesize
          end
          msg
        end

        def encode_value(value)
          msg = message_for_value(value)
          out = encode_message(msg)
          @state.previous_message = msg.clone_message
          @state.previous_message_size = out.bytesize
          out
        end

        def decode_value(bytes)
          msg = decode_message(bytes)
          @state.previous_message = msg.clone_message
          case msg.kind
          when Model::MessageKind::SCALAR
            msg.scalar.clone_value
          when Model::MessageKind::ARRAY
            Model.array_value(msg.array)
          when Model::MessageKind::MAP
            entries = entries_to_map(msg.map, @state)
            Model.map_value(entries)
          when Model::MessageKind::SHAPED_OBJECT
            keys, ok = @state.shape_table.get_keys(msg.shaped_object.shape_id)
            raise reference_error("shape_id", msg.shaped_object.shape_id) unless ok

            Model.map_value(
              shape_values_to_map(
                keys,
                msg.shaped_object.presence,
                msg.shaped_object.has_presence,
                msg.shaped_object.values
              )
            )
          when Model::MessageKind::TYPED_VECTOR
            typed_vector_to_value(msg.typed_vector)
          else
            raise Errors.invalid_data("decode_value expects scalar/array/map/vector message")
          end
        end

        def reference_error(kind, id)
          if @state.options.unknown_reference_policy == Session::UnknownReferencePolicy::STATELESS_RETRY
            raise Errors.stateless_retry_required(kind, id)
          end
          raise Errors.unknown_reference(kind, id)
        end

        def shape_key(keys)
          @state.shape_table.shape_key(keys)
        end

        def message_for_value(value)
          case value.kind
          when Model::ValueKind::ARRAY
            vec, ok = try_make_typed_vector(value.arr)
            return Model.message(kind: Model::MessageKind::TYPED_VECTOR, typed_vector: vec) if ok

            arr = value.arr.map(&:clone_value)
            Model.message(kind: Model::MessageKind::ARRAY, array: arr)
          when Model::ValueKind::MAP
            keys = value.map.map(&:key)
            had_observation = @state.encode_shape_observations.key?(shape_key(keys))
            obs = observe_encode_shape_candidate(keys)
            shape_id, ok = @state.shape_table.get_id(keys)
            return shaped_message(shape_id, value.map) if ok && (!had_observation || obs >= 2)

            map_message(value.map)
          else
            sc = value.clone_value
            Model.message(kind: Model::MessageKind::SCALAR, scalar: sc)
          end
        end

        def map_message(entries)
          out = entries.map do |entry|
            key = entry.key
            id, ok = @state.key_table.get_id(key)
            key_ref = if ok
                        Model::KeyRef.id_ref(id)
                      else
                        @state.key_table.register(key)
                        Model::KeyRef.literal(key)
                      end
            Model::MessageMapEntry.new(key: key_ref, value: entry.value.clone_value)
          end
          Model.message(kind: Model::MessageKind::MAP, map: out)
        end

        def shaped_message(shape_id, entries)
          keys, = @state.shape_table.get_keys(shape_id)
          index = {}
          entries.each { |entry| index[entry.key] = entry.value }

          values = []
          presence = Array.new(keys.length, false)
          all = true
          keys.each_with_index do |key, i|
            v = index[key]
            if v
              presence[i] = true
              values << v.clone_value
            else
              presence[i] = false
              all = false
            end
          end

          msg = Model::ShapedObjectMessage.new(
            shape_id: shape_id,
            values: values,
            has_presence: !all,
            presence: all ? nil : presence
          )
          Model.message(kind: Model::MessageKind::SHAPED_OBJECT, shaped_object: msg)
        end

        def try_make_typed_vector(values)
          return [nil, false] if values.length < 4

          all_bool = true
          all_i64 = true
          all_u64 = true
          all_f64 = true
          all_str = true
          values.each do |value|
            case value.kind
            when Model::ValueKind::BOOL
              all_i64 = false
              all_u64 = false
              all_f64 = false
              all_str = false
            when Model::ValueKind::I64
              all_bool = false
              all_u64 = false
              all_f64 = false
              all_str = false
            when Model::ValueKind::U64
              all_bool = false
              all_i64 = false
              all_f64 = false
              all_str = false
            when Model::ValueKind::F64
              all_bool = false
              all_i64 = false
              all_u64 = false
              all_str = false
            when Model::ValueKind::STRING
              all_bool = false
              all_i64 = false
              all_u64 = false
              all_f64 = false
            else
              return [nil, false]
            end
          end

          if all_bool
            bools = values.map(&:bool)
            return [
              Model::TypedVector.new(
                element_type: Model::ElementType::BOOL,
                codec: Model::VectorCodec::DIRECT_BITPACK,
                data: Model::TypedVectorData.new(
                  kind: Model::ElementType::BOOL,
                  bools: bools,
                  i64s: [],
                  u64s: [],
                  f64s: [],
                  strings: [],
                  binary: [],
                  values: []
                )
              ),
              true
            ]
          end

          if all_i64
            vals = values.map(&:i64)
            return [
              Model::TypedVector.new(
                element_type: Model::ElementType::I64,
                codec: select_integer_codec(vals),
                data: Model::TypedVectorData.new(
                  kind: Model::ElementType::I64,
                  bools: [],
                  i64s: vals,
                  u64s: [],
                  f64s: [],
                  strings: [],
                  binary: [],
                  values: []
                )
              ),
              true
            ]
          end

          if all_u64
            vals = values.map(&:u64)
            return [
              Model::TypedVector.new(
                element_type: Model::ElementType::U64,
                codec: select_u64_codec(vals),
                data: Model::TypedVectorData.new(
                  kind: Model::ElementType::U64,
                  bools: [],
                  i64s: [],
                  u64s: vals,
                  f64s: [],
                  strings: [],
                  binary: [],
                  values: []
                )
              ),
              true
            ]
          end

          if all_f64
            vals = values.map(&:f64)
            return [
              Model::TypedVector.new(
                element_type: Model::ElementType::F64,
                codec: select_float_codec(vals),
                data: Model::TypedVectorData.new(
                  kind: Model::ElementType::F64,
                  bools: [],
                  i64s: [],
                  u64s: [],
                  f64s: vals,
                  strings: [],
                  binary: [],
                  values: []
                )
              ),
              true
            ]
          end

          if all_str
            vals = values.map(&:str)
            return [
              Model::TypedVector.new(
                element_type: Model::ElementType::STRING,
                codec: select_string_codec(vals),
                data: Model::TypedVectorData.new(
                  kind: Model::ElementType::STRING,
                  bools: [],
                  i64s: [],
                  u64s: [],
                  f64s: [],
                  strings: vals,
                  binary: [],
                  values: []
                )
              ),
              true
            ]
          end

          [nil, false]
        end

        def write_message(message, out)
          case message.kind
          when Model::MessageKind::SCALAR
            out << message.kind.value.chr
            write_value(message.scalar, out)
          when Model::MessageKind::ARRAY
            out << message.kind.value.chr
            Wire.encode_varuint(message.array.length, out)
            message.array.each { |value| write_value(value, out) }
          when Model::MessageKind::MAP
            out << message.kind.value.chr
            Wire.encode_varuint(message.map.length, out)
            message.map.each do |entry|
              write_key_ref(entry.key, out)
              field_id = key_ref_field_identity(entry.key, @state)
              write_value_with_field(entry.value, field_id, out)
            end
          when Model::MessageKind::SHAPED_OBJECT
            out << message.kind.value.chr
            Wire.encode_varuint(message.shaped_object.shape_id, out)
            write_presence(message.shaped_object.presence, message.shaped_object.has_presence, out)
            Wire.encode_varuint(message.shaped_object.values.length, out)
            keys, ok = @state.shape_table.get_keys(message.shaped_object.shape_id)
            if ok
              pres = message.shaped_object.presence
              unless message.shaped_object.has_presence
                pres = Array.new(keys.length, true)
              end
              value_idx = 0
              keys.each_with_index do |key, i|
                next if i < pres.length && !pres[i]
                break if value_idx >= message.shaped_object.values.length

                write_value_with_field(message.shaped_object.values[value_idx], key, out)
                value_idx += 1
              end
              while value_idx < message.shaped_object.values.length
                write_value(message.shaped_object.values[value_idx], out)
                value_idx += 1
              end
            else
              message.shaped_object.values.each { |value| write_value(value, out) }
            end
          when Model::MessageKind::SCHEMA_OBJECT
            out << message.kind.value.chr
            schema_id = nil
            if message.schema_object.schema_id
              out << 1.chr
              Wire.encode_varuint(message.schema_object.schema_id, out)
              schema_id = message.schema_object.schema_id
            else
              out << 0.chr
            end
            write_presence(message.schema_object.presence, message.schema_object.has_presence, out)
            Wire.encode_varuint(message.schema_object.fields.length, out)

            schema = nil
            if schema_id
              schema = @state.schemas[schema_id]
            elsif @state.last_schema_id
              schema = @state.schemas[@state.last_schema_id]
            end

            if schema
              out << 1.chr
              write_schema_fields(
                schema,
                message.schema_object.presence,
                message.schema_object.has_presence,
                message.schema_object.fields,
                out
              )
              @state.last_schema_id = schema_id if schema_id
            else
              out << 0.chr
              message.schema_object.fields.each { |field| write_value(field, out) }
            end
          when Model::MessageKind::TYPED_VECTOR
            out << message.kind.value.chr
            write_typed_vector(message.typed_vector, out)
          when Model::MessageKind::ROW_BATCH
            out << message.kind.value.chr
            Wire.encode_varuint(message.row_batch.rows.length, out)
            message.row_batch.rows.each do |row|
              Wire.encode_varuint(row.length, out)
              row.each { |value| write_value(value, out) }
            end
          when Model::MessageKind::COLUMN_BATCH
            out << message.kind.value.chr
            Wire.encode_varuint(message.column_batch.count, out)
            Wire.encode_varuint(message.column_batch.columns.length, out)
            message.column_batch.columns.each { |column| write_column(column, out) }
          when Model::MessageKind::CONTROL
            out << message.kind.value.chr
            write_control(message.control, out)
          when Model::MessageKind::EXT
            out << message.kind.value.chr
            Wire.encode_varuint(message.ext.ext_type, out)
            Wire.encode_bytes(message.ext.payload, out)
          when Model::MessageKind::STATE_PATCH
            out << message.kind.value.chr
            write_base_ref(message.state_patch.base_ref, out)
            Wire.encode_varuint(message.state_patch.operations.length, out)
            message.state_patch.operations.each do |op|
              Wire.encode_varuint(op.field_id, out)
              out << op.opcode.value.chr
              if op.value
                out << 1.chr
                write_value(op.value, out)
              else
                out << 0.chr
              end
            end
            Wire.encode_varuint(message.state_patch.literals.length, out)
            message.state_patch.literals.each { |literal| write_value(literal, out) }
          when Model::MessageKind::TEMPLATE_BATCH
            out << message.kind.value.chr
            Wire.encode_varuint(message.template_batch.template_id, out)
            Wire.encode_varuint(message.template_batch.count, out)
            Wire.encode_bitmap(message.template_batch.changed_column_mask, out)
            Wire.encode_varuint(message.template_batch.columns.length, out)
            message.template_batch.columns.each { |column| write_column(column, out) }
          when Model::MessageKind::CONTROL_STREAM
            out << message.kind.value.chr
            out << message.control_stream.codec.value.chr
            write_control_stream_payload(
              message.control_stream.codec,
              message.control_stream.payload,
              out
            )
          when Model::MessageKind::BASE_SNAPSHOT
            out << message.kind.value.chr
            Wire.encode_varuint(message.base_snapshot.base_id, out)
            Wire.encode_varuint(message.base_snapshot.schema_or_shape_ref, out)
            write_message(message.base_snapshot.payload, out)
            @state.register_base_snapshot(message.base_snapshot.base_id, message.base_snapshot.payload)
          else
            raise Errors.invalid_data("unsupported message kind")
          end
        end

        def read_message(reader)
          reader.with_depth { read_message_inner(reader) }
        end

        def read_message_inner(reader)
          kind_byte = reader.read_u8
          kind = Model::MessageKind.from_byte(kind_byte)
          raise Errors.invalid_kind(kind_byte) if kind.nil?

          case kind
          when Model::MessageKind::SCALAR
            v = read_value(reader)
            Model.message(kind: Model::MessageKind::SCALAR, scalar: v)
          when Model::MessageKind::ARRAY
            n = reader.read_count
            values = []
            n.times { values << read_value(reader) }
            Model.message(kind: Model::MessageKind::ARRAY, array: values)
          when Model::MessageKind::MAP
            n = reader.read_count
            entries = []
            n.times do
              key_ref = read_key_ref(reader)
              field_identity = key_ref_field_identity(key_ref, @state)
              v = read_value_with_field(reader, field_identity)
              entries << Model::MessageMapEntry.new(key: key_ref, value: v)
            end
            keys = entries.map { |entry| key_ref_string(entry.key, @state) }
            observe_decode_shape_candidate(keys)
            Model.message(kind: Model::MessageKind::MAP, map: entries)
          when Model::MessageKind::SHAPED_OBJECT
            shape_id = reader.read_count(65535)
            presence, has_presence = read_presence(reader)
            n = reader.read_count
            values = []
            keys, ok = @state.shape_table.get_keys(shape_id)
            if ok
              pres = presence
              unless has_presence
                pres = Array.new(keys.length, true)
              end
              read_count = 0
              keys.each_with_index do |key, i|
                next if i < pres.length && !pres[i]
                break if read_count >= n

                values << read_value_with_field(reader, key)
                read_count += 1
              end
              while read_count < n
                values << read_value(reader)
                read_count += 1
              end
            else
              n.times { values << read_value(reader) }
            end
            Model.message(
              kind: Model::MessageKind::SHAPED_OBJECT,
              shaped_object: Model::ShapedObjectMessage.new(
                shape_id: shape_id, presence: presence, has_presence: has_presence, values: values
              )
            )
          when Model::MessageKind::SCHEMA_OBJECT
            has_schema = reader.read_u8
            schema_id = nil
            if has_schema == 1
              schema_id = reader.read_varuint
            end
            presence, has_presence = read_presence(reader)
            n = reader.read_count
            mode = reader.read_u8
            fields = []
            if mode == 1
              effective_id = if schema_id
                               schema_id
                             elsif @state.last_schema_id
                               @state.last_schema_id
                             else
                               raise Errors.invalid_data("schema object requires schema id in context")
                             end
              schema = @state.schemas[effective_id]
              raise reference_error("schema_id", effective_id) if schema.nil?

              fields = read_schema_fields(schema, presence, has_presence, n, reader)
              @state.last_schema_id = effective_id
            else
              n.times { fields << read_value(reader) }
              @state.last_schema_id = schema_id if schema_id
            end
            Model.message(
              kind: Model::MessageKind::SCHEMA_OBJECT,
              schema_object: Model::SchemaObjectMessage.new(
                schema_id: schema_id, presence: presence, has_presence: has_presence, fields: fields
              )
            )
          when Model::MessageKind::TYPED_VECTOR
            tv = read_typed_vector(reader, nil, nil)
            Model.message(kind: Model::MessageKind::TYPED_VECTOR, typed_vector: tv)
          when Model::MessageKind::ROW_BATCH
            row_count = reader.read_count
            rows = []
            row_count.times do
              field_count = reader.read_count
              row = []
              field_count.times { row << read_value(reader) }
              rows << row
            end
            Model.message(
              kind: Model::MessageKind::ROW_BATCH,
              row_batch: Model::RowBatchMessage.new(rows: rows)
            )
          when Model::MessageKind::COLUMN_BATCH
            count = reader.read_count
            col_count = reader.read_count
            cols = []
            col_count.times { cols << read_column(reader) }
            Model.message(
              kind: Model::MessageKind::COLUMN_BATCH,
              column_batch: Model::ColumnBatchMessage.new(count: count, columns: cols)
            )
          when Model::MessageKind::CONTROL
            ctrl = read_control(reader)
            Model.message(kind: Model::MessageKind::CONTROL, control: ctrl)
          when Model::MessageKind::EXT
            ext_type = reader.read_varuint
            payload = reader.read_bytes
            Model.message(
              kind: Model::MessageKind::EXT,
              ext: Model::ExtMessage.new(ext_type: ext_type, payload: payload)
            )
          when Model::MessageKind::STATE_PATCH
            base_ref = read_base_ref(reader)
            n = reader.read_count
            ops = []
            n.times do
              field_id = reader.read_varuint
              op_byte = reader.read_u8
              opcode = Model::PatchOpcode.from_byte(op_byte)
              raise Errors.invalid_data("patch opcode") if opcode.nil?

              has_value = reader.read_u8
              value = has_value == 1 ? read_value(reader) : nil
              ops << Model::PatchOperation.new(field_id: field_id, opcode: opcode, value: value)
            end
            lit_n = reader.read_count
            lits = []
            lit_n.times { lits << read_value(reader) }
            Model.message(
              kind: Model::MessageKind::STATE_PATCH,
              state_patch: Model::StatePatchMessage.new(base_ref: base_ref, operations: ops, literals: lits)
            )
          when Model::MessageKind::TEMPLATE_BATCH
            template_id = reader.read_varuint
            count = reader.read_count
            mask = reader.read_bitmap
            col_n = reader.read_count
            changed_cols = []
            col_n.times { changed_cols << read_column(reader) }
            full_cols = changed_cols
            prev = @state.template_columns[template_id]
            if prev
              full_cols = merge_template_columns(prev, mask, changed_cols)
            else
              mask.each do |bit|
                raise reference_error("template_id", template_id) unless bit
              end
            end
            @state.template_columns[template_id] = full_cols
            @state.templates[template_id] = template_descriptor_from_columns(template_id, full_cols)
            if count >= 16
              @state.previous_message = Model.message(
                kind: Model::MessageKind::COLUMN_BATCH,
                column_batch: Model::ColumnBatchMessage.new(count: count, columns: full_cols)
              )
            end
            Model.message(
              kind: Model::MessageKind::TEMPLATE_BATCH,
              template_batch: Model::TemplateBatchMessage.new(
                template_id: template_id, count: count, changed_column_mask: mask, columns: changed_cols
              )
            )
          when Model::MessageKind::CONTROL_STREAM
            codec_byte = reader.read_u8
            codec = Model::ControlStreamCodec.from_byte(codec_byte)
            raise Errors.invalid_data("control stream codec") if codec.nil?

            payload = read_control_stream_payload(codec, reader)
            Model.message(
              kind: Model::MessageKind::CONTROL_STREAM,
              control_stream: Model::ControlStreamMessage.new(codec: codec, payload: payload)
            )
          when Model::MessageKind::BASE_SNAPSHOT
            base_id = reader.read_varuint
            schema_or_shape_ref = reader.read_varuint
            payload = read_message(reader)
            @state.register_base_snapshot(base_id, payload)
            Model.message(
              kind: Model::MessageKind::BASE_SNAPSHOT,
              base_snapshot: Model::BaseSnapshotMessage.new(
                base_id: base_id,
                schema_or_shape_ref: schema_or_shape_ref,
                payload: payload
              )
            )
          else
            raise Errors.invalid_data("unsupported message kind")
          end
        end

        def write_value(value, out)
          write_value_with_field(value, nil, out)
        end

        def write_value_with_field(value, field_identity, out)
          case value.kind
          when Model::ValueKind::NULL
            out << TAG_NULL.chr
          when Model::ValueKind::BOOL
            out << (value.bool ? TAG_BOOL_TRUE : TAG_BOOL_FALSE).chr
          when Model::ValueKind::I64
            out << TAG_I64.chr
            write_smallest_u64(Wire.encode_zigzag(value.i64), out)
          when Model::ValueKind::U64
            out << TAG_U64.chr
            write_smallest_u64(value.u64, out)
          when Model::ValueKind::F64
            out << TAG_F64.chr
            Wire.append_f64_le(out, value.f64)
          when Model::ValueKind::STRING
            out << TAG_STRING.chr
            unless field_identity.nil?
              enum_vals = @state.field_enums[field_identity]
              unless enum_vals.nil?
                enum_vals.each_with_index do |enum_value, i|
                  if enum_value == value.str
                    out << Model::StringMode::INLINE_ENUM.value.chr
                    Wire.encode_varuint(i, out)
                    return
                  end
                end
              end
            end
            if value.str.empty?
              out << Model::StringMode::EMPTY.value.chr
              return
            end
            id, ok = @state.string_table.get_id(value.str)
            if ok
              out << Model::StringMode::REF.value.chr
              Wire.encode_varuint(id, out)
              return
            end
            base_id, prefix_len, has_prefix = best_prefix_base(value.str)
            if has_prefix && prefix_len >= 4 && prefix_len < value.str.bytesize
              out << Model::StringMode::PREFIX_DELTA.value.chr
              Wire.encode_varuint(base_id, out)
              Wire.encode_varuint(prefix_len, out)
              Wire.encode_string(value.str.byteslice(prefix_len, value.str.bytesize - prefix_len), out)
              @state.string_table.register(value.str)
              return
            end
            out << Model::StringMode::LITERAL.value.chr
            Wire.encode_string(value.str, out)
            @state.string_table.register(value.str)
          when Model::ValueKind::BINARY
            out << TAG_BINARY.chr
            Wire.encode_bytes(value.bin, out)
          when Model::ValueKind::ARRAY
            out << TAG_ARRAY.chr
            Wire.encode_varuint(value.arr.length, out)
            value.arr.each { |entry| write_value(entry, out) }
          when Model::ValueKind::MAP
            out << TAG_MAP.chr
            Wire.encode_varuint(value.map.length, out)
            value.map.each do |entry|
              write_key_ref(Model::KeyRef.literal(entry.key), out)
              write_value_with_field(entry.value, entry.key, out)
            end
          end
        end

        def read_value(reader)
          read_value_with_field(reader, nil)
        end

        def read_value_with_field(reader, field_identity)
          reader.with_depth { read_value_with_field_inner(reader, field_identity) }
        end

        def read_value_with_field_inner(reader, field_identity)
          tag = reader.read_u8
          case tag
          when TAG_NULL
            Model.null_value
          when TAG_BOOL_FALSE
            Model.bool_value(false)
          when TAG_BOOL_TRUE
            Model.bool_value(true)
          when TAG_I64
            Model.i64_value(Wire.decode_zigzag(read_smallest_u64(reader)))
          when TAG_U64
            Model.u64_value(read_smallest_u64(reader))
          when TAG_F64
            Model.f64_value(Wire.read_f64_le(reader))
          when TAG_STRING
            mode_byte = reader.read_u8
            mode = Model::StringMode.from_byte(mode_byte)
            raise Errors.invalid_data("string mode") if mode.nil?

            case mode
            when Model::StringMode::EMPTY
              Model.string_value("")
            when Model::StringMode::LITERAL
              s = reader.read_string
              @state.string_table.register(s)
              Model.string_value(s)
            when Model::StringMode::REF
              id = reader.read_varuint
              s, ok = @state.string_table.get_value(id)
              raise reference_error("string_id", id) unless ok

              Model.string_value(s)
            when Model::StringMode::PREFIX_DELTA
              base_id = reader.read_varuint
              prefix_len = reader.read_count
              suffix = reader.read_string
              base, ok = @state.string_table.get_value(base_id)
              raise reference_error("string_id", base_id) unless ok
              raise Errors.invalid_data("prefix delta length") if prefix_len > base.bytesize

              s = base.byteslice(0, prefix_len) + suffix
              @state.string_table.register(s)
              Model.string_value(s)
            when Model::StringMode::INLINE_ENUM
              raise Errors.invalid_data("inline enum missing field identity") if field_identity.nil?

              enum_vals = @state.field_enums[field_identity]
              raise Errors.invalid_data("inline enum unknown field") if enum_vals.nil?

              code = reader.read_varuint
              raise Errors.invalid_data("inline enum code") if code >= enum_vals.length

              Model.string_value(enum_vals[code])
            end
          when TAG_BINARY
            Model.binary_value(reader.read_bytes)
          when TAG_ARRAY
            n = reader.read_count
            out = []
            n.times { out << read_value(reader) }
            Model.array_value(out)
          when TAG_MAP
            n = reader.read_count
            out = []
            n.times do
              key_ref = read_key_ref(reader)
              key = key_ref.literal
              value = read_value_with_field(reader, key)
              out << Model.entry(key, value)
            end
            Model.map_value(out)
          else
            raise Errors.invalid_tag(tag)
          end
        end

        def write_schema_fields(schema, presence, has_presence, fields, out)
          indices = Protocol.schema_present_field_indices(schema, presence, has_presence)
          indices.each_with_index do |schema_idx, i|
            raise Errors.invalid_data("schema fields length mismatch") if i >= fields.length

            write_schema_field_value(schema.fields[schema_idx], fields[i], out)
          end
        end

        def read_schema_fields(schema, presence, has_presence, n, reader)
          indices = Protocol.schema_present_field_indices(schema, presence, has_presence)
          raise Errors.invalid_data("schema fields length") if indices.length != n

          out = []
          indices.each do |schema_idx|
            out << read_schema_field_value(schema.fields[schema_idx], reader)
          end
          out
        end

        def write_schema_field_value(field, value, out)
          case Protocol.normalized_logical_type(field.logical_type)
          when "bool"
            raise Errors.invalid_data("schema bool field type mismatch") unless value.kind == Model::ValueKind::BOOL

            write_value(value, out)
          when "i64", "int64", "int"
            raise Errors.invalid_data("schema i64 field type mismatch") unless value.kind == Model::ValueKind::I64

            write_value(value, out)
          when "u64", "uint64", "uint"
            raise Errors.invalid_data("schema u64 field type mismatch") unless value.kind == Model::ValueKind::U64

            write_value(value, out)
          when "f64", "float64", "float"
            raise Errors.invalid_data("schema f64 field type mismatch") unless value.kind == Model::ValueKind::F64

            write_value(value, out)
          when "string"
            raise Errors.invalid_data("schema string field type mismatch") unless value.kind == Model::ValueKind::STRING

            write_value_with_field(value, field.name, out)
          else
            write_value(value, out)
          end
        end

        def read_schema_field_value(field, reader)
          if Protocol.normalized_logical_type(field.logical_type) == "string"
            return read_value_with_field(reader, field.name)
          end
          read_value(reader)
        end

        def write_key_ref(key_ref, out)
          if key_ref.is_id
            out << 1.chr
            Wire.encode_varuint(key_ref.id, out)
            return
          end
          out << 0.chr
          Wire.encode_string(key_ref.literal, out)
          @state.key_table.register(key_ref.literal)
        end

        def read_key_ref(reader)
          mode = reader.read_u8
          if mode == 1
            id = reader.read_varuint
            key, ok = @state.key_table.get_value(id)
            raise reference_error("key_id", id) unless ok

            return Model::KeyRef.literal(key)
          end
          raise Errors.invalid_data("key ref mode") unless mode.zero?

          s = reader.read_string
          @state.key_table.register(s)
          Model::KeyRef.literal(s)
        end

        def write_presence(presence, has_presence, out)
          unless has_presence
            out << 0.chr
            return
          end
          out << 1.chr
          Wire.encode_bitmap(presence, out)
        end

        def read_presence(reader)
          flag = reader.read_u8
          return [nil, false] if flag.zero?
          raise Errors.invalid_data("presence flag") unless flag == 1

          [reader.read_bitmap, true]
        end

        def typed_vector_len(data)
          case data.kind
          when Model::ElementType::BOOL
            data.bools.length
          when Model::ElementType::I64
            data.i64s.length
          when Model::ElementType::U64
            data.u64s.length
          when Model::ElementType::F64
            data.f64s.length
          when Model::ElementType::STRING
            data.strings.length
          when Model::ElementType::BINARY
            data.binary.length
          when Model::ElementType::VALUE
            data.values.length
          else
            0
          end
        end

        def write_typed_vector(vector, out)
          out << vector.element_type.value.chr
          Wire.encode_varuint(typed_vector_len(vector.data), out)
          out << vector.codec.value.chr
          case vector.element_type
          when Model::ElementType::BOOL
            Wire.encode_bitmap(vector.data.bools, out)
          when Model::ElementType::I64
            Codec.encode_i64_vector(vector.data.i64s, vector.codec, out)
          when Model::ElementType::U64
            Codec.encode_u64_vector(vector.data.u64s, vector.codec, out)
          when Model::ElementType::F64
            Codec.encode_f64_vector(vector.data.f64s, vector.codec, out)
          when Model::ElementType::STRING
            write_string_vector(vector.data.strings, vector.codec, out)
          when Model::ElementType::BINARY
            Wire.encode_varuint(vector.data.binary.length, out)
            vector.data.binary.each { |bytes| Wire.encode_bytes(bytes, out) }
          when Model::ElementType::VALUE
            Wire.encode_varuint(vector.data.values.length, out)
            vector.data.values.each { |entry| write_value(entry, out) }
          else
            raise Errors.invalid_data("unsupported element type")
          end
        end

        def read_typed_vector(reader, forced_element, expected_codec)
          elem_type = if forced_element.nil?
                        elem_byte = reader.read_u8
                        parsed = Model::ElementType.from_byte(elem_byte)
                        raise Errors.invalid_data("vector element type") if parsed.nil?

                        parsed
                      else
                        forced_element
                      end
          expected_len = reader.read_count
          codec_byte = reader.read_u8
          codec = Model::VectorCodec.from_byte(codec_byte)
          raise Errors.invalid_data("vector codec") if codec.nil?
          raise Errors.invalid_data("column codec mismatch") if !expected_codec.nil? && codec != expected_codec

          data = Model::TypedVectorData.new(
            kind: elem_type, bools: [], i64s: [], u64s: [], f64s: [], strings: [], binary: [], values: []
          )
          case elem_type
          when Model::ElementType::BOOL
            data = data.with(bools: reader.read_bitmap)
          when Model::ElementType::I64
            data = data.with(i64s: Codec.decode_i64_vector(reader, codec))
          when Model::ElementType::U64
            data = data.with(u64s: Codec.decode_u64_vector(reader, codec))
          when Model::ElementType::F64
            data = data.with(f64s: Codec.decode_f64_vector(reader, codec))
          when Model::ElementType::STRING
            data = data.with(strings: read_string_vector(reader, codec))
          when Model::ElementType::BINARY
            n = reader.read_count
            values = []
            n.times { values << reader.read_bytes }
            data = data.with(binary: values)
          when Model::ElementType::VALUE
            n = reader.read_count
            values = []
            n.times { values << read_value(reader) }
            data = data.with(values: values)
          end
          raise Errors.invalid_data("typed vector length mismatch") if typed_vector_len(data) != expected_len

          Model::TypedVector.new(element_type: elem_type, codec: codec, data: data)
        end

        def write_column(column, out)
          Wire.encode_varuint(column.field_id, out)
          out << column.null_strategy.value.chr
          case column.null_strategy
          when Model::NullStrategy::PRESENCE_BITMAP, Model::NullStrategy::INVERTED_PRESENCE_BITMAP
            if !column.has_presence || column.presence.nil?
              raise Errors.invalid_data("missing column presence bitmap")
            end
            Wire.encode_bitmap(column.presence, out)
          end
          out << column.codec.value.chr
          if column.dictionary_id
            out << 1.chr
            Wire.encode_varuint(column.dictionary_id, out)
            payload = @state.dictionaries[column.dictionary_id]
            if payload
              profile = @state.dictionary_profiles[column.dictionary_id]
              if profile
                out << 1.chr
                Wire.encode_varuint(profile.version, out)
                Wire.encode_varuint(profile.hash, out)
                Wire.encode_varuint(profile.expires_at, out)
                out << dictionary_fallback_to_byte(profile.fallback).chr
                Wire.encode_bytes(payload, out)
              else
                out << 0.chr
              end
            else
              out << 0.chr
            end
          else
            out << 0.chr
          end

          trained_block = nil
          if !column.dictionary_id.nil? && column.values.kind == Model::ElementType::STRING
            if column.codec == Model::VectorCodec::DICTIONARY || column.codec == Model::VectorCodec::STRING_REF
              payload = @state.dictionaries[column.dictionary_id]
              if payload
                begin
                  dictionary = Dictionary.decode_trained_dictionary_payload(payload)
                  block, ok = Dictionary.encode_trained_dictionary_block(column.values.strings, dictionary)
                  trained_block = block if ok
                rescue StandardError
                  # fall through to regular typed-vector encoding
                end
              end
            end
          end
          unless trained_block.nil?
            out << 1.chr
            Wire.encode_bytes(trained_block, out)
            return
          end

          out << 0.chr
          tv = Model::TypedVector.new(
            element_type: column.values.kind,
            codec: column.codec,
            data: Model.clone_typed_vector_data(column.values)
          )
          write_typed_vector(tv, out)
        end

        def read_column(reader)
          field_id = reader.read_varuint
          null_byte = reader.read_u8
          null_strategy = Model::NullStrategy.from_byte(null_byte)
          raise Errors.invalid_data("null strategy") if null_strategy.nil?

          presence = nil
          has_presence = false
          case null_strategy
          when Model::NullStrategy::PRESENCE_BITMAP, Model::NullStrategy::INVERTED_PRESENCE_BITMAP
            presence = reader.read_bitmap
            has_presence = true
          end

          codec_byte = reader.read_u8
          codec = Model::VectorCodec.from_byte(codec_byte)
          raise Errors.invalid_data("column codec") if codec.nil?

          has_dict = reader.read_u8
          dictionary_id = nil
          case has_dict
          when 0
          when 1
            id = reader.read_varuint
            has_profile = reader.read_u8
            case has_profile
            when 0
              raise reference_error("dict_id", id) unless @state.dictionaries.key?(id)
            when 1
              version = reader.read_varuint
              hash = reader.read_varuint
              expires_at = reader.read_varuint
              fallback_byte = reader.read_u8
              fallback = Session::DictionaryFallback.from_byte(fallback_byte)
              raise Errors.invalid_data("dictionary fallback") if fallback.nil?

              payload = reader.read_bytes
              if Dictionary.dictionary_payload_hash(payload) != hash
                raise Errors.invalid_data("dictionary profile hash mismatch")
              end
              @state.dictionaries[id] = payload
              @state.dictionary_profiles[id] = Session::DictionaryProfile.new(
                version: version,
                hash: hash,
                expires_at: expires_at,
                fallback: fallback
              )
            else
              raise Errors.invalid_data("dictionary profile flag")
            end
            dictionary_id = id
          else
            raise Errors.invalid_data("dictionary flag")
          end

          payload_mode = reader.read_u8
          values = nil
          case payload_mode
          when 0
            values = read_typed_vector(reader, nil, codec).data
          when 1
            raise Errors.invalid_data("trained dictionary block requires dict_id") if dictionary_id.nil?
            unless codec == Model::VectorCodec::DICTIONARY || codec == Model::VectorCodec::STRING_REF
              raise Errors.invalid_data("trained dictionary block requires string dictionary codec")
            end

            dictionary_payload = @state.dictionaries[dictionary_id]
            raise reference_error("dict_id", dictionary_id) if dictionary_payload.nil?

            dictionary = Dictionary.decode_trained_dictionary_payload(dictionary_payload)
            block = reader.read_bytes
            strings = Dictionary.decode_trained_dictionary_block(block, dictionary)
            values = Model::TypedVectorData.new(
              kind: Model::ElementType::STRING,
              bools: [],
              i64s: [],
              u64s: [],
              f64s: [],
              strings: strings,
              binary: [],
              values: []
            )
          else
            raise Errors.invalid_data("column payload mode")
          end

          Model::Column.new(
            field_id: field_id,
            null_strategy: null_strategy,
            presence: presence,
            has_presence: has_presence,
            codec: codec,
            dictionary_id: dictionary_id,
            values: values
          )
        end

        def write_control(control, out)
          out << control.opcode.value.chr
          case control.opcode
          when Model::ControlOpcode::REGISTER_KEYS
            Wire.encode_varuint(control.register_keys.length, out)
            control.register_keys.each do |key|
              Wire.encode_string(key, out)
              @state.key_table.register(key)
            end
          when Model::ControlOpcode::REGISTER_SHAPE
            raise Errors.invalid_data("register shape payload missing") if control.register_shape.nil?

            Wire.encode_varuint(control.register_shape.shape_id, out)
            Wire.encode_varuint(control.register_shape.keys.length, out)
            keys = []
            control.register_shape.keys.each do |key_ref|
              write_key_ref(key_ref, out)
              keys << key_ref.literal
            end
            @state.shape_table.register_with_id(control.register_shape.shape_id, keys)
          when Model::ControlOpcode::REGISTER_STRINGS
            Wire.encode_varuint(control.register_strings.length, out)
            control.register_strings.each do |str|
              Wire.encode_string(str, out)
              @state.string_table.register(str)
            end
          when Model::ControlOpcode::PROMOTE_STRING_FIELD_TO_ENUM
            raise Errors.invalid_data("promote enum payload missing") if control.promote_string_field_to_enum.nil?

            Wire.encode_string(control.promote_string_field_to_enum.field_identity, out)
            Wire.encode_varuint(control.promote_string_field_to_enum.values.length, out)
            control.promote_string_field_to_enum.values.each { |value| Wire.encode_string(value, out) }
            @state.field_enums[control.promote_string_field_to_enum.field_identity] =
              control.promote_string_field_to_enum.values.dup
          when Model::ControlOpcode::RESET_TABLES
            @state.reset_tables
          when Model::ControlOpcode::RESET_STATE
            @state.reset_state
          else
            raise Errors.invalid_data("control opcode")
          end
        end

        def read_control(reader)
          op_byte = reader.read_u8
          opcode = Model::ControlOpcode.from_byte(op_byte)
          raise Errors.invalid_data("control opcode") if opcode.nil?

          msg = Model::ControlMessage.new(
            register_keys: [],
            register_shape: nil,
            register_strings: [],
            promote_string_field_to_enum: nil,
            reset_tables: false,
            reset_state: false,
            opcode: opcode
          )
          case opcode
          when Model::ControlOpcode::REGISTER_KEYS
            n = reader.read_count
            keys = Array.new(n, "")
            n.times do |i|
              key = reader.read_string
              keys[i] = key
              @state.key_table.register(key)
            end
            msg = msg.with(register_keys: keys)
          when Model::ControlOpcode::REGISTER_SHAPE
            shape_id = reader.read_count(65535)
            n = reader.read_count
            keys = Array.new(n)
            key_names = Array.new(n, "")
            n.times do |i|
              key_ref = read_key_ref(reader)
              keys[i] = key_ref
              key_names[i] = key_ref.literal
            end
            @state.shape_table.register_with_id(shape_id, key_names)
            msg = msg.with(register_shape: Model::RegisterShapeControl.new(shape_id: shape_id, keys: keys))
          when Model::ControlOpcode::REGISTER_STRINGS
            n = reader.read_count
            strings = Array.new(n, "")
            n.times do |i|
              str = reader.read_string
              strings[i] = str
              @state.string_table.register(str)
            end
            msg = msg.with(register_strings: strings)
          when Model::ControlOpcode::PROMOTE_STRING_FIELD_TO_ENUM
            field_identity = reader.read_string
            n = reader.read_count
            values = Array.new(n, "")
            n.times do |i|
              values[i] = reader.read_string
            end
            @state.field_enums[field_identity] = values.dup
            msg = msg.with(
              promote_string_field_to_enum: Model::PromoteEnumControl.new(
                field_identity: field_identity,
                values: values
              )
            )
          when Model::ControlOpcode::RESET_TABLES
            msg = msg.with(reset_tables: true)
            @state.reset_tables
          when Model::ControlOpcode::RESET_STATE
            msg = msg.with(reset_state: true)
            @state.reset_state
          end
          msg
        end

        attr_accessor :state

        def write_base_ref(base_ref, out)
          if base_ref.previous
            out << 0.chr
            return
          end
          out << 1.chr
          Wire.encode_varuint(base_ref.base_id, out)
        end

        def read_base_ref(reader)
          mode = reader.read_u8
          case mode
          when 0
            Model::BaseRef.previous
          when 1
            id = reader.read_varuint
            Model::BaseRef.id_ref(id)
          else
            raise Errors.invalid_data("base ref")
          end
        end

        def write_control_stream_payload(codec, payload, out)
          encoded = case codec
                    when Model::ControlStreamCodec::PLAIN
                      payload.b.dup
                    when Model::ControlStreamCodec::RLE
                      rle_encode_bytes(payload)
                    when Model::ControlStreamCodec::BITPACK
                      control_bitpack_encode_bytes(payload)
                    when Model::ControlStreamCodec::HUFFMAN
                      control_huffman_encode_bytes(payload)
                    when Model::ControlStreamCodec::FSE
                      control_fse_encode_bytes(payload)
                    end
          Wire.encode_bytes(encoded, out)
        end

        def read_control_stream_payload(codec, reader)
          encoded = reader.read_bytes
          case codec
          when Model::ControlStreamCodec::PLAIN
            encoded
          when Model::ControlStreamCodec::RLE
            rle_decode_bytes(encoded)
          when Model::ControlStreamCodec::BITPACK
            control_bitpack_decode_bytes(encoded)
          when Model::ControlStreamCodec::HUFFMAN
            control_huffman_decode_bytes(encoded)
          when Model::ControlStreamCodec::FSE
            control_fse_decode_bytes(encoded)
          else
            raise Errors.invalid_data("control stream codec")
          end
        end

        def best_prefix_base(value)
          best_id = 0
          best_len = 0
          state.string_table.by_id.each_with_index do |candidate, id|
            n = common_prefix_len(value.b, candidate.b)
            if n > best_len
              best_len = n
              best_id = id
            end
          end
          return [0, 0, false] if best_len.zero?

          [best_id, best_len, true]
        end

        def write_string_vector(values, codec, out)
          case codec
          when Model::VectorCodec::DICTIONARY
            dict = {}
            uniq = []
            refs = Array.new(values.length, 0)
            values.each_with_index do |v, i|
              id = dict[v]
              if id
                refs[i] = id
              else
                id = uniq.length
                dict[v] = id
                uniq << v
                refs[i] = id
              end
            end
            Wire.encode_varuint(uniq.length, out)
            uniq.each { |v| Wire.encode_string(v, out) }
            Codec.encode_u64_vector(refs, Model::VectorCodec::DIRECT_BITPACK, out)
          when Model::VectorCodec::STRING_REF
            Wire.encode_varuint(values.length, out)
            values.each do |v|
              id, ok = state.string_table.get_id(v)
              if ok
                Wire.encode_varuint(id, out)
              else
                id = state.string_table.register(v)
                Wire.encode_varuint(id, out)
              end
            end
          when Model::VectorCodec::PREFIX_DELTA
            Wire.encode_varuint(values.length, out)
            prev = ""
            values.each do |v|
              prefix = common_prefix_len(prev.b, v.b)
              Wire.encode_varuint(prefix, out)
              Wire.encode_string(v.byteslice(prefix, v.bytesize - prefix), out)
              prev = v
            end
          else
            Wire.encode_varuint(values.length, out)
            values.each { |v| Wire.encode_string(v, out) }
          end
        end

        def read_string_vector(reader, codec)
          case codec
          when Model::VectorCodec::DICTIONARY
            dict_n = reader.read_count
            dict = Array.new(dict_n, "")
            dict_n.times do |i|
              dict[i] = reader.read_string
            end
            refs = Codec.decode_u64_vector(reader, Model::VectorCodec::DIRECT_BITPACK)
            out = Array.new(refs.length, "")
            refs.each_with_index do |ref, i|
              raise Errors.invalid_data("dictionary reference") if ref >= dict.length

              out[i] = dict[ref]
            end
            out
          when Model::VectorCodec::STRING_REF
            n = reader.read_count
            out = Array.new(n, "")
            n.times do |i|
              id = reader.read_varuint
              s, ok = state.string_table.get_value(id)
              raise reference_error("string_id", id) unless ok

              out[i] = s
            end
            out
          when Model::VectorCodec::PREFIX_DELTA
            n = reader.read_count
            out = Array.new(n, "")
            prev = ""
            n.times do |i|
              prefix = reader.read_varuint
              suffix = reader.read_string
              raise Errors.invalid_data("prefix delta in string vector") if prefix > prev.length

              out[i] = prev.byteslice(0, prefix) + suffix
              prev = out[i]
            end
            out
          else
            n = reader.read_count
            out = Array.new(n, "")
            n.times do |i|
              out[i] = reader.read_string
            end
            out
          end
        end

        def apply_state_patch(base_ref, operations, literals)
          base = if base_ref.previous
                   raise reference_error("previous", 0) unless state.previous_message

                   state.previous_message.clone_message
                 else
                   b, ok = state.get_base_snapshot(base_ref.base_id)
                   raise reference_error("base_id", base_ref.base_id) unless ok

                   b
                 end
          _ = literals
          fields = message_fields(base)
          operations.each do |op|
            idx = op.field_id
            case op.opcode
            when Model::PatchOpcode::KEEP
              # no-op
            when Model::PatchOpcode::REPLACE_SCALAR,
                 Model::PatchOpcode::REPLACE_VECTOR,
                 Model::PatchOpcode::INSERT_FIELD,
                 Model::PatchOpcode::STRING_REF,
                 Model::PatchOpcode::PREFIX_DELTA
              raise Errors.invalid_data("patch operation missing value") if op.value.nil?

              if idx < fields.length
                fields[idx] = op.value.clone_value
              elsif idx == fields.length
                fields << op.value.clone_value
              else
                raise Errors.invalid_data("patch field index out of range")
              end
            when Model::PatchOpcode::DELETE_FIELD
              raise Errors.invalid_data("delete field index out of range") if idx.negative? || idx >= fields.length

              fields.delete_at(idx)
            when Model::PatchOpcode::APPEND_VECTOR
              if op.value.nil? || idx.negative? || idx >= fields.length
                raise Errors.invalid_data("append vector patch invalid")
              end
              if fields[idx].kind != Model::ValueKind::ARRAY || op.value.kind != Model::ValueKind::ARRAY
                raise Errors.invalid_data("append vector requires arrays")
              end

              fields[idx] = fields[idx].with(arr: fields[idx].arr + op.value.arr)
            when Model::PatchOpcode::TRUNCATE_VECTOR
              if op.value.nil? || idx.negative? || idx >= fields.length
                raise Errors.invalid_data("truncate vector patch invalid")
              end
              if fields[idx].kind != Model::ValueKind::ARRAY || op.value.kind != Model::ValueKind::U64
                raise Errors.invalid_data("truncate vector requires array and u64")
              end

              n = op.value.u64
              raise Errors.invalid_data("truncate length") if n.negative? || n > fields[idx].arr.length

              fields[idx] = fields[idx].with(arr: fields[idx].arr[0, n].dup)
            end
          end
          rebuild_message_like(base, fields)
        end

        def observe_decode_shape_candidate(keys)
          _id, ok = state.shape_table.get_id(keys)
          return if ok

          observed = state.shape_table.observe(keys)
          state.shape_table.register(keys) if should_register_shape(keys, observed)
        end

        def should_register_shape(keys, observed_count)
          !keys.empty? && observed_count >= 2
        end

        def observe_encode_shape_candidate(keys)
          sk = shape_key(keys)
          state.encode_shape_observations[sk] ||= 0
          state.encode_shape_observations[sk] += 1
          count = state.encode_shape_observations[sk]
          state.shape_table.register(keys) if should_register_shape(keys, count)
          count
        end
        private

        def write_smallest_u64(value, out)
          if value <= 0xFF
            out << 1.chr
            out << value.chr
          elsif value <= 0xFFFF
            out << 2.chr
            out << (value & 0xFF).chr
            out << ((value >> 8) & 0xFF).chr
          elsif value <= 0xFFFFFFFF
            out << 4.chr
            out << (value & 0xFF).chr
            out << ((value >> 8) & 0xFF).chr
            out << ((value >> 16) & 0xFF).chr
            out << ((value >> 24) & 0xFF).chr
          else
            out << 8.chr
            Wire.append_u64_le(out, value)
          end
        end

        def read_smallest_u64(reader)
          size = reader.read_u8
          case size
          when 1
            reader.read_u8
          when 2
            bytes = reader.read_exact(2)
            bytes.getbyte(0) | (bytes.getbyte(1) << 8)
          when 4
            bytes = reader.read_exact(4)
            bytes.getbyte(0) | (bytes.getbyte(1) << 8) | (bytes.getbyte(2) << 16) | (bytes.getbyte(3) << 24)
          when 8
            Wire.read_u64_le(reader)
          else
            raise Errors.invalid_data("smallest u64 size")
          end
        end

        def dictionary_fallback_to_byte(fallback)
          case fallback
          when Session::DictionaryFallback::FAIL_FAST
            0
          when Session::DictionaryFallback::STATELESS_RETRY
            1
          else
            raise Errors.invalid_data("dictionary fallback")
          end
        end
      end
      class SessionEncoder
        attr_reader :codec

        def initialize(options)
          @codec = Protocol.twilic_codec_with_options(options)
        end

        def encode(value)
          msg = codec.message_for_value(value)
          if codec.state.options.enable_state_patch && codec.state.previous_message &&
             supports_state_patch(codec.state.previous_message, msg)
            base_ref = Model::BaseRef.previous
            ops, _literals = diff_message(codec.state.previous_message, msg)
            patch_msg = Model.message(
              kind: Model::MessageKind::STATE_PATCH,
              state_patch: Model::StatePatchMessage.new(base_ref: base_ref, operations: ops, literals: [])
            )
            patch_size = encoded_size(patch_msg)
            full_size = encoded_size(msg)
            if patch_size < full_size
              begin
                return codec.encode_message(patch_msg)
              rescue StandardError
                # fall back to full message path
              end
            end
          end
          codec.encode_message(msg)
        end

        def encode_with_schema(schema, value)
          codec.state.schemas[schema.schema_id] = schema
          codec.state.last_schema_id = schema.schema_id
          schema.fields.each do |field|
            next if field.enum_values.empty?

            codec.state.field_enums[field.name] = field.enum_values.dup
          end
          raise Errors.invalid_data("encode_with_schema expects map value") unless value.kind == Model::ValueKind::MAP

          presence = Array.new(schema.fields.length, false)
          fields = []
          has_presence = false
          schema.fields.each_with_index do |field, i|
            v = lookup_map_field(value, field.name)
            if v
              presence[i] = true
              fields << v.clone_value
            else
              presence[i] = false
              has_presence = true
            end
          end
          msg = Model.message(
            kind: Model::MessageKind::SCHEMA_OBJECT,
            schema_object: Model::SchemaObjectMessage.new(
              schema_id: schema.schema_id, presence: presence, has_presence: has_presence, fields: fields
            )
          )
          codec.encode_message(msg)
        end

        def encode_batch(values)
          if values.empty?
            msg = Model.message(
              kind: Model::MessageKind::ROW_BATCH,
              row_batch: Model::RowBatchMessage.new(rows: [])
            )
            return codec.encode_message(msg)
          end

          msg = nil
          if values.length >= 16
            cols = columns_from_map_values(values)
            cols = rows_to_columns(rows_from_values(values)) if cols.nil?
            Dictionary.apply_dictionary_references(codec.state, cols) if codec.state.options.enable_trained_dictionary
            msg = Model.message(
              kind: Model::MessageKind::COLUMN_BATCH,
              column_batch: Model::ColumnBatchMessage.new(count: values.length, columns: cols)
            )
          else
            msg = Model.message(
              kind: Model::MessageKind::ROW_BATCH,
              row_batch: Model::RowBatchMessage.new(rows: rows_from_values(values))
            )
          end

          bytes = codec.encode_message(msg)
          codec.state.previous_message = msg
          size = bytes.bytesize
          codec.state.previous_message_size = size
          record_full_message_as_base
          bytes
        end

        def record_full_message_as_base
          return if codec.state.options.max_base_snapshots.zero?
          return if codec.state.previous_message.nil?

          base_id = codec.state.allocate_base_id
          codec.state.register_base_snapshot(base_id, codec.state.previous_message)
        end

        def encode_patch(value)
          msg = codec.message_for_value(value)
          if codec.state.previous_message.nil? || !supports_state_patch(codec.state.previous_message, msg)
            return codec.encode_message(msg)
          end
          ops, _literals = diff_message(codec.state.previous_message, msg)
          patch_msg = Model.message(
            kind: Model::MessageKind::STATE_PATCH,
            state_patch: Model::StatePatchMessage.new(
              base_ref: Model::BaseRef.previous, operations: ops, literals: []
            )
          )
          return codec.encode_message(msg) if encoded_size(patch_msg) >= encoded_size(msg)

          codec.encode_message(patch_msg)
        end

        def encode_micro_batch(values)
          return encode_batch(values) if values.empty?
          if !codec.state.options.enable_template_batch || !has_uniform_micro_batch_shape(values)
            return encode_batch(values)
          end

          columns = columns_from_map_values(values)
          columns = rows_to_columns(rows_from_values(values)) if columns.nil?
          Dictionary.apply_dictionary_references(codec.state, columns) if codec.state.options.enable_trained_dictionary
          template_id, ok = find_template_id(codec.state.templates, columns)
          unless ok
            template_id = codec.state.allocate_template_id
            codec.state.templates[template_id] = template_descriptor_from_columns(template_id, columns)
            codec.state.template_columns[template_id] = columns
            mask = Array.new(columns.length, true)
            msg = Model.message(
              kind: Model::MessageKind::TEMPLATE_BATCH,
              template_batch: Model::TemplateBatchMessage.new(
                template_id: template_id, count: values.length, changed_column_mask: mask, columns: columns
              )
            )
            return codec.encode_message(msg)
          end
          mask, changed_cols = diff_template_columns(codec.state.template_columns[template_id], columns)
          codec.state.template_columns[template_id] = columns
          msg = Model.message(
            kind: Model::MessageKind::TEMPLATE_BATCH,
            template_batch: Model::TemplateBatchMessage.new(
              template_id: template_id, count: values.length, changed_column_mask: mask, columns: changed_cols
            )
          )
          codec.encode_message(msg)
        end

        def reset
          codec.state.reset_state
        end

        def decode_message(bytes)
          codec.decode_message(bytes)
        end
      end

      module_function

      def lookup_map_field(value, key)
        return nil unless value.kind == Model::ValueKind::MAP

        value.map.each do |entry|
          if entry.key == key
            v = entry.value.clone_value
            return v
          end
        end
        nil
      end

      def schema_present_field_indices(schema, presence, has_presence)
        unless has_presence
          out = Array.new(schema.fields.length, 0)
          out.each_index { |i| out[i] = i }
          return out
        end
        raise Errors.invalid_data("presence bitmap mismatch for schema") if presence.length != schema.fields.length

        out = []
        schema.fields.each_with_index do |_field, i|
          out << i if presence[i]
        end
        out
      end

      def normalized_logical_type(raw)
        raw.strip.downcase
      end

      def rows_from_values(values)
        rows = Array.new(values.length) { [] }
        values.each_with_index do |value, i|
          if value.kind == Model::ValueKind::ARRAY
            row = Array.new(value.arr.length)
            value.arr.each_with_index { |item, j| row[j] = item.clone_value }
            rows[i] = row
          else
            rows[i] = [value.clone_value]
          end
        end
        rows
      end

      def column_null_strategy(values, present_bits)
        null_count = 0
        values.each do |value|
          null_count += 1 if value.kind == Model::ValueKind::NULL
        end
        optional_count = values.length
        if null_count.zero?
          return [Model::NullStrategy::ALL_PRESENT_ELIDED, nil, false]
        end
        if null_count <= optional_count / 4
          inverted = Array.new(present_bits.length, false)
          present_bits.each_with_index do |bit, i|
            inverted[i] = !bit
          end
          return [Model::NullStrategy::INVERTED_PRESENCE_BITMAP, inverted, true]
        end
        [Model::NullStrategy::PRESENCE_BITMAP, present_bits.dup, true]
      end

      def strip_nulls(values)
        out = []
        values.each do |value|
          out << value unless value.kind == Model::ValueKind::NULL
        end
        out
      end

      def columns_from_map_values(values)
        return nil if values.empty?

        values.each do |value|
          return nil unless value.kind == Model::ValueKind::MAP
        end
        key_order = []
        key_index = {}
        column_values = []
        column_presence = []
        values.each_with_index do |row_value, row_idx|
          present = Array.new(key_order.length, false)
          row_value.map.each do |entry|
            key = entry.key
            entry_value = entry.value.clone_value
            col_idx = key_index[key]
            unless col_idx
              col_idx = key_order.length
              key_order << key
              key_index[key] = col_idx
              column_values << Array.new(row_idx)
              column_presence << Array.new(row_idx)
              present << false
            end
            column_values[col_idx] << entry_value
            column_presence[col_idx] << true
            present[col_idx] = true
          end
          key_order.each_index do |col_idx|
            next if present[col_idx]

            column_values[col_idx] << Model.null_value
            column_presence[col_idx] << false
          end
        end
        columns = Array.new(key_order.length)
        key_order.each_index do |field_id|
          col_values = column_values[field_id]
          present_bits = column_presence[field_id]
          null_strategy, presence, has_presence = column_null_strategy(col_values, present_bits)
          codec, tvd = infer_column_codec_and_values(strip_nulls(col_values))
          columns[field_id] = Model::Column.new(
            field_id: field_id,
            null_strategy: null_strategy,
            presence: presence,
            has_presence: has_presence,
            codec: codec,
            dictionary_id: nil,
            values: tvd
          )
        end
        columns
      end

      def has_uniform_micro_batch_shape(values)
        return false if values.empty?
        return false if values[0].kind != Model::ValueKind::MAP

        keys = values[0].map.map(&:key)
        (1...values.length).each do |i|
          return false if values[i].kind != Model::ValueKind::MAP || values[i].map.length != keys.length

          keys.each_index do |j|
            return false if values[i].map[j].key != keys[j]
          end
        end
        true
      end

      def should_register_shape(keys, observed_count)
        !keys.empty? && observed_count >= 2
      end

      def supports_state_patch(base, current)
        !base.nil? && !current.nil? && base.kind == current.kind &&
          (base.kind == Model::MessageKind::MAP ||
            base.kind == Model::MessageKind::SCHEMA_OBJECT ||
            base.kind == Model::MessageKind::SHAPED_OBJECT ||
            base.kind == Model::MessageKind::ARRAY)
      end

      def encoded_size(message)
        estimate_message_size(message)
      end

      def typed_vector_to_value(vector)
        case vector.element_type
        when Model::ElementType::BOOL
          out = Array.new(vector.data.bools.length)
          out.each_index { |i| out[i] = Model.bool_value(vector.data.bools[i]) }
          Model.array_value(out)
        when Model::ElementType::I64
          out = Array.new(vector.data.i64s.length)
          out.each_index { |i| out[i] = Model.i64_value(vector.data.i64s[i]) }
          Model.array_value(out)
        when Model::ElementType::U64
          out = Array.new(vector.data.u64s.length)
          out.each_index { |i| out[i] = Model.u64_value(vector.data.u64s[i]) }
          Model.array_value(out)
        when Model::ElementType::F64
          out = Array.new(vector.data.f64s.length)
          out.each_index { |i| out[i] = Model.f64_value(vector.data.f64s[i]) }
          Model.array_value(out)
        when Model::ElementType::STRING
          out = Array.new(vector.data.strings.length)
          out.each_index { |i| out[i] = Model.string_value(vector.data.strings[i]) }
          Model.array_value(out)
        else
          Model.array_value([])
        end
      end

      def entries_to_map(entries, state)
        out = Array.new(entries.length)
        entries.each_with_index do |entry, i|
          key = key_ref_string(entry.key, state)
          out[i] = Model::MapEntry.new(key, entry.value.clone_value)
          _id, ok = state.key_table.get_id(key)
          state.key_table.register(key) unless ok
        end
        out
      end

      def key_ref_string(key, state)
        if key.is_id
          s, ok = state.key_table.get_value(key.id)
          return s if ok

          return ""
        end
        key.literal
      end

      def key_ref_field_identity(key, state)
        s = key_ref_string(key, state)
        return nil if s == ""

        s
      end

      def shape_values_to_map(keys, presence, has_presence, values)
        out = []
        idx = 0
        keys.each_with_index do |key, i|
          next if has_presence && i < presence.length && !presence[i]
          break if idx >= values.length

          out << Model.entry(key, values[idx].clone_value)
          idx += 1
        end
        out
      end
    end
  end
end

require "twilic/core/protocol_helpers"

module Twilic
  module Core
    module Protocol
      ProtocolHelpers.singleton_methods(false).each do |name|
        next if singleton_methods(false).include?(name)

        define_singleton_method(name) do |*args, **kwargs, &block|
          ProtocolHelpers.send(name, *args, **kwargs, &block)
        end
      end

      def self.delegate_helpers_to(klass)
        ProtocolHelpers.singleton_methods(false).each do |name|
          next if klass.method_defined?(name)

          klass.define_method(name) do |*args, **kwargs, &block|
            ProtocolHelpers.send(name, *args, **kwargs, &block)
          end
        end
        singleton_methods(false).each do |name|
          next if klass.method_defined?(name)

          klass.define_method(name) do |*args, **kwargs, &block|
            Protocol.send(name, *args, **kwargs, &block)
          end
        end
      end

      delegate_helpers_to(TwilicCodec)
      delegate_helpers_to(SessionEncoder)
    end
  end
end
