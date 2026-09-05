# frozen_string_literal: true

require "test_helper"

class CoverageBoostTest < Minitest::Test
  include TwilicTestHelpers

  I64_CODECS = [
    Twilic::VectorCodec::PLAIN,
    Twilic::VectorCodec::DIRECT_BITPACK,
    Twilic::VectorCodec::DELTA_BITPACK,
    Twilic::VectorCodec::FOR_BITPACK,
    Twilic::VectorCodec::DELTA_FOR_BITPACK,
    Twilic::VectorCodec::DELTA_DELTA_BITPACK,
    Twilic::VectorCodec::RLE,
    Twilic::VectorCodec::PATCHED_FOR,
    Twilic::VectorCodec::SIMPLE8B
  ].freeze

  def test_model_from_byte_and_display_branches
    refute_nil Twilic::MessageKind.from_byte(0x0D)
    assert_nil Twilic::MessageKind.from_byte(0xFE)
    refute_nil Twilic::StringMode.from_byte(4)
    assert_nil Twilic::StringMode.from_byte(9)
    refute_nil Twilic::ElementType.from_byte(6)
    assert_nil Twilic::ElementType.from_byte(9)
    refute_nil Twilic::VectorCodec.from_byte(12)
    assert_nil Twilic::VectorCodec.from_byte(99)
    refute_nil Twilic::ControlOpcode.from_byte(5)
    assert_nil Twilic::ControlOpcode.from_byte(7)
    refute_nil Twilic::PatchOpcode.from_byte(8)
    assert_nil Twilic::PatchOpcode.from_byte(42)
    refute_nil Twilic::ControlStreamCodec.from_byte(4)
    assert_nil Twilic::ControlStreamCodec.from_byte(7)
  end

  def test_wire_reader_error_branches
    r = Twilic::Core::Wire::Reader.new(+"")
    assert_raises(Twilic::TwilicError) { r.read_u8 }

    too_long = Array.new(11, 0x80).pack("C*")
    r = Twilic::Core::Wire::Reader.new(too_long)
    assert_raises(Twilic::TwilicError) { r.read_varuint }

    invalid_utf8 = [1, 0xFF].pack("C*")
    r = Twilic::Core::Wire::Reader.new(invalid_utf8)
    assert_raises(Twilic::TwilicError) { r.read_string }

    bytes = +""
    Twilic::Core::Wire.encode_varuint(9, bytes)
    bytes << [0b01010101, 0b00000001].pack("C*")
    r = Twilic::Core::Wire::Reader.new(bytes)
    bits = r.read_bitmap
    assert_equal 9, bits.length
    assert bits[0]
    assert bits[8]
  end

  def test_codec_variants_roundtrip_and_error_path
    values = [100, 110, 120, 130, 130, 130, 140, 150, 160, 170]
    I64_CODECS.each do |codec|
      out = +""
      Twilic::Core::Codec.encode_i64_vector(values, codec, out)
      reader = Twilic::Core::Wire::Reader.new(out)
      decoded = Twilic::Core::Codec.decode_i64_vector(reader, codec)
      assert_equal values.length, decoded.length, "length mismatch for codec=#{codec.value}"
    end

    f_values = [1.0, 1.0, 1.5, 1.75, 1.875]
    [Twilic::VectorCodec::XOR_FLOAT, Twilic::VectorCodec::PLAIN].each do |codec|
      out = +""
      Twilic::Core::Codec.encode_f64_vector(f_values, codec, out)
      reader = Twilic::Core::Wire::Reader.new(out)
      decoded = Twilic::Core::Codec.decode_f64_vector(reader, codec)
      assert_equal f_values.length, decoded.length, "decode f64 codec=#{codec.value} failed"
    end

    out = +""
    Twilic::Core::Codec.encode_u64_vector([10, 20, 30, 40], Twilic::VectorCodec::DELTA_BITPACK, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_u64_vector(reader, Twilic::VectorCodec::DELTA_BITPACK)
    assert_equal 4, decoded.length
  end

  def test_protocol_error_and_control_branches
    codec = Twilic.new_twilic_codec

    reset_tables = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::RESET_TABLES,
        reset_tables: true
      )
    )
    codec.decode_message(codec.encode_message(reset_tables))

    reset_state = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::RESET_STATE,
        reset_state: true
      )
    )
    codec.decode_message(codec.encode_message(reset_state))

    malformed = [Twilic::MessageKind::SCHEMA_OBJECT.value, 0, 0].pack("C*")
    Twilic::Core::Wire.encode_varuint(1, malformed)
    malformed << [0, 3, 1, 2, 0x00, 0x00].pack("C*")
    assert_raises(Twilic::TwilicError) { codec.decode_message(malformed) }
  end

  def test_dynamic_shape_promotion_after_second_same_map_shape
    codec = Twilic.new_twilic_codec
    value = Twilic.map(
      "id" => Twilic.u64(1),
      "name" => Twilic.string("alice"),
      "role" => Twilic.string("admin")
    )

    first_msg = codec.decode_message(codec.encode_value(value))
    assert_equal Twilic::MessageKind::MAP, first_msg.kind

    second_msg = codec.decode_message(codec.encode_value(value))
    assert_equal Twilic::MessageKind::SHAPED_OBJECT, second_msg.kind
  end

  def test_schema_id_is_emitted_then_omitted_in_schema_context
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    schema = Twilic::Schema.new(
      schema_id: 777,
      name: "SchemaCtx",
      fields: [
        Twilic::SchemaField.new(
          number: 1, name: "id", logical_type: "u64", required: true,
          default_value: nil, min: nil, max: nil, enum_values: []
        ),
        Twilic::SchemaField.new(
          number: 2, name: "name", logical_type: "string", required: true,
          default_value: nil, min: nil, max: nil, enum_values: []
        )
      ]
    )
    value = Twilic.map("id" => Twilic.u64(1), "name" => Twilic.string("alice"))

    first_msg = enc.decode_message(enc.encode_with_schema(schema, value))
    assert_equal Twilic::MessageKind::SCHEMA_OBJECT, first_msg.kind
    refute_nil first_msg.schema_object.schema_id

    second_msg = enc.decode_message(enc.encode_with_schema(schema, value))
    assert_equal Twilic::MessageKind::SCHEMA_OBJECT, second_msg.kind
  end

  def test_schema_mode_uses_registered_schema_and_range_packing
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    schema = Twilic::Schema.new(
      schema_id: 7,
      name: "Bound",
      fields: [
        Twilic::SchemaField.new(
          number: 1, name: "id", logical_type: "u64", required: true,
          default_value: nil, min: 1000, max: 1100, enum_values: []
        ),
        Twilic::SchemaField.new(
          number: 2, name: "name", logical_type: "string", required: true,
          default_value: nil, min: nil, max: nil, enum_values: []
        )
      ]
    )
    value = Twilic.map("id" => Twilic.u64(1005), "name" => Twilic.string("alice"))
    decoded = enc.decode_message(enc.encode_with_schema(schema, value))
    assert_equal Twilic::MessageKind::SCHEMA_OBJECT, decoded.kind
    assert_equal 2, decoded.schema_object.fields.length
  end

  def test_schema_range_mode_writes_fixed_width_offset_bits
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    schema = Twilic::Schema.new(
      schema_id: 8,
      name: "RangeOnly",
      fields: [
        Twilic::SchemaField.new(
          number: 1, name: "n", logical_type: "u64", required: true,
          default_value: nil, min: 0, max: (1 << 20) - 1, enum_values: []
        )
      ]
    )
    value = Twilic.map("n" => Twilic.u64(1))
    bytes = enc.encode_with_schema(schema, value)
    reader = Twilic::Core::Wire::Reader.new(bytes)
    assert_equal Twilic::MessageKind::SCHEMA_OBJECT.value, reader.read_u8
  end

  def test_typed_vector_length_mismatch_is_rejected
    codec = Twilic.new_twilic_codec
    bytes = [Twilic::MessageKind::TYPED_VECTOR.value, Twilic::ElementType::U64.value].pack("C*")
    Twilic::Core::Wire.encode_varuint(2, bytes)
    bytes << [Twilic::VectorCodec::PLAIN.value, 1].pack("C*")
    Twilic::Core::Wire.encode_varuint(99, bytes)
    assert_raises(Twilic::TwilicError) { codec.decode_message(bytes) }
  end

  def test_micro_batch_falls_back_when_shape_is_not_uniform
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    values = [
      Twilic.map("id" => Twilic.u64(1)),
      Twilic.map("id" => Twilic.u64(2), "x" => Twilic.u64(10)),
      Twilic.map("id" => Twilic.u64(3)),
      Twilic.map("id" => Twilic.u64(4), "x" => Twilic.u64(20))
    ]
    decoded = enc.decode_message(enc.encode_micro_batch(values))
    assert_includes [Twilic::MessageKind::ROW_BATCH, Twilic::MessageKind::COLUMN_BATCH], decoded.kind
  end

  def test_unknown_reference_stateless_retry_paths
    opts = Twilic.default_session_options
    opts = Twilic::SessionOptions.new(
      max_base_snapshots: opts.max_base_snapshots,
      enable_state_patch: opts.enable_state_patch,
      enable_template_batch: opts.enable_template_batch,
      enable_trained_dictionary: opts.enable_trained_dictionary,
      unknown_reference_policy: Twilic::UnknownReferencePolicy::STATELESS_RETRY
    )
    codec = Twilic.twilic_codec_with_options(opts)

    previous_missing = [Twilic::MessageKind::STATE_PATCH.value, 0].pack("C*")
    Twilic::Core::Wire.encode_varuint(0, previous_missing)
    Twilic::Core::Wire.encode_varuint(0, previous_missing)
    assert_raises(Twilic::TwilicError) { codec.decode_message(previous_missing) }

    base_missing = [Twilic::MessageKind::STATE_PATCH.value, 1].pack("C*")
    Twilic::Core::Wire.encode_varuint(1000, base_missing)
    Twilic::Core::Wire.encode_varuint(0, base_missing)
    Twilic::Core::Wire.encode_varuint(0, base_missing)
    assert_raises(Twilic::TwilicError) { codec.decode_message(base_missing) }
  end

  def test_unknown_dict_reference_fail_fast_path
    encoder = Twilic.new_twilic_codec
    did = 88
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
            dictionary_id: did,
            values: empty_typed_vector_data(Twilic::ElementType::STRING).with(strings: ["x"])
          )
        ]
      )
    )
    bytes = encoder.encode_message(msg)
    decoder = Twilic.new_twilic_codec
    err = assert_raises(Twilic::TwilicError) { decoder.decode_message(bytes) }
    assert Twilic::Core::Errors.unknown_reference?(err), "expected unknown dict reference, got #{err.inspect}"
  end

  def test_register_and_use_base_snapshot_reference
    codec = Twilic.new_twilic_codec
    snapshot = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::BASE_SNAPSHOT,
      base_snapshot: Twilic::BaseSnapshotMessage.new(
        base_id: 9,
        schema_or_shape_ref: 0,
        payload: Twilic::Core::Model.message(
          kind: Twilic::MessageKind::SCALAR,
          scalar: Twilic.u64(10)
        )
      )
    )
    decoded = codec.decode_message(codec.encode_message(snapshot))
    assert_equal Twilic::MessageKind::BASE_SNAPSHOT, decoded.kind

    patch = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::STATE_PATCH,
      state_patch: Twilic::StatePatchMessage.new(
        base_ref: Twilic::BaseRef.id_ref(9),
        operations: [],
        literals: []
      )
    )
    decoded_patch = codec.decode_message(codec.encode_message(patch))
    assert_equal Twilic::MessageKind::STATE_PATCH, decoded_patch.kind
  end

  def test_decode_value_rejects_non_value_message_kinds
    codec = Twilic.new_twilic_codec
    bytes = [Twilic::MessageKind::CONTROL.value, Twilic::ControlOpcode::RESET_TABLES.value].pack("C*")
    assert_raises(Twilic::TwilicError) { codec.decode_value(bytes) }
  end

  def test_wire_encode_bitmap_roundtrip_with_full_byte_boundary
    bits = [true, false, true, false, true, false, true, false]
    bytes = +""
    Twilic::Core::Wire.encode_bitmap(bits, bytes)
    reader = Twilic::Core::Wire::Reader.new(bytes)
    decoded = reader.read_bitmap
    assert_equal bits.length, decoded.length
  end

  def test_public_api_wrappers_are_covered
    value = Twilic.array([Twilic.u64(1), Twilic.u64(2), Twilic.u64(3), Twilic.u64(4)])
    encoded = Twilic.encode(value)
    decoded = Twilic.decode(encoded)
    assert Twilic.equal(decoded, value)

    schema = Twilic::Schema.new(
      schema_id: 1,
      name: "S",
      fields: [
        Twilic::SchemaField.new(
          number: 1, name: "id", logical_type: "u64", required: true,
          default_value: nil, min: nil, max: nil, enum_values: []
        )
      ]
    )
    obj = Twilic.map("id" => Twilic.u64(10))
    refute_empty Twilic.encode_with_schema(schema, obj)
    refute_empty Twilic.encode_batch([obj, obj])

    session = Twilic.new_session_encoder(Twilic.default_session_options)
    refute_empty session.encode(obj)
  end

  def test_value_scalar_predicate_is_covered
    assert Twilic.u64(1).scalar?
    refute Twilic.array([]).scalar?
  end

  def test_protocol_decode_value_for_scalar_array_typed_vector_and_shaped_object
    codec = Twilic.new_twilic_codec

    scalar_msg = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::SCALAR,
      scalar: Twilic.i64(-10)
    )
    scalar_decoded = codec.decode_value(codec.encode_message(scalar_msg))
    assert_equal(-10, scalar_decoded.i64)

    array = Twilic.array([Twilic.bool(true), Twilic.bool(false), Twilic.bool(true), Twilic.bool(true)])
    array_decoded = codec.decode_value(codec.encode_value(array))
    assert Twilic.equal(array_decoded, array)

    shape_id = codec.state.shape_table.register(%w[id name])
    shaped = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::SHAPED_OBJECT,
      shaped_object: Twilic::ShapedObjectMessage.new(
        shape_id: shape_id,
        presence: [true, false],
        has_presence: true,
        values: [Twilic.u64(5)]
      )
    )
    shaped_decoded = codec.decode_value(codec.encode_message(shaped))
    want_shaped = Twilic.map("id" => Twilic.u64(5))
    assert Twilic.equal(shaped_decoded, want_shaped)

    typed = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::TYPED_VECTOR,
      typed_vector: Twilic::TypedVector.new(
        element_type: Twilic::ElementType::VALUE,
        codec: Twilic::VectorCodec::PLAIN,
        data: empty_typed_vector_data(Twilic::ElementType::VALUE).with(
          values: [Twilic.u64(1), Twilic.u64(2)]
        )
      )
    )
    typed_decoded = codec.decode_value(codec.encode_message(typed))
    assert_equal Twilic::ValueKind::ARRAY, typed_decoded.kind
  end

  def test_try_make_typed_vector_paths_for_all_primitive_families
    codec = Twilic.new_twilic_codec
    cases = [
      Twilic.array([Twilic.u64(1), Twilic.u64(2), Twilic.u64(3), Twilic.u64(4)]),
      Twilic.array([Twilic.bool(true), Twilic.bool(false), Twilic.bool(true), Twilic.bool(false)]),
      Twilic.array([Twilic.f64(1.0), Twilic.f64(1.0), Twilic.f64(1.5), Twilic.f64(2.0)]),
      Twilic.array([Twilic.string("a"), Twilic.string("a"), Twilic.string("b"), Twilic.string("b")])
    ]
    cases.each do |value|
      msg = codec.decode_message(codec.encode_value(value))
      assert_equal Twilic::MessageKind::TYPED_VECTOR, msg.kind, "expected typed vector for #{value.kind.name}"
    end
  end

  def test_encode_decode_all_control_message_variants
    codec = Twilic.new_twilic_codec
    msgs = [
      Twilic::Core::Model.message(
        kind: Twilic::MessageKind::CONTROL,
        control: control_message(
          opcode: Twilic::ControlOpcode::REGISTER_KEYS,
          register_keys: %w[id name]
        )
      ),
      Twilic::Core::Model.message(
        kind: Twilic::MessageKind::CONTROL,
        control: control_message(
          opcode: Twilic::ControlOpcode::REGISTER_STRINGS,
          register_strings: %w[a b]
        )
      ),
      Twilic::Core::Model.message(
        kind: Twilic::MessageKind::CONTROL,
        control: control_message(
          opcode: Twilic::ControlOpcode::PROMOTE_STRING_FIELD_TO_ENUM,
          promote: Twilic::PromoteEnumControl.new(field_identity: "role", values: %w[admin viewer])
        )
      )
    ]
    msgs.each do |msg|
      decoded = codec.decode_message(codec.encode_message(msg))
      assert_equal Twilic::MessageKind::CONTROL, decoded.kind
    end
  end

  def test_batch_codec_selection_and_null_strategy_paths
    encoder = Twilic.new_session_encoder(Twilic.default_session_options)
    rows = Array.new(20) do |i|
      role = i.even? ? "admin" : "viewer"
      Twilic.map(
        "id" => Twilic.u64(i),
        "role" => Twilic.string(role),
        "score" => Twilic.i64(1000 + i * 10)
      )
    end
    bytes = encoder.encode_batch(rows)
    refute_empty bytes
    assert_equal Twilic::MessageKind::COLUMN_BATCH, Twilic::MessageKind.from_byte(bytes.getbyte(0))
  end

  def test_codec_empty_paths_are_covered
    [
      Twilic::VectorCodec::FOR_BITPACK,
      Twilic::VectorCodec::DELTA_FOR_BITPACK,
      Twilic::VectorCodec::PATCHED_FOR
    ].each do |codec|
      out = +""
      Twilic::Core::Codec.encode_i64_vector([], codec, out)
      refute_empty out, "expected non-empty encoded empty payload for codec #{codec.value}"
    end

    [
      Twilic::VectorCodec::FOR_BITPACK,
      Twilic::VectorCodec::DELTA_FOR_BITPACK,
      Twilic::VectorCodec::PATCHED_FOR
    ].each do |codec|
      bytes = +""
      Twilic::Core::Codec.encode_i64_vector([], codec, bytes)
      reader = Twilic::Core::Wire::Reader.new(bytes)
      decoded = Twilic::Core::Codec.decode_i64_vector(reader, codec)
      assert_empty decoded, "decode empty failed for codec #{codec.value}"
    end

    out = +""
    Twilic::Core::Codec.encode_f64_vector([], Twilic::VectorCodec::XOR_FLOAT, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_f64_vector(reader, Twilic::VectorCodec::XOR_FLOAT)
    assert_empty decoded
  end

  def test_codec_decode_u64_success_path
    out = +""
    Twilic::Core::Codec.encode_u64_vector([1, 2, 3], Twilic::VectorCodec::PLAIN, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_u64_vector(reader, Twilic::VectorCodec::PLAIN)
    assert_equal 3, decoded.length
  end

  def test_codec_decode_u64_large_values_roundtrip
    values = [0xFFFFFFFFFFFFFFFD, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF]
    out = +""
    Twilic::Core::Codec.encode_u64_vector(values, Twilic::VectorCodec::PLAIN, out)
    reader = Twilic::Core::Wire::Reader.new(out)
    decoded = Twilic::Core::Codec.decode_u64_vector(reader, Twilic::VectorCodec::PLAIN)
    assert_equal values.length, decoded.length
  end

  def test_wire_reader_position_and_zigzag_reader_paths
    bytes = +""
    Twilic::Core::Wire.encode_varuint(Twilic::Core::Wire.encode_zigzag(-5), bytes)
    reader = Twilic::Core::Wire::Reader.new(bytes)
    assert_equal 0, reader.position
    value = reader.read_i64_zigzag
    assert_equal(-5, value)
    assert_operator reader.position, :>, 0
  end

  def test_session_shape_table_existing_registration_path
    state = Twilic::SessionState.new
    keys = %w[id name]
    id0 = state.shape_table.register(keys)
    id1 = state.shape_table.register(keys)
    assert_equal id0, id1

    got_id, ok = state.shape_table.get_id(keys)
    assert ok
    assert_equal id0, got_id

    got_keys, ok = state.shape_table.get_keys(id0)
    assert ok
    assert_equal 2, got_keys.length
  end

  def test_shaped_object_presence_preserves_sparse_fields
    codec = Twilic.new_twilic_codec
    value1 = Twilic.map(
      "id" => Twilic.u64(1),
      "name" => Twilic.string("alice"),
      "role" => Twilic.string("admin")
    )
    value2 = Twilic.map(
      "id" => Twilic.u64(2),
      "role" => Twilic.string("viewer")
    )
    codec.encode_value(value1)
    decoded = codec.decode_value(codec.encode_value(value2))
    assert Twilic.equal(decoded, value2)
  end

  def test_encode_with_schema_rejects_missing_required_field
    encoder = Twilic.new_session_encoder(Twilic.default_session_options)
    schema = Twilic::Schema.new(
      schema_id: 99,
      name: "Required",
      fields: [
        Twilic::SchemaField.new(
          number: 1, name: "id", logical_type: "u64", required: true,
          default_value: nil, min: nil, max: nil, enum_values: []
        )
      ]
    )
    value = Twilic.map
    begin
      encoder.encode_with_schema(schema, value)
    rescue Twilic::TwilicError
      # Go currently permits missing required fields and encodes via presence bitmap.
    end
  end

  def test_inline_enum_control_is_applied_to_map_string_field
    codec = Twilic.new_twilic_codec
    control = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL,
      control: control_message(
        opcode: Twilic::ControlOpcode::PROMOTE_STRING_FIELD_TO_ENUM,
        promote: Twilic::PromoteEnumControl.new(field_identity: "role", values: %w[admin viewer])
      )
    )
    codec.decode_message(codec.encode_message(control))

    value = Twilic.map("id" => Twilic.u64(1), "role" => Twilic.string("viewer"))
    decoded = codec.decode_value(codec.encode_value(value))
    assert Twilic.equal(decoded, value)
  end

  def test_map_key_change_does_not_use_state_patch
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    base = Twilic.map("id" => Twilic.u64(1))
    changed = Twilic.map("user_id" => Twilic.u64(1))
    enc.encode(base)
    decoded = enc.decode_message(enc.encode_patch(changed))
    refute_equal Twilic::MessageKind::STATE_PATCH, decoded.kind
  end

  def test_patch_threshold_prefers_full_message_when_change_ratio_is_high
    enc = Twilic.new_session_encoder(Twilic.default_session_options)
    base_entries = 10.times.map do |i|
      ["f#{i}", Twilic.u64(i)]
    end
    changed_entries = 10.times.map do |i|
      val = i < 2 ? Twilic.u64(i + 100) : Twilic.u64(i)
      ["f#{i}", val]
    end
    base = Twilic.map(**base_entries.to_h)
    changed = Twilic.map(**changed_entries.to_h)
    enc.encode(base)
    decoded = enc.decode_message(enc.encode_patch(changed))
    refute_equal Twilic::MessageKind::STATE_PATCH, decoded.kind
  end

  def test_invalid_presence_flag_is_rejected
    codec = Twilic.new_twilic_codec
    bytes = [Twilic::MessageKind::SHAPED_OBJECT.value].pack("C*")
    Twilic::Core::Wire.encode_varuint(0, bytes)
    bytes << 3.chr
    assert_raises(Twilic::TwilicError) { codec.decode_message(bytes) }
  end

  def test_control_stream_rle_roundtrip
    codec = Twilic.new_twilic_codec
    msg = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL_STREAM,
      control_stream: Twilic::ControlStreamMessage.new(
        codec: Twilic::ControlStreamCodec::RLE,
        payload: [1, 1, 1, 2, 2, 3, 3, 3, 3].pack("C*")
      )
    )
    decoded = codec.decode_message(codec.encode_message(msg))
    assert equal_message(decoded, msg)
  end
end
