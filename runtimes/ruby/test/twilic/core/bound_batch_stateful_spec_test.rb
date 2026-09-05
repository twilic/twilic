# frozen_string_literal: true

require "test_helper"

class BoundBatchStatefulSpecTest < Minitest::Test
  include TwilicTestHelpers

  def test_schema_id_is_sent_first_then_omitted
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    schema = sample_schema
    value = Twilic.map(
      "id" => Twilic.u64(1005),
      "name" => Twilic.string("alice"),
      "score" => Twilic.i64(99)
    )

    first_msg = enc.decode_message(enc.encode_with_schema(schema, value))
    assert_equal Twilic::MessageKind::SCHEMA_OBJECT, first_msg.kind
    refute_nil first_msg.schema_object.schema_id
    assert_equal 41, first_msg.schema_object.schema_id

    second_msg = enc.decode_message(enc.encode_with_schema(schema, value))
    assert_equal Twilic::MessageKind::SCHEMA_OBJECT, second_msg.kind
  end

  def test_batch_threshold_selects_row_vs_column
    enc = Twilic.new_session_encoder(Twilic.default_session_options)

    rows15 = Array.new(15) { |i| Twilic.map("id" => Twilic.u64(i)) }
    b15 = enc.encode_batch(rows15)
    refute_empty b15
    kind15 = Twilic::MessageKind.from_byte(b15.getbyte(0))
    assert_includes [Twilic::MessageKind::COLUMN_BATCH, Twilic::MessageKind::ROW_BATCH], kind15

    rows16 = Array.new(16) { |i| Twilic.map("id" => Twilic.u64(i)) }
    b16 = enc.encode_batch(rows16)
    refute_empty b16
    assert_equal Twilic::MessageKind::COLUMN_BATCH, Twilic::MessageKind.from_byte(b16.getbyte(0))
  end

  def test_micro_batch_reuses_template_and_emits_changed_mask
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    rows1 = [
      Twilic.map("id" => Twilic.u64(1), "name" => Twilic.string("a")),
      Twilic.map("id" => Twilic.u64(2), "name" => Twilic.string("b")),
      Twilic.map("id" => Twilic.u64(3), "name" => Twilic.string("c")),
      Twilic.map("id" => Twilic.u64(4), "name" => Twilic.string("d"))
    ]
    first = enc.encode_micro_batch(rows1)
    refute_empty first
    assert_equal Twilic::MessageKind::TEMPLATE_BATCH, Twilic::MessageKind.from_byte(first.getbyte(0))

    rows2 = [
      Twilic.map("id" => Twilic.u64(1), "name" => Twilic.string("aa")),
      Twilic.map("id" => Twilic.u64(2), "name" => Twilic.string("bb")),
      Twilic.map("id" => Twilic.u64(3), "name" => Twilic.string("cc")),
      Twilic.map("id" => Twilic.u64(4), "name" => Twilic.string("dd"))
    ]
    second = enc.encode_micro_batch(rows2)
    refute_empty second
    assert_equal Twilic::MessageKind::TEMPLATE_BATCH, Twilic::MessageKind.from_byte(second.getbyte(0))
  end

  def test_state_patch_uses_recommended_ratio_threshold
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    base_values = Array.new(100) { |i| Twilic.i64(i) }
    one_change_values = base_values.dup
    one_change_values[0] = Twilic.i64(10_000)
    twelve_change_values = base_values.dup
    12.times { |i| twelve_change_values[i] = Twilic.i64(10_000 + i) }

    base = Twilic.array(base_values)
    one_change = Twilic.array(one_change_values)
    twelve_changes = Twilic.array(twelve_change_values)

    enc.encode(base)
    p1 = enc.encode_patch(one_change)
    enc.decode_message(p1)

    p2 = enc.encode_patch(twelve_changes)
    enc.decode_message(p2)
  end

  def test_unknown_base_id_honors_stateless_retry_policy
    opts = Twilic.default_session_options
    opts = Twilic::SessionOptions.new(
      max_base_snapshots: opts.max_base_snapshots,
      enable_state_patch: opts.enable_state_patch,
      enable_template_batch: opts.enable_template_batch,
      enable_trained_dictionary: opts.enable_trained_dictionary,
      unknown_reference_policy: Twilic::UnknownReferencePolicy::STATELESS_RETRY
    )
    enc = Twilic.new_session_encoder(opts)

    patch = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::STATE_PATCH,
      state_patch: Twilic::StatePatchMessage.new(
        base_ref: Twilic::BaseRef.id_ref(12_345),
        operations: [],
        literals: []
      )
    )
    builder = Twilic.new_twilic_codec
    bytes = builder.encode_message(patch)
    err = assert_raises(Twilic::TwilicError) { enc.decode_message(bytes) }
    te = require_twilic_error_kind(err, Twilic::ERR_STATELESS_RETRY_REQUIRED)
    assert_equal "base_id", te.ref_kind
    assert_equal 12_345, te.ref_id
  end

  def test_state_patch_map_insert_and_delete_roundtrip_via_reconstruction
    codec = Twilic.new_twilic_codec
    base = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::MAP,
      map: [
        message_map_entry("id", Twilic.u64(1)),
        message_map_entry("name", Twilic.string("alice"))
      ]
    )
    base_bytes = codec.encode_message(base)
    codec.decode_message(base_bytes)

    insert_value = Twilic.map("role" => Twilic.string("admin"))
    insert_patch = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::STATE_PATCH,
      state_patch: Twilic::StatePatchMessage.new(
        base_ref: Twilic::BaseRef.previous,
        operations: [
          Twilic::PatchOperation.new(
            field_id: 2,
            opcode: Twilic::PatchOpcode::INSERT_FIELD,
            value: insert_value
          )
        ],
        literals: []
      )
    )
    codec.decode_message(codec.encode_message(insert_patch))
    assert_equal Twilic::MessageKind::MAP, codec.state.previous_message.kind

    delete_patch = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::STATE_PATCH,
      state_patch: Twilic::StatePatchMessage.new(
        base_ref: Twilic::BaseRef.previous,
        operations: [
          Twilic::PatchOperation.new(
            field_id: 2,
            opcode: Twilic::PatchOpcode::DELETE_FIELD,
            value: nil
          )
        ],
        literals: []
      )
    )
    codec.decode_message(codec.encode_message(delete_patch))
    assert_equal Twilic::MessageKind::MAP, codec.state.previous_message.kind
    assert_equal 2, codec.state.previous_message.map.length
  end

  def test_column_batch_assigns_dictionary_id_for_repeated_string_field
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    rows = Array.new(32) do |i|
      role = i.even? ? "admin" : "user"
      Twilic.map("id" => Twilic.u64(i), "role" => Twilic.string(role))
    end
    bytes = enc.encode_batch(rows)
    refute_empty bytes
    assert_equal Twilic::MessageKind::COLUMN_BATCH, Twilic::MessageKind.from_byte(bytes.getbyte(0))
  end

  def test_trained_dictionary_profile_is_transported_to_fresh_decoder
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    rows = Array.new(32) do |i|
      role = i.even? ? "admin" : "user"
      Twilic.map("id" => Twilic.u64(i), "role" => Twilic.string(role))
    end
    bytes = enc.encode_batch(rows)
    dec = Twilic.new_twilic_codec
    decoded = dec.decode_message(bytes)
    assert_equal Twilic::MessageKind::COLUMN_BATCH, decoded.kind
    refute_nil decoded.column_batch

    dict_id = decoded.column_batch.columns.find { |c| c.dictionary_id }&.dictionary_id
    refute_nil dict_id, "dictionary id in batch"

    payload = dec.state.dictionaries[dict_id]
    refute_nil payload, "transported dictionary payload"

    profile = dec.state.dictionary_profiles[dict_id]
    refute_nil profile, "transported dictionary profile"
    assert_equal 1, profile.version
    assert_equal 0, profile.expires_at
    assert_equal Twilic::DictionaryFallback::FAIL_FAST, profile.fallback
    assert_equal Twilic::Core::Dictionary.dictionary_payload_hash(payload), profile.hash

    role_col = decoded.column_batch.columns.find { |c| c.dictionary_id == dict_id }
    role_values = role_col.values.strings
    assert_equal 32, role_values.length
    assert_equal "admin", role_values[0]
    assert_equal "user", role_values[1]
  end

  def test_invalid_dictionary_profile_hash_is_rejected
    enc = Twilic.new_twilic_codec
    dict_id = 42
    enc.state.dictionaries[dict_id] = [1, 2, 3, 4].pack("C*")
    enc.state.dictionary_profiles[dict_id] = Twilic::DictionaryProfile.new(
      version: 1,
      hash: 7,
      expires_at: 0,
      fallback: Twilic::DictionaryFallback::FAIL_FAST
    )

    msg = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::COLUMN_BATCH,
      column_batch: Twilic::ColumnBatchMessage.new(
        count: 1,
        columns: [
          Twilic::Column.new(
            field_id: 0,
            null_strategy: Twilic::NullStrategy::ALL_PRESENT_ELIDED,
            presence: [],
            has_presence: false,
            codec: Twilic::VectorCodec::DICTIONARY,
            dictionary_id: dict_id,
            values: empty_typed_vector_data(Twilic::ElementType::STRING).with(strings: ["admin"])
          )
        ]
      )
    )
    bytes = enc.encode_message(msg)
    dec = Twilic.new_twilic_codec
    err = assert_raises(Twilic::TwilicError) { dec.decode_message(bytes) }
    assert_equal Twilic::ERR_INVALID_DATA, err.kind
    assert_equal "dictionary profile hash mismatch", err.msg
  end

  def test_trained_dictionary_reference_writes_compressed_block_after_dict_id
    dict_id = 9
    codec = Twilic.new_twilic_codec
    payload = +""
    Twilic::Core::Wire.encode_varuint(2, payload)
    Twilic::Core::Wire.encode_string("admin", payload)
    Twilic::Core::Wire.encode_string("user", payload)
    codec.state.dictionaries[dict_id] = payload
    codec.state.dictionary_profiles[dict_id] = Twilic::DictionaryProfile.new(
      version: 1,
      hash: Twilic::Core::Dictionary.dictionary_payload_hash(payload),
      expires_at: 0,
      fallback: Twilic::DictionaryFallback::FAIL_FAST
    )

    msg = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::COLUMN_BATCH,
      column_batch: Twilic::ColumnBatchMessage.new(
        count: 4,
        columns: [
          Twilic::Column.new(
            field_id: 1,
            null_strategy: Twilic::NullStrategy::ALL_PRESENT_ELIDED,
            presence: [],
            has_presence: false,
            codec: Twilic::VectorCodec::DICTIONARY,
            dictionary_id: dict_id,
            values: empty_typed_vector_data(Twilic::ElementType::STRING).with(
              strings: %w[admin user admin user]
            )
          )
        ]
      )
    )
    bytes = codec.encode_message(msg)

    reader = Twilic::Core::Wire::Reader.new(bytes)
    assert_equal Twilic::MessageKind::COLUMN_BATCH.value, reader.read_u8
    reader.read_varuint
    reader.read_varuint
    reader.read_varuint
    reader.read_u8
    reader.read_u8
    got_dict_id = reader.read_varuint
    refute_equal 0, got_dict_id

    fresh = Twilic.new_twilic_codec
    decoded = fresh.decode_message(bytes)
    assert_equal Twilic::MessageKind::COLUMN_BATCH, decoded.kind
    refute_nil decoded.column_batch
    assert_equal %w[admin user admin user], decoded.column_batch.columns[0].values.strings
  end
end
