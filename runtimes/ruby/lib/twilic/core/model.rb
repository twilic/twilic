# frozen_string_literal: true

module Twilic
  module Core
    module Model
      class MessageKind
        Entry = Data.define(:value)
        SCALAR = Entry.new(0x00)
        ARRAY = Entry.new(0x01)
        MAP = Entry.new(0x02)
        SHAPED_OBJECT = Entry.new(0x03)
        SCHEMA_OBJECT = Entry.new(0x04)
        TYPED_VECTOR = Entry.new(0x05)
        ROW_BATCH = Entry.new(0x06)
        COLUMN_BATCH = Entry.new(0x07)
        CONTROL = Entry.new(0x08)
        EXT = Entry.new(0x09)
        STATE_PATCH = Entry.new(0x0A)
        TEMPLATE_BATCH = Entry.new(0x0B)
        CONTROL_STREAM = Entry.new(0x0C)
        BASE_SNAPSHOT = Entry.new(0x0D)

        def self.from_byte(b)
          case b
          when 0x00 then SCALAR
          when 0x01 then ARRAY
          when 0x02 then MAP
          when 0x03 then SHAPED_OBJECT
          when 0x04 then SCHEMA_OBJECT
          when 0x05 then TYPED_VECTOR
          when 0x06 then ROW_BATCH
          when 0x07 then COLUMN_BATCH
          when 0x08 then CONTROL
          when 0x09 then EXT
          when 0x0A then STATE_PATCH
          when 0x0B then TEMPLATE_BATCH
          when 0x0C then CONTROL_STREAM
          when 0x0D then BASE_SNAPSHOT
          end
        end
      end

      class ValueKind
        Entry = Data.define(:name)
        NULL = Entry.new(:null)
        BOOL = Entry.new(:bool)
        I64 = Entry.new(:i64)
        U64 = Entry.new(:u64)
        F64 = Entry.new(:f64)
        STRING = Entry.new(:string)
        BINARY = Entry.new(:binary)
        ARRAY = Entry.new(:array)
        MAP = Entry.new(:map)
      end

      Value = Data.define(:kind, :bool, :i64, :u64, :f64, :str, :bin, :arr, :map) do
        def scalar?
          kind != ValueKind::ARRAY && kind != ValueKind::MAP
        end

        def clone_value
          case kind
          when ValueKind::NULL, ValueKind::BOOL, ValueKind::I64, ValueKind::U64, ValueKind::F64, ValueKind::STRING
            self
          when ValueKind::BINARY
            with(bin: bin.b.dup)
          when ValueKind::ARRAY
            with(arr: arr.map(&:clone_value))
          when ValueKind::MAP
            with(map: map.map { |e| MapEntry.new(e.key, e.value.clone_value) })
          else
            new(kind: ValueKind::NULL)
          end
        end
      end

      MapEntry = Data.define(:key, :value)
      MessageMapEntry = Data.define(:key, :value)

      KeyRef = Data.define(:literal, :id, :is_id) do
        def self.literal(s)
          new(literal: s, id: 0, is_id: false)
        end

        def self.id_ref(id)
          new(literal: "", id: id, is_id: true)
        end
      end

      class StringMode
        Entry = Data.define(:value)
        EMPTY = Entry.new(0)
        LITERAL = Entry.new(1)
        REF = Entry.new(2)
        PREFIX_DELTA = Entry.new(3)
        INLINE_ENUM = Entry.new(4)

        def self.from_byte(b)
          return Entry.new(b) if (0..4).cover?(b)

          nil
        end
      end

      StringValue = Data.define(:mode, :value, :ref_id, :prefix_len)

      class ElementType
        Entry = Data.define(:value)
        BOOL = Entry.new(0)
        I64 = Entry.new(1)
        U64 = Entry.new(2)
        F64 = Entry.new(3)
        STRING = Entry.new(4)
        BINARY = Entry.new(5)
        VALUE = Entry.new(6)

        def self.from_byte(b)
          return Entry.new(b) if (0..6).cover?(b)

          nil
        end
      end

      class VectorCodec
        Entry = Data.define(:value)
        PLAIN = Entry.new(0)
        DIRECT_BITPACK = Entry.new(1)
        DELTA_BITPACK = Entry.new(2)
        FOR_BITPACK = Entry.new(3)
        DELTA_FOR_BITPACK = Entry.new(4)
        DELTA_DELTA_BITPACK = Entry.new(5)
        RLE = Entry.new(6)
        PATCHED_FOR = Entry.new(7)
        SIMPLE8B = Entry.new(8)
        XOR_FLOAT = Entry.new(9)
        DICTIONARY = Entry.new(10)
        STRING_REF = Entry.new(11)
        PREFIX_DELTA = Entry.new(12)

        def self.from_byte(b)
          return Entry.new(b) if b <= 12

          nil
        end
      end

      TypedVectorData = Data.define(:bools, :i64s, :u64s, :f64s, :strings, :binary, :values, :kind)
      TypedVector = Data.define(:element_type, :codec, :data)

      SchemaField = Data.define(
        :number, :name, :logical_type, :required, :default_value, :min, :max, :enum_values
      )

      Schema = Data.define(:schema_id, :name, :fields)

      class NullStrategy
        Entry = Data.define(:value)
        NONE = Entry.new(0)
        PRESENCE_BITMAP = Entry.new(1)
        INVERTED_PRESENCE_BITMAP = Entry.new(2)
        ALL_PRESENT_ELIDED = Entry.new(3)

        def self.from_byte(b)
          return Entry.new(b) if (0..3).cover?(b)

          nil
        end
      end

      Column = Data.define(
        :field_id, :null_strategy, :presence, :has_presence, :codec, :dictionary_id, :values
      )

      class ControlOpcode
        Entry = Data.define(:value)
        REGISTER_KEYS = Entry.new(0)
        REGISTER_SHAPE = Entry.new(1)
        REGISTER_STRINGS = Entry.new(2)
        PROMOTE_STRING_FIELD_TO_ENUM = Entry.new(3)
        RESET_TABLES = Entry.new(4)
        RESET_STATE = Entry.new(5)

        def self.from_byte(b)
          return Entry.new(b) if (0..5).cover?(b)

          nil
        end
      end

      ControlMessage = Data.define(
        :register_keys, :register_shape, :register_strings, :promote_string_field_to_enum,
        :reset_tables, :reset_state, :opcode
      )

      RegisterShapeControl = Data.define(:shape_id, :keys)
      PromoteEnumControl = Data.define(:field_identity, :values)

      class PatchOpcode
        Entry = Data.define(:value)
        KEEP = Entry.new(0)
        REPLACE_SCALAR = Entry.new(1)
        REPLACE_VECTOR = Entry.new(2)
        APPEND_VECTOR = Entry.new(3)
        TRUNCATE_VECTOR = Entry.new(4)
        DELETE_FIELD = Entry.new(5)
        INSERT_FIELD = Entry.new(6)
        STRING_REF = Entry.new(7)
        PREFIX_DELTA = Entry.new(8)

        def self.from_byte(b)
          return Entry.new(b) if b <= 8

          nil
        end
      end

      BaseRef = Data.define(:previous, :base_id) do
        def self.previous
          new(previous: true, base_id: 0)
        end

        def self.id_ref(id)
          new(previous: false, base_id: id)
        end
      end

      PatchOperation = Data.define(:field_id, :opcode, :value)

      class ControlStreamCodec
        Entry = Data.define(:value)
        PLAIN = Entry.new(0)
        RLE = Entry.new(1)
        BITPACK = Entry.new(2)
        HUFFMAN = Entry.new(3)
        FSE = Entry.new(4)

        def self.from_byte(b)
          return Entry.new(b) if b <= 4

          nil
        end
      end

      Message = Data.define(
        :scalar, :array, :map, :shaped_object, :schema_object, :typed_vector, :row_batch,
        :column_batch, :control, :ext, :state_patch, :template_batch, :control_stream,
        :base_snapshot, :kind
      ) do
        def clone_message
          case kind
          when MessageKind::SCALAR
            v = scalar.clone_value
            Model.message(kind: kind, scalar: v)
          when MessageKind::ARRAY
            Model.message(kind: kind, array: array.map(&:clone_value))
          when MessageKind::MAP
            Model.message(kind: kind, map: map.map { |e| MessageMapEntry.new(e.key, e.value.clone_value) })
          when MessageKind::SHAPED_OBJECT
            s = shaped_object
            vals = s.values.map(&:clone_value)
            pres = s.has_presence ? s.presence.dup : nil
            Model.message(kind: kind, shaped_object: ShapedObjectMessage.new(
              shape_id: s.shape_id, presence: pres, has_presence: s.has_presence, values: vals
            ))
          when MessageKind::SCHEMA_OBJECT
            s = schema_object
            fields = s.fields.map(&:clone_value)
            pres = s.has_presence ? s.presence.dup : nil
            sid = s.schema_id
            Model.message(kind: kind, schema_object: SchemaObjectMessage.new(
              schema_id: sid, presence: pres, has_presence: s.has_presence, fields: fields
            ))
          when MessageKind::TYPED_VECTOR
            Model.message(kind: kind, typed_vector: Model.clone_typed_vector(typed_vector))
          when MessageKind::ROW_BATCH
            rows = row_batch.rows.map { |r| r.map(&:clone_value) }
            Model.message(kind: kind, row_batch: RowBatchMessage.new(rows: rows))
          when MessageKind::COLUMN_BATCH
            cols = column_batch.columns.map { |c| Model.clone_column(c) }
            Model.message(kind: kind, column_batch: ColumnBatchMessage.new(
              count: column_batch.count, columns: cols
            ))
          when MessageKind::CONTROL
            Model.message(kind: kind, control: Model.clone_control(control))
          when MessageKind::EXT
            Model.message(kind: kind, ext: ExtMessage.new(
              ext_type: ext.ext_type, payload: ext.payload.b.dup
            ))
          when MessageKind::STATE_PATCH
            sp = state_patch
            ops = sp.operations.map do |op|
              val = op.value ? op.value.clone_value : nil
              PatchOperation.new(field_id: op.field_id, opcode: op.opcode, value: val)
            end
            lits = sp.literals.map(&:clone_value)
            Model.message(kind: kind, state_patch: StatePatchMessage.new(
              base_ref: sp.base_ref, operations: ops, literals: lits
            ))
          when MessageKind::TEMPLATE_BATCH
            tb = template_batch
            cols = tb.columns.map { |c| Model.clone_column(c) }
            Model.message(kind: kind, template_batch: TemplateBatchMessage.new(
              template_id: tb.template_id, count: tb.count,
              changed_column_mask: tb.changed_column_mask.dup, columns: cols
            ))
          when MessageKind::CONTROL_STREAM
            cs = control_stream
            Model.message(kind: kind, control_stream: ControlStreamMessage.new(
              codec: cs.codec, payload: cs.payload.b.dup
            ))
          when MessageKind::BASE_SNAPSHOT
            bs = base_snapshot
            Model.message(kind: kind, base_snapshot: BaseSnapshotMessage.new(
              base_id: bs.base_id, schema_or_shape_ref: bs.schema_or_shape_ref,
              payload: bs.payload.clone_message
            ))
          else
            Model.message(kind: MessageKind::SCALAR)
          end
        end
      end

      ShapedObjectMessage = Data.define(:shape_id, :presence, :has_presence, :values)
      SchemaObjectMessage = Data.define(:schema_id, :presence, :has_presence, :fields)
      RowBatchMessage = Data.define(:rows)
      ColumnBatchMessage = Data.define(:count, :columns)
      ExtMessage = Data.define(:ext_type, :payload)
      StatePatchMessage = Data.define(:base_ref, :operations, :literals)
      TemplateBatchMessage = Data.define(:template_id, :count, :changed_column_mask, :columns)
      ControlStreamMessage = Data.define(:codec, :payload)
      BaseSnapshotMessage = Data.define(:base_id, :schema_or_shape_ref, :payload)
      TemplateDescriptor = Data.define(:template_id, :field_ids, :null_strategies, :codecs)

      EMPTY_MESSAGE_FIELDS = {
        scalar: nil, array: nil, map: nil, shaped_object: nil, schema_object: nil,
        typed_vector: nil, row_batch: nil, column_batch: nil, control: nil, ext: nil,
        state_patch: nil, template_batch: nil, control_stream: nil, base_snapshot: nil
      }.freeze

      def self.message(kind:, **kwargs)
        Message.new(**EMPTY_MESSAGE_FIELDS, kind: kind, **kwargs)
      end

      module_function

      def null_value
        Value.new(kind: ValueKind::NULL, bool: false, i64: 0, u64: 0, f64: 0.0,
                  str: "", bin: +"", arr: [], map: [])
      end

      def bool_value(b)
        Value.new(kind: ValueKind::BOOL, bool: b, i64: 0, u64: 0, f64: 0.0,
                  str: "", bin: +"", arr: [], map: [])
      end

      def i64_value(n)
        Value.new(kind: ValueKind::I64, bool: false, i64: n, u64: 0, f64: 0.0,
                  str: "", bin: +"", arr: [], map: [])
      end

      def u64_value(n)
        Value.new(kind: ValueKind::U64, bool: false, i64: 0, u64: n, f64: 0.0,
                  str: "", bin: +"", arr: [], map: [])
      end

      def f64_value(n)
        Value.new(kind: ValueKind::F64, bool: false, i64: 0, u64: 0, f64: n,
                  str: "", bin: +"", arr: [], map: [])
      end

      def string_value(s)
        Value.new(kind: ValueKind::STRING, bool: false, i64: 0, u64: 0, f64: 0.0,
                  str: s, bin: +"", arr: [], map: [])
      end

      def binary_value(b)
        Value.new(kind: ValueKind::BINARY, bool: false, i64: 0, u64: 0, f64: 0.0,
                  str: "", bin: b.b.dup, arr: [], map: [])
      end

      def array_value(items)
        Value.new(kind: ValueKind::ARRAY, bool: false, i64: 0, u64: 0, f64: 0.0,
                  str: "", bin: +"", arr: items.map(&:clone_value), map: [])
      end

      def entry(key, value)
        MapEntry.new(key, value)
      end

      def map_value(entries = nil, **kwargs)
        if kwargs.any?
          entries = kwargs.map { |k, v| MapEntry.new(k.to_s, v) }
        elsif entries.is_a?(Hash)
          entries = entries.map { |k, v| MapEntry.new(k.to_s, v) }
        end
        entries ||= []
        Value.new(kind: ValueKind::MAP, bool: false, i64: 0, u64: 0, f64: 0.0,
                  str: "", bin: +"", arr: [],
                  map: entries.map { |e| MapEntry.new(e.key, e.value.clone_value) })
      end

      def equal(a, b)
        return false unless a.kind == b.kind

        case a.kind
        when ValueKind::NULL then true
        when ValueKind::BOOL then a.bool == b.bool
        when ValueKind::I64 then a.i64 == b.i64
        when ValueKind::U64 then a.u64 == b.u64
        when ValueKind::F64 then a.f64 == b.f64
        when ValueKind::STRING then a.str == b.str
        when ValueKind::BINARY then a.bin == b.bin
        when ValueKind::ARRAY
          return false unless a.arr.length == b.arr.length

          a.arr.each_with_index.all? { |v, i| equal(v, b.arr[i]) }
        when ValueKind::MAP
          return false unless a.map.length == b.map.length

          a.map.each_with_index.all? do |e, i|
            e.key == b.map[i].key && equal(e.value, b.map[i].value)
          end
        else
          false
        end
      end

      def clone_typed_vector(tv)
        return nil unless tv

        data = tv.data
        out_data = case tv.element_type
                   when ElementType::BOOL
                     TypedVectorData.new(bools: data.bools.dup, i64s: [], u64s: [], f64s: [],
                                         strings: [], binary: [], values: [], kind: tv.element_type)
                   when ElementType::I64
                     TypedVectorData.new(bools: [], i64s: data.i64s.dup, u64s: [], f64s: [],
                                         strings: [], binary: [], values: [], kind: tv.element_type)
                   when ElementType::U64
                     TypedVectorData.new(bools: [], i64s: [], u64s: data.u64s.dup, f64s: [],
                                         strings: [], binary: [], values: [], kind: tv.element_type)
                   when ElementType::F64
                     TypedVectorData.new(bools: [], i64s: [], u64s: [], f64s: data.f64s.dup,
                                         strings: [], binary: [], values: [], kind: tv.element_type)
                   when ElementType::STRING
                     TypedVectorData.new(bools: [], i64s: [], u64s: [], f64s: [],
                                         strings: data.strings.dup, binary: [], values: [],
                                         kind: tv.element_type)
                   when ElementType::BINARY
                     TypedVectorData.new(bools: [], i64s: [], u64s: [], f64s: [],
                                         strings: [], binary: data.binary.map(&:b), values: [],
                                         kind: tv.element_type)
                   when ElementType::VALUE
                     TypedVectorData.new(bools: [], i64s: [], u64s: [], f64s: [],
                                         strings: [], binary: [],
                                         values: data.values.map(&:clone_value), kind: tv.element_type)
                   else
                     TypedVectorData.new(bools: [], i64s: [], u64s: [], f64s: [],
                                         strings: [], binary: [], values: [], kind: tv.element_type)
                   end
        TypedVector.new(element_type: tv.element_type, codec: tv.codec, data: out_data)
      end

      def clone_column(c)
        pres = c.has_presence ? c.presence.dup : nil
        dict_id = c.dictionary_id
        Column.new(
          field_id: c.field_id, null_strategy: c.null_strategy, presence: pres,
          has_presence: c.has_presence, codec: c.codec, dictionary_id: dict_id,
          values: clone_typed_vector_data(c.values)
        )
      end

      def clone_typed_vector_data(d)
        TypedVectorData.new(
          bools: d.bools.dup, i64s: d.i64s.dup, u64s: d.u64s.dup, f64s: d.f64s.dup,
          strings: d.strings.dup, binary: d.binary.map(&:b), values: d.values.map(&:clone_value),
          kind: d.kind
        )
      end

      def clone_control(c)
        return nil unless c

        rs = if c.register_shape
               RegisterShapeControl.new(
                 shape_id: c.register_shape.shape_id,
                 keys: c.register_shape.keys.dup
               )
             end
        pe = if c.promote_string_field_to_enum
               PromoteEnumControl.new(
                 field_identity: c.promote_string_field_to_enum.field_identity,
                 values: c.promote_string_field_to_enum.values.dup
               )
             end
        ControlMessage.new(
          register_keys: c.register_keys.dup, register_shape: rs,
          register_strings: c.register_strings.dup,
          promote_string_field_to_enum: pe, reset_tables: c.reset_tables,
          reset_state: c.reset_state, opcode: c.opcode
        )
      end
    end
  end
end
