# frozen_string_literal: true

require "digest"

module Twilic
  module Core
    module Session
      class UnknownReferencePolicy
        Entry = Data.define(:name)
        FAIL_FAST = Entry.new(:fail_fast)
        STATELESS_RETRY = Entry.new(:stateless_retry)
      end

      class DictionaryFallback
        Entry = Data.define(:name)
        FAIL_FAST = Entry.new(:fail_fast)
        STATELESS_RETRY = Entry.new(:stateless_retry)

        def self.from_byte(b)
          case b
          when 0 then FAIL_FAST
          when 1 then STATELESS_RETRY
          end
        end
      end

      DictionaryProfile = Data.define(:version, :hash, :expires_at, :fallback)

      SessionOptions = Data.define(
        :max_base_snapshots, :enable_state_patch, :enable_template_batch,
        :enable_trained_dictionary, :unknown_reference_policy
      ) do
        def self.default
          new(
            max_base_snapshots: 8,
            enable_state_patch: true,
            enable_template_batch: true,
            enable_trained_dictionary: true,
            unknown_reference_policy: UnknownReferencePolicy::FAIL_FAST
          )
        end
      end

      InternTable = Data.define(:by_value, :by_id) do
        def self.new_table
          new(by_value: {}, by_id: [])
        end

        def get_id(value)
          id = by_value[value]
          id ? [id, true] : [0, false]
        end

        def get_value(id)
          return ["", false] if id >= by_id.length

          [by_id[id], true]
        end

        def register(value)
          id, ok = get_id(value)
          return id if ok

          id = by_id.length
          new(by_value: by_value.merge(value => id), by_id: by_id + [value])
        end

        def clear
          new(by_value: {}, by_id: [])
        end
      end

      ShapeTable = Data.define(:by_keys, :by_id, :observations, :next_id) do
        def self.new_table
          new(by_keys: {}, by_id: {}, observations: {}, next_id: 0)
        end

        def shape_key(keys)
          keys.join("\0")
        end

        def get_id(keys)
          id = by_keys[shape_key(keys)]
          id ? [id, true] : [0, false]
        end

        def get_keys(id)
          keys = by_id[id]
          keys ? [keys, true] : [nil, false]
        end

        def register(keys)
          sk = shape_key(keys)
          id = by_keys[sk]
          return id if id

          id = next_id
          keys_copy = keys.dup
          new(
            by_keys: by_keys.merge(sk => id),
            by_id: by_id.merge(id => keys_copy),
            observations: observations,
            next_id: id + 1
          ).then { |t| t.by_keys[sk] }
        end

        def register_with_id(shape_id, keys)
          sk = shape_key(keys)
          if by_id.key?(shape_id)
            return shape_key(by_id[shape_id]) == sk
          end
          return false if by_keys.key?(sk) && by_keys[sk] != shape_id

          keys_copy = keys.dup
          new_by_id = by_id.merge(shape_id => keys_copy)
          new_by_keys = by_keys.merge(sk => shape_id)
          new_next = [next_id, shape_id + 1].max
          replace(by_id: new_by_id, by_keys: new_by_keys, next_id: new_next)
          true
        end

        def observe(keys)
          sk = shape_key(keys)
          count = (observations[sk] || 0) + 1
          replace(observations: observations.merge(sk => count))
          count
        end

        def clear
          new(by_keys: {}, by_id: {}, observations: {}, next_id: 0)
        end
      end

      BaseSnapshotEntry = Data.define(:id, :message)

      SessionState = Data.define(
        :options, :key_table, :string_table, :shape_table, :encode_shape_observations,
        :base_snapshots, :templates, :template_columns, :field_enums, :dictionaries,
        :dictionary_profiles, :schemas, :last_schema_id, :previous_message,
        :previous_message_size, :next_base_id, :next_template_id, :next_dictionary_id
      ) do
        def self.new_state
          new(
            options: SessionOptions.default,
            key_table: InternTable.new_table,
            string_table: InternTable.new_table,
            shape_table: ShapeTable.new_table,
            encode_shape_observations: {},
            base_snapshots: [],
            templates: {},
            template_columns: {},
            field_enums: {},
            dictionaries: {},
            dictionary_profiles: {},
            schemas: {},
            last_schema_id: nil,
            previous_message: nil,
            previous_message_size: nil,
            next_base_id: 0,
            next_template_id: 0,
            next_dictionary_id: 0
          )
        end

        def self.with_options(options)
          new_state.with(options: options)
        end

        def register_base_snapshot(base_id, message)
          filtered = base_snapshots.reject { |e| e.id == base_id }
          filtered << BaseSnapshotEntry.new(id: base_id, message: message.clone_message)
          while filtered.length > options.max_base_snapshots
            filtered.shift
          end
          with(base_snapshots: filtered)
        end

        def allocate_base_id
          id = next_base_id
          with(next_base_id: next_base_id + 1).next_base_id == id ? id : id
        end

        def allocate_template_id
          id = next_template_id
          with(next_template_id: next_template_id + 1)
          id
        end

        def allocate_dictionary_id
          id = next_dictionary_id
          with(next_dictionary_id: next_dictionary_id + 1)
          id
        end

        def get_base_snapshot(base_id)
          entry = base_snapshots.find { |e| e.id == base_id }
          return [nil, false] unless entry

          [entry.message.clone_message, true]
        end

        def reset_tables
          with(
            key_table: InternTable.new_table,
            string_table: InternTable.new_table,
            shape_table: ShapeTable.new_table,
            encode_shape_observations: {},
            field_enums: {}
          )
        end

        def reset_state
          reset_tables.with(
            base_snapshots: [],
            templates: {},
            template_columns: {},
            dictionaries: {},
            dictionary_profiles: {},
            schemas: {},
            last_schema_id: nil,
            previous_message: nil,
            previous_message_size: nil,
            next_base_id: 0,
            next_template_id: 0,
            next_dictionary_id: 0
          )
        end
      end

      # Mutable wrapper for session state used during encode/decode
      class MutableSessionState
        attr_accessor :options, :key_table, :string_table, :shape_table,
                      :encode_shape_observations, :base_snapshots, :templates,
                      :template_columns, :field_enums, :dictionaries,
                      :dictionary_profiles, :schemas, :last_schema_id,
                      :previous_message, :previous_message_size,
                      :next_base_id, :next_template_id, :next_dictionary_id

        def initialize(options = SessionOptions.default)
          @options = options
          @key_table = MutableInternTable.new
          @string_table = MutableInternTable.new
          @shape_table = MutableShapeTable.new
          @encode_shape_observations = {}
          @base_snapshots = []
          @templates = {}
          @template_columns = {}
          @field_enums = {}
          @dictionaries = {}
          @dictionary_profiles = {}
          @schemas = {}
          @last_schema_id = nil
          @previous_message = nil
          @previous_message_size = nil
          @next_base_id = 0
          @next_template_id = 0
          @next_dictionary_id = 0
        end

        def shape_key(keys)
          keys.join("\0")
        end

        def register_base_snapshot(base_id, message)
          @base_snapshots.reject! { |e| e.id == base_id }
          @base_snapshots << BaseSnapshotEntry.new(id: base_id, message: message.clone_message)
          while @base_snapshots.length > @options.max_base_snapshots
            @base_snapshots.shift
          end
        end

        def allocate_base_id
          id = @next_base_id
          @next_base_id += 1
          id
        end

        def allocate_template_id
          id = @next_template_id
          @next_template_id += 1
          id
        end

        def allocate_dictionary_id
          id = @next_dictionary_id
          @next_dictionary_id += 1
          id
        end

        def get_base_snapshot(base_id)
          entry = @base_snapshots.find { |e| e.id == base_id }
          return [nil, false] unless entry

          [entry.message.clone_message, true]
        end

        def reset_tables
          @key_table = MutableInternTable.new
          @string_table = MutableInternTable.new
          @shape_table = MutableShapeTable.new
          @encode_shape_observations = {}
          @field_enums = {}
        end

        def reset_state
          reset_tables
          @base_snapshots = []
          @templates = {}
          @template_columns = {}
          @dictionaries = {}
          @dictionary_profiles = {}
          @schemas = {}
          @last_schema_id = nil
          @previous_message = nil
          @previous_message_size = nil
          @next_base_id = 0
          @next_template_id = 0
          @next_dictionary_id = 0
        end
      end

      module InternTableHelpers
        module_function

        def get_id(table, value)
          id = table.by_value[value]
          id ? [id, true] : [0, false]
        end

        def get_value(table, id)
          return ["", false] if id >= table.by_id.length

          [table.by_id[id], true]
        end

        def register(table, value)
          id, ok = get_id(table, value)
          return [table, id] if ok

          id = table.by_id.length
          new_table = InternTable.new(
            by_value: table.by_value.merge(value => id),
            by_id: table.by_id + [value]
          )
          [new_table, id]
        end

        def register_mut(table, value)
          id = table.by_value[value]
          return id if id

          id = table.by_id.length
          table.by_value[value] = id
          table.by_id << value
          id
        end
      end

      class MutableInternTable
        attr_reader :by_value, :by_id

        def initialize
          @by_value = {}
          @by_id = []
        end

        def get_id(value)
          id = @by_value[value]
          id ? [id, true] : [0, false]
        end

        def get_value(id)
          return ["", false] if id >= @by_id.length

          [@by_id[id], true]
        end

        def register(value)
          id = @by_value[value]
          return id if id

          id = @by_id.length
          @by_value[value] = id
          @by_id << value
          id
        end

        def clear
          @by_value = {}
          @by_id = []
        end
      end

      class MutableShapeTable
        attr_reader :by_keys, :by_id, :observations, :next_id

        def initialize
          @by_keys = {}
          @by_id = {}
          @observations = {}
          @next_id = 0
        end

        def shape_key(keys)
          keys.join("\0")
        end

        def get_id(keys)
          id = @by_keys[shape_key(keys)]
          id ? [id, true] : [0, false]
        end

        def get_keys(id)
          keys = @by_id[id]
          keys ? [keys.dup, true] : [nil, false]
        end

        def register(keys)
          sk = shape_key(keys)
          id = @by_keys[sk]
          return id if id

          id = @next_id
          @next_id += 1
          @by_id[id] = keys.dup
          @by_keys[sk] = id
          id
        end

        def register_with_id(shape_id, keys)
          sk = shape_key(keys)
          if @by_id.key?(shape_id)
            return shape_key(@by_id[shape_id]) == sk
          end
          return false if @by_keys.key?(sk) && @by_keys[sk] != shape_id

          @by_id[shape_id] = keys.dup
          @by_keys[sk] = shape_id
          @next_id = [@next_id, shape_id + 1].max
          true
        end

        def observe(keys)
          sk = shape_key(keys)
          @observations[sk] = (@observations[sk] || 0) + 1
        end

        def observation_count(keys)
          @observations[shape_key(keys)] || 0
        end

        def clear
          @by_keys = {}
          @by_id = {}
          @observations = {}
          @next_id = 0
        end
      end
    end
  end
end
