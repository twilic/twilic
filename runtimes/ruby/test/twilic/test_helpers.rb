# frozen_string_literal: true

module TwilicTestHelpers
  TAG_STRING = 6

  def require_twilic_error_kind(err, kind)
    assert_instance_of Twilic::TwilicError, err, "expected TwilicError, got #{err.inspect}"
    assert_equal kind, err.kind, "expected error kind #{kind}, got #{err.kind}"
    err
  end

  def equal_key_ref(a, b)
    a.is_id == b.is_id && a.id == b.id && a.literal == b.literal
  end

  def equal_message(a, b)
    return false unless a.kind == b.kind

    case a.kind
    when Twilic::MessageKind::SCALAR
      Twilic.equal(a.scalar, b.scalar)
    when Twilic::MessageKind::ARRAY
      return false unless a.array.length == b.array.length

      a.array.each_with_index.all? { |v, i| Twilic.equal(v, b.array[i]) }
    when Twilic::MessageKind::MAP
      return false unless a.map.length == b.map.length

      a.map.each_with_index.all? do |entry, i|
        equal_key_ref(entry.key, b.map[i].key) && Twilic.equal(entry.value, b.map[i].value)
      end
    when Twilic::MessageKind::CONTROL_STREAM
      a.control_stream.codec == b.control_stream.codec &&
        a.control_stream.payload == b.control_stream.payload
    else
      a.clone_message == b.clone_message
    end
  end

  def message_map_entry(key, value)
    Twilic::MessageMapEntry.new(key: Twilic::KeyRef.literal(key), value: value)
  end

  def scalar_string_mode(bytes)
    assert_operator bytes.bytesize, :>=, 3, "expected at least 3 bytes, got #{bytes.bytesize}"
    assert_equal Twilic::MessageKind::SCALAR.value, bytes.getbyte(0), "expected scalar kind byte"
    assert_equal TAG_STRING, bytes.getbyte(1), "expected string tag byte"
    bytes.getbyte(2)
  end

  def sample_schema
    Twilic::Schema.new(
      schema_id: 41,
      name: "User",
      fields: [
        Twilic::SchemaField.new(
          number: 1, name: "id", logical_type: "u64", required: true,
          default_value: nil, min: 1000, max: 1100, enum_values: []
        ),
        Twilic::SchemaField.new(
          number: 2, name: "name", logical_type: "string", required: true,
          default_value: nil, min: nil, max: nil, enum_values: []
        ),
        Twilic::SchemaField.new(
          number: 3, name: "score", logical_type: "i64", required: false,
          default_value: nil, min: 0, max: 100, enum_values: []
        )
      ]
    )
  end

  def control_message(opcode:, register_keys: [], register_shape: nil, register_strings: [],
                      promote: nil, reset_tables: false, reset_state: false)
    Twilic::ControlMessage.new(
      register_keys: register_keys,
      register_shape: register_shape,
      register_strings: register_strings,
      promote_string_field_to_enum: promote,
      reset_tables: reset_tables,
      reset_state: reset_state,
      opcode: opcode
    )
  end

  def encoded_control_stream_len(codec_enum, payload)
    codec = Twilic.new_twilic_codec
    msg = Twilic::Core::Model.message(
      kind: Twilic::MessageKind::CONTROL_STREAM,
      control_stream: Twilic::ControlStreamMessage.new(codec: codec_enum, payload: payload.b)
    )
    bytes = codec.encode_message(msg)
    bytes.bytesize
  end

  def empty_typed_vector_data(kind)
    Twilic::TypedVectorData.new(
      bools: [], i64s: [], u64s: [], f64s: [], strings: [], binary: [], values: [], kind: kind
    )
  end
end
