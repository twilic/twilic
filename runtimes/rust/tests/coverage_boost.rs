use twilic as twilic_rust;

use twilic_rust::{
    SessionEncoder, TwilicCodec, TwilicError,
    codec::{
        decode_f64_vector, decode_i64_vector, decode_u64_vector, encode_f64_vector,
        encode_i64_vector, encode_u64_vector,
    },
    model::{
        BaseRef, ControlMessage, ControlOpcode, ControlStreamCodec, ElementType, Message,
        MessageKind, PatchOpcode, StringMode, Value, VectorCodec,
    },
    session::{SessionOptions, UnknownReferencePolicy},
    wire::{Reader, encode_bitmap, encode_string, encode_varuint, encode_zigzag},
};

#[test]
fn model_from_byte_and_display_branches() {
    assert!(MessageKind::from_byte(0x0D).is_some());
    assert!(MessageKind::from_byte(0xFE).is_none());
    assert!(StringMode::from_byte(4).is_some());
    assert!(StringMode::from_byte(9).is_none());
    assert!(ElementType::from_byte(6).is_some());
    assert!(ElementType::from_byte(9).is_none());
    assert!(VectorCodec::from_byte(12).is_some());
    assert!(VectorCodec::from_byte(99).is_none());
    assert!(ControlOpcode::from_byte(5).is_some());
    assert!(ControlOpcode::from_byte(7).is_none());
    assert!(PatchOpcode::from_byte(8).is_some());
    assert!(PatchOpcode::from_byte(42).is_none());
    assert!(ControlStreamCodec::from_byte(4).is_some());
    assert!(ControlStreamCodec::from_byte(7).is_none());

    let errors = [
        TwilicError::UnexpectedEof,
        TwilicError::InvalidKind(0xFF),
        TwilicError::InvalidTag(0xFF),
        TwilicError::InvalidData("bad"),
        TwilicError::Utf8Error,
        TwilicError::UnknownReference("base_id", 3),
        TwilicError::StatelessRetryRequired("base_id", 3),
    ];
    for err in errors {
        assert!(!err.to_string().is_empty());
    }
}

#[test]
fn wire_reader_error_branches() {
    let mut r = Reader::new(&[]);
    assert!(matches!(r.read_u8(), Err(TwilicError::UnexpectedEof)));

    let too_long = vec![0x80; 11];
    let mut r = Reader::new(&too_long);
    assert!(matches!(
        r.read_varuint(),
        Err(TwilicError::InvalidData("varuint too large"))
    ));

    let invalid_utf8 = vec![1, 0xFF];
    let mut r = Reader::new(&invalid_utf8);
    assert!(matches!(r.read_string(), Err(TwilicError::Utf8Error)));

    let mut bytes = Vec::new();
    encode_varuint(9, &mut bytes);
    bytes.push(0b0101_0101);
    bytes.push(0b0000_0001);
    let mut r = Reader::new(&bytes);
    let bits = r.read_bitmap().expect("bitmap decode");
    assert_eq!(bits.len(), 9);
    assert!(bits[0]);
    assert!(bits[8]);
}

#[test]
fn codec_variants_roundtrip_and_error_path() {
    let values = vec![100, 110, 120, 130, 130, 130, 140, 150, 160, 170];
    let codecs = [
        VectorCodec::Plain,
        VectorCodec::DirectBitpack,
        VectorCodec::DeltaBitpack,
        VectorCodec::ForBitpack,
        VectorCodec::DeltaForBitpack,
        VectorCodec::DeltaDeltaBitpack,
        VectorCodec::Rle,
        VectorCodec::PatchedFor,
        VectorCodec::Simple8b,
    ];
    for codec in codecs {
        let mut out = Vec::new();
        encode_i64_vector(&values, codec, &mut out);
        let mut reader = Reader::new(&out);
        let decoded = decode_i64_vector(&mut reader, codec).expect("decode i64 vector");
        assert_eq!(decoded, values, "codec={codec:?}");
    }

    let f_values = vec![1.0_f64, 1.0, 1.5, 1.75, 1.875];
    for codec in [VectorCodec::XorFloat, VectorCodec::Plain] {
        let mut out = Vec::new();
        encode_f64_vector(&f_values, codec, &mut out);
        let mut reader = Reader::new(&out);
        let decoded = decode_f64_vector(&mut reader, codec).expect("decode f64 vector");
        assert_eq!(decoded, f_values);
    }

    let mut out = Vec::new();
    encode_u64_vector(&[10, 20, 30, 40], VectorCodec::DeltaBitpack, &mut out);
    let mut reader = Reader::new(&out);
    let decoded = decode_u64_vector(&mut reader, VectorCodec::DeltaBitpack)
        .expect("decode u64 vector with fallback codec");
    assert_eq!(decoded, vec![10, 20, 30, 40]);
}

#[test]
fn protocol_error_and_control_branches() {
    let mut codec = TwilicCodec::default();

    let bytes = codec
        .encode_message(&Message::Control(ControlMessage::ResetTables))
        .expect("encode reset tables");
    let decoded = codec.decode_message(&bytes).expect("decode reset tables");
    assert!(matches!(
        decoded,
        Message::Control(ControlMessage::ResetTables)
    ));

    let bytes = codec
        .encode_message(&Message::Control(ControlMessage::ResetState))
        .expect("encode reset state");
    let decoded = codec.decode_message(&bytes).expect("decode reset state");
    assert!(matches!(
        decoded,
        Message::Control(ControlMessage::ResetState)
    ));

    let mut malformed = Vec::new();
    malformed.push(MessageKind::SchemaObject as u8);
    malformed.push(0);
    malformed.push(0);
    encode_varuint(1, &mut malformed);
    malformed.push(0);
    malformed.push(3);
    malformed.push(1);
    malformed.push(2);
    malformed.push(0x00);
    malformed.push(0x00);
    assert!(matches!(
        codec.decode_message(&malformed),
        Err(TwilicError::InvalidData("trailing bytes in message"))
    ));

    let mut bad_schema_flag = Vec::new();
    bad_schema_flag.push(MessageKind::SchemaObject as u8);
    bad_schema_flag.push(2);
    assert!(matches!(
        codec.decode_message(&bad_schema_flag),
        Err(TwilicError::InvalidData("schema flag"))
    ));

    let mut map_with_unknown_key_id = Vec::new();
    map_with_unknown_key_id.push(MessageKind::Map as u8);
    encode_varuint(1, &mut map_with_unknown_key_id);
    map_with_unknown_key_id.push(1);
    encode_varuint(77, &mut map_with_unknown_key_id);
    map_with_unknown_key_id.push(4);
    map_with_unknown_key_id.push(1);
    map_with_unknown_key_id.push(1);
    assert!(matches!(
        codec.decode_value(&map_with_unknown_key_id),
        Err(TwilicError::UnknownReference("key_id", 77))
    ));

    let mut pd_unknown = Vec::new();
    pd_unknown.push(MessageKind::Scalar as u8);
    pd_unknown.push(6);
    pd_unknown.push(StringMode::PrefixDelta as u8);
    encode_varuint(99, &mut pd_unknown);
    encode_varuint(2, &mut pd_unknown);
    encode_string("x", &mut pd_unknown);
    assert!(matches!(
        codec.decode_value(&pd_unknown),
        Err(TwilicError::UnknownReference("string_id", 99))
    ));

    let mut register_shape = Vec::new();
    register_shape.push(MessageKind::Control as u8);
    register_shape.push(ControlOpcode::RegisterShape as u8);
    encode_varuint(42, &mut register_shape);
    encode_varuint(1, &mut register_shape);
    register_shape.push(0);
    encode_string("id", &mut register_shape);
    let decoded = codec
        .decode_message(&register_shape)
        .expect("decode register shape");
    assert!(matches!(
        decoded,
        Message::Control(ControlMessage::RegisterShape { shape_id: 42, .. })
    ));

    let mut bad_column_codec = Vec::new();
    bad_column_codec.push(MessageKind::ColumnBatch as u8);
    encode_varuint(1, &mut bad_column_codec);
    encode_varuint(1, &mut bad_column_codec);
    encode_varuint(0, &mut bad_column_codec);
    bad_column_codec.push(0);
    bad_column_codec.push(VectorCodec::Plain as u8);
    bad_column_codec.push(0);
    bad_column_codec.push(0);
    bad_column_codec.push(ElementType::I64 as u8);
    bad_column_codec.push(VectorCodec::DirectBitpack as u8);
    encode_varuint(1, &mut bad_column_codec);
    bad_column_codec.push(2);
    bad_column_codec.push(2);
    assert!(matches!(
        codec.decode_message(&bad_column_codec),
        Err(TwilicError::InvalidData("column codec mismatch"))
    ));
}

#[test]
fn dynamic_shape_promotion_after_second_same_map_shape() {
    let mut codec = TwilicCodec::default();
    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1)),
        ("name".to_string(), Value::String("alice".to_string())),
        ("role".to_string(), Value::String("admin".to_string())),
    ]);
    let first = codec.encode_value(&value).expect("encode first");
    let first_msg = codec.decode_message(&first).expect("decode first");
    assert!(matches!(first_msg, Message::Map(_)));

    let second = codec.encode_value(&value).expect("encode second");
    let second_msg = codec.decode_message(&second).expect("decode second");
    assert!(matches!(second_msg, Message::ShapedObject { .. }));

    let third = codec.encode_value(&value).expect("encode third");
    let third_msg = codec.decode_message(&third).expect("decode third");
    assert!(matches!(third_msg, Message::ShapedObject { .. }));
}

#[test]
fn schema_id_is_emitted_then_omitted_in_schema_context() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let schema = twilic_rust::model::Schema {
        schema_id: 777,
        name: "SchemaCtx".to_string(),
        fields: vec![
            twilic_rust::model::SchemaField {
                number: 1,
                name: "id".to_string(),
                logical_type: "u64".to_string(),
                required: true,
                default_value: None,
                min: None,
                max: None,
                enum_values: vec![],
            },
            twilic_rust::model::SchemaField {
                number: 2,
                name: "name".to_string(),
                logical_type: "string".to_string(),
                required: true,
                default_value: None,
                min: None,
                max: None,
                enum_values: vec![],
            },
        ],
    };
    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1)),
        ("name".to_string(), Value::String("alice".to_string())),
    ]);

    let first = enc
        .encode_with_schema(&schema, &value)
        .expect("encode with schema first");
    let first_msg = enc.decode_message(&first).expect("decode first schema msg");
    assert!(matches!(
        first_msg,
        Message::SchemaObject {
            schema_id: Some(777),
            ..
        }
    ));

    let second = enc
        .encode_with_schema(&schema, &value)
        .expect("encode with schema second");
    let second_msg = enc
        .decode_message(&second)
        .expect("decode second schema msg");
    assert!(matches!(
        second_msg,
        Message::SchemaObject {
            schema_id: None,
            ..
        }
    ));
}

#[test]
fn schema_mode_uses_registered_schema_and_range_packing() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let schema = twilic_rust::model::Schema {
        schema_id: 7,
        name: "Bound".to_string(),
        fields: vec![
            twilic_rust::model::SchemaField {
                number: 1,
                name: "id".to_string(),
                logical_type: "u64".to_string(),
                required: true,
                default_value: None,
                min: Some(1000),
                max: Some(1100),
                enum_values: vec![],
            },
            twilic_rust::model::SchemaField {
                number: 2,
                name: "name".to_string(),
                logical_type: "string".to_string(),
                required: true,
                default_value: None,
                min: None,
                max: None,
                enum_values: vec![],
            },
        ],
    };
    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1005)),
        ("name".to_string(), Value::String("alice".to_string())),
    ]);

    let bytes = enc
        .encode_with_schema(&schema, &value)
        .expect("encode with schema");
    let decoded = enc.decode_message(&bytes).expect("decode with schema");
    match decoded {
        Message::SchemaObject { fields, .. } => {
            assert_eq!(fields.len(), 2);
            assert_eq!(fields[0], Value::U64(1005));
            assert_eq!(fields[1], Value::String("alice".to_string()));
        }
        other => panic!("expected schema object, got {other:?}"),
    }
}

#[test]
fn schema_aliases_and_enums_use_compact_encodings() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let schema = twilic_rust::model::Schema {
        schema_id: 9,
        name: "UserRecord".to_string(),
        fields: vec![
            twilic_rust::model::SchemaField {
                number: 1,
                name: "id".to_string(),
                logical_type: "u32".to_string(),
                required: true,
                default_value: None,
                min: Some(1),
                max: Some(10_000_000),
                enum_values: vec![],
            },
            twilic_rust::model::SchemaField {
                number: 2,
                name: "role".to_string(),
                logical_type: "string".to_string(),
                required: true,
                default_value: None,
                min: None,
                max: None,
                enum_values: vec![
                    "viewer".to_string(),
                    "editor".to_string(),
                    "admin".to_string(),
                ],
            },
            twilic_rust::model::SchemaField {
                number: 3,
                name: "age".to_string(),
                logical_type: "u8".to_string(),
                required: true,
                default_value: None,
                min: Some(0),
                max: Some(127),
                enum_values: vec![],
            },
        ],
    };
    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1_234)),
        ("role".to_string(), Value::String("admin".to_string())),
        ("age".to_string(), Value::U64(36)),
    ]);

    let bytes = enc
        .encode_with_schema(&schema, &value)
        .expect("encode compact schema value");
    assert_eq!(bytes.len(), 14, "expected compact bytes, got {bytes:?}");

    let decoded = enc
        .decode_message(&bytes)
        .expect("decode compact schema value");
    let Message::SchemaObject { fields, .. } = decoded else {
        panic!("expected schema object");
    };
    assert_eq!(
        fields,
        vec![
            Value::U64(1_234),
            Value::String("admin".to_string()),
            Value::U64(36)
        ]
    );
}

#[test]
fn schema_range_mode_writes_fixed_width_offset_bits() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let schema = twilic_rust::model::Schema {
        schema_id: 8,
        name: "RangeOnly".to_string(),
        fields: vec![twilic_rust::model::SchemaField {
            number: 1,
            name: "n".to_string(),
            logical_type: "u64".to_string(),
            required: true,
            default_value: None,
            min: Some(0),
            max: Some((1 << 20) - 1),
            enum_values: vec![],
        }],
    };
    let value = Value::Map(vec![("n".to_string(), Value::U64(1))]);

    let bytes = enc
        .encode_with_schema(&schema, &value)
        .expect("encode with schema");

    let mut reader = Reader::new(&bytes);
    assert_eq!(
        reader.read_u8().expect("kind"),
        MessageKind::SchemaObject as u8
    );
    assert_eq!(reader.read_u8().expect("has schema"), 1);
    assert_eq!(reader.read_varuint().expect("schema id"), 8);
    assert_eq!(reader.read_u8().expect("presence"), 0);
    assert_eq!(reader.read_varuint().expect("field count"), 1);
    assert_eq!(reader.read_u8().expect("encoding mode"), 1);
    assert_eq!(reader.read_u8().expect("range mode"), 1);
    let offset_bytes = reader.read_exact(3).expect("20-bit offset bytes");
    assert_eq!(offset_bytes, &[1, 0, 0]);
    assert!(reader.is_eof());

    let decoded = enc.decode_message(&bytes).expect("decode schema message");
    let Message::SchemaObject { fields, .. } = decoded else {
        panic!("expected schema object")
    };
    assert_eq!(fields, vec![Value::U64(1)]);
}

#[test]
fn typed_vector_length_mismatch_is_rejected() {
    let mut codec = TwilicCodec::default();
    let mut bytes = Vec::new();
    bytes.push(MessageKind::TypedVector as u8);
    bytes.push(ElementType::U64 as u8);
    encode_varuint(2, &mut bytes);
    bytes.push(VectorCodec::Plain as u8);
    encode_varuint(1, &mut bytes);
    encode_varuint(99, &mut bytes);
    assert!(matches!(
        codec.decode_message(&bytes),
        Err(TwilicError::InvalidData("typed vector length mismatch"))
    ));
}

#[test]
fn micro_batch_falls_back_when_shape_is_not_uniform() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let values = vec![
        Value::Map(vec![("id".to_string(), Value::U64(1))]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(2)),
            ("x".to_string(), Value::U64(10)),
        ]),
        Value::Map(vec![("id".to_string(), Value::U64(3))]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(4)),
            ("x".to_string(), Value::U64(20)),
        ]),
    ];
    let bytes = enc
        .encode_micro_batch(&values)
        .expect("encode micro fallback");
    let decoded = enc.decode_message(&bytes).expect("decode micro fallback");
    assert!(matches!(decoded, Message::RowBatch { .. }));
}

#[test]
fn unknown_reference_stateless_retry_paths() {
    let options = SessionOptions {
        unknown_reference_policy: UnknownReferencePolicy::StatelessRetry,
        ..SessionOptions::default()
    };
    let mut codec = TwilicCodec::with_options(options);

    let mut previous_missing = Vec::new();
    previous_missing.push(MessageKind::StatePatch as u8);
    previous_missing.push(0);
    encode_varuint(0, &mut previous_missing);
    encode_varuint(0, &mut previous_missing);
    assert!(matches!(
        codec.decode_message(&previous_missing),
        Err(TwilicError::StatelessRetryRequired("previous_message", 0))
    ));

    let mut base_missing = Vec::new();
    base_missing.push(MessageKind::StatePatch as u8);
    base_missing.push(1);
    encode_varuint(1000, &mut base_missing);
    encode_varuint(0, &mut base_missing);
    encode_varuint(0, &mut base_missing);
    assert!(matches!(
        codec.decode_message(&base_missing),
        Err(TwilicError::StatelessRetryRequired("base_id", 1000))
    ));

    let mut builder = TwilicCodec::default();
    let dict_ref_column = Message::ColumnBatch {
        count: 1,
        columns: vec![twilic_rust::model::Column {
            field_id: 0,
            null_strategy: twilic_rust::model::NullStrategy::AllPresentElided,
            presence: None,
            codec: VectorCodec::Dictionary,
            dictionary_id: Some(77),
            values: twilic_rust::model::TypedVectorData::String(vec!["admin".to_string()]),
        }],
    };
    let dict_ref_bytes = builder
        .encode_message(&dict_ref_column)
        .expect("encode dict-ref column batch");
    assert!(matches!(
        codec.decode_message(&dict_ref_bytes),
        Err(TwilicError::StatelessRetryRequired("dict_id", 77))
    ));
}

#[test]
fn unknown_dict_reference_fail_fast_path() {
    let mut encoder = TwilicCodec::default();
    let msg = Message::ColumnBatch {
        count: 1,
        columns: vec![twilic_rust::model::Column {
            field_id: 0,
            null_strategy: twilic_rust::model::NullStrategy::AllPresentElided,
            presence: None,
            codec: VectorCodec::Dictionary,
            dictionary_id: Some(88),
            values: twilic_rust::model::TypedVectorData::String(vec!["x".to_string()]),
        }],
    };
    let bytes = encoder.encode_message(&msg).expect("encode column batch");

    let mut decoder = TwilicCodec::default();
    assert!(matches!(
        decoder.decode_message(&bytes),
        Err(TwilicError::UnknownReference("dict_id", 88))
    ));
}

#[test]
fn register_and_use_base_snapshot_reference() {
    let mut codec = TwilicCodec::default();
    let snapshot = Message::BaseSnapshot {
        base_id: 9,
        schema_or_shape_ref: 0,
        payload: Box::new(Message::Scalar(twilic_rust::Value::U64(10))),
    };
    let bytes = codec.encode_message(&snapshot).expect("encode snapshot");
    let decoded = codec.decode_message(&bytes).expect("decode snapshot");
    assert!(matches!(decoded, Message::BaseSnapshot { .. }));

    let patch = Message::StatePatch {
        base_ref: BaseRef::BaseId(9),
        operations: vec![],
        literals: vec![],
    };
    let patch_bytes = codec.encode_message(&patch).expect("encode patch");
    let decoded_patch = codec.decode_message(&patch_bytes).expect("decode patch");
    assert!(matches!(
        decoded_patch,
        Message::StatePatch {
            base_ref: BaseRef::BaseId(9),
            ..
        }
    ));
}

#[test]
fn decode_value_rejects_non_value_message_kinds() {
    let mut codec = TwilicCodec::default();
    let mut bytes = Vec::new();
    bytes.push(MessageKind::Control as u8);
    bytes.push(ControlOpcode::ResetTables as u8);
    assert!(matches!(
        codec.decode_value(&bytes),
        Err(TwilicError::InvalidData(
            "decode_value expects scalar/array/map/vector message"
        ))
    ));
}

#[test]
fn wire_encode_bitmap_roundtrip_with_full_byte_boundary() {
    let bits = vec![true, false, true, false, true, false, true, false];
    let mut bytes = Vec::new();
    encode_bitmap(&bits, &mut bytes);
    let mut reader = Reader::new(&bytes);
    let decoded = reader.read_bitmap().expect("decode bitmap");
    assert_eq!(decoded, bits);
}

#[test]
fn public_api_wrappers_are_covered() {
    let value = Value::Array(vec![
        Value::U64(1),
        Value::U64(2),
        Value::U64(3),
        Value::U64(4),
    ]);
    let encoded = twilic_rust::encode(&value).expect("encode wrapper");
    let decoded = twilic_rust::decode(&encoded).expect("decode wrapper");
    assert_eq!(decoded, value);

    let schema = twilic_rust::model::Schema {
        schema_id: 1,
        name: "S".to_string(),
        fields: vec![twilic_rust::model::SchemaField {
            number: 1,
            name: "id".to_string(),
            logical_type: "u64".to_string(),
            required: true,
            default_value: None,
            min: None,
            max: None,
            enum_values: vec![],
        }],
    };
    let obj = Value::Map(vec![("id".to_string(), Value::U64(10))]);
    let schema_bytes = twilic_rust::encode_with_schema(&schema, &obj).expect("schema wrapper");
    assert!(!schema_bytes.is_empty());

    let batch = twilic_rust::encode_batch(&[obj.clone(), obj.clone()]).expect("batch wrapper");
    assert!(!batch.is_empty());

    let mut session = twilic_rust::create_session_encoder(SessionOptions::default());
    let bytes = session.encode(&obj).expect("session encode");
    assert!(!bytes.is_empty());
}

#[test]
fn value_scalar_predicate_is_covered() {
    assert!(Value::U64(1).is_scalar());
    assert!(!Value::Array(vec![]).is_scalar());
}

#[test]
fn protocol_decode_value_for_scalar_array_typed_vector_and_shaped_object() {
    let mut codec = TwilicCodec::default();

    let scalar_bytes = codec
        .encode_message(&Message::Scalar(Value::I64(-10)))
        .expect("encode scalar");
    assert_eq!(
        codec.decode_value(&scalar_bytes).expect("decode scalar"),
        Value::I64(-10)
    );

    let array = Value::Array(vec![
        Value::Bool(true),
        Value::Bool(false),
        Value::Bool(true),
        Value::Bool(true),
    ]);
    let array_bytes = codec.encode_value(&array).expect("encode array");
    assert_eq!(
        codec.decode_value(&array_bytes).expect("decode array"),
        array
    );

    let shape_id = codec
        .state
        .shape_table
        .register(vec!["id".to_string(), "name".to_string()]);
    let shaped = Message::ShapedObject {
        shape_id,
        presence: Some(vec![true, false]),
        values: vec![Value::U64(5)],
    };
    let shaped_bytes = codec.encode_message(&shaped).expect("encode shaped");
    let decoded = codec.decode_value(&shaped_bytes).expect("decode shaped");
    assert_eq!(decoded, Value::Map(vec![("id".to_string(), Value::U64(5))]));

    let typed = Message::TypedVector(twilic_rust::model::TypedVector {
        element_type: ElementType::Value,
        codec: VectorCodec::Plain,
        data: twilic_rust::model::TypedVectorData::Value(vec![Value::U64(1), Value::U64(2)]),
    });
    let typed_bytes = codec.encode_message(&typed).expect("encode typed");
    assert_eq!(
        codec.decode_value(&typed_bytes).expect("decode typed"),
        Value::Array(vec![Value::U64(1), Value::U64(2)])
    );
}

#[test]
fn try_make_typed_vector_paths_for_all_primitive_families() {
    let mut codec = TwilicCodec::default();

    let u = Value::Array(vec![
        Value::U64(1),
        Value::U64(2),
        Value::U64(3),
        Value::U64(4),
    ]);
    let b = Value::Array(vec![
        Value::Bool(true),
        Value::Bool(false),
        Value::Bool(true),
        Value::Bool(false),
    ]);
    let f = Value::Array(vec![
        Value::F64(1.0),
        Value::F64(1.0),
        Value::F64(1.5),
        Value::F64(2.0),
    ]);
    let s = Value::Array(vec![
        Value::String("a".to_string()),
        Value::String("a".to_string()),
        Value::String("b".to_string()),
        Value::String("b".to_string()),
    ]);
    for v in [u, b, f, s] {
        let bytes = codec.encode_value(&v).expect("encode family");
        let msg = codec.decode_message(&bytes).expect("decode family message");
        assert!(matches!(msg, Message::TypedVector(_)));
    }
}

#[test]
fn encode_decode_all_control_message_variants() {
    let mut codec = TwilicCodec::default();
    let msgs = vec![
        Message::Control(ControlMessage::RegisterKeys(vec![
            "id".to_string(),
            "name".to_string(),
        ])),
        Message::Control(ControlMessage::RegisterStrings(vec![
            "a".to_string(),
            "b".to_string(),
        ])),
        Message::Control(ControlMessage::PromoteStringFieldToEnum {
            field_identity: "role".to_string(),
            values: vec!["admin".to_string(), "viewer".to_string()],
        }),
    ];
    for msg in msgs {
        let bytes = codec.encode_message(&msg).expect("encode control");
        let decoded = codec.decode_message(&bytes).expect("decode control");
        assert_eq!(decoded, msg);
    }

    let reg_shape = Message::Control(ControlMessage::RegisterShape {
        shape_id: 0,
        keys: vec![
            twilic_rust::model::KeyRef::Literal("id".to_string()),
            twilic_rust::model::KeyRef::Literal("name".to_string()),
        ],
    });
    let bytes = codec.encode_message(&reg_shape).expect("encode reg shape");
    let decoded = codec.decode_message(&bytes).expect("decode reg shape");
    assert_eq!(decoded, reg_shape);
}

#[test]
fn batch_codec_selection_and_null_strategy_paths() {
    let mut encoder = SessionEncoder::new(SessionOptions::default());

    let mut rows = Vec::new();
    for i in 0..20u64 {
        rows.push(Value::Map(vec![
            ("id".to_string(), Value::U64(i)),
            (
                "role".to_string(),
                Value::String(if i % 2 == 0 { "admin" } else { "viewer" }.to_string()),
            ),
            ("score".to_string(), Value::I64(1000 + i as i64 * 10)),
        ]));
    }
    let bytes = encoder.encode_batch(&rows).expect("encode column batch");
    let decoded = encoder.decode_message(&bytes).expect("decode column batch");
    assert!(matches!(decoded, Message::ColumnBatch { .. }));

    let mut sparse_rows = Vec::new();
    for i in 0..20u64 {
        if i % 3 == 0 {
            sparse_rows.push(Value::Map(vec![("id".to_string(), Value::U64(i))]));
        } else {
            sparse_rows.push(Value::Map(vec![
                ("id".to_string(), Value::U64(i)),
                ("extra".to_string(), Value::I64(i as i64)),
            ]));
        }
    }
    let bytes = encoder
        .encode_batch(&sparse_rows)
        .expect("encode sparse batch");
    let decoded = encoder.decode_message(&bytes).expect("decode sparse batch");
    assert!(matches!(decoded, Message::ColumnBatch { .. }));
}

#[test]
fn codec_empty_paths_are_covered() {
    for codec in [
        VectorCodec::ForBitpack,
        VectorCodec::DeltaForBitpack,
        VectorCodec::PatchedFor,
    ] {
        let mut out = Vec::new();
        encode_i64_vector(&[], codec, &mut out);
        assert!(!out.is_empty());
    }

    for codec in [
        VectorCodec::ForBitpack,
        VectorCodec::DeltaForBitpack,
        VectorCodec::PatchedFor,
    ] {
        let mut bytes = Vec::new();
        encode_i64_vector(&[], codec, &mut bytes);
        let mut reader = Reader::new(&bytes);
        let decoded = decode_i64_vector(&mut reader, codec).expect("decode empty");
        assert!(decoded.is_empty());
    }

    for codec in [
        VectorCodec::ForBitpack,
        VectorCodec::DeltaForBitpack,
        VectorCodec::PatchedFor,
    ] {
        let mut out = Vec::new();
        encode_i64_vector(&[1, 2], codec, &mut out);
        let mut reader = Reader::new(&out);
        let decoded = decode_i64_vector(&mut reader, codec).expect("decode non-empty");
        assert_eq!(decoded, vec![1, 2]);
    }

    let mut out = Vec::new();
    encode_f64_vector(&[], VectorCodec::XorFloat, &mut out);
    let mut reader = Reader::new(&out);
    let decoded =
        decode_f64_vector(&mut reader, VectorCodec::XorFloat).expect("decode empty float");
    assert!(decoded.is_empty());
}

#[test]
fn codec_decode_u64_success_path() {
    let mut out = Vec::new();
    encode_u64_vector(&[1, 2, 3], VectorCodec::Plain, &mut out);
    let mut reader = Reader::new(&out);
    let decoded = decode_u64_vector(&mut reader, VectorCodec::Plain).expect("decode u64");
    assert_eq!(decoded, vec![1, 2, 3]);
}

#[test]
fn codec_decode_u64_large_values_roundtrip() {
    let values = vec![u64::MAX - 2, u64::MAX - 1, u64::MAX];
    let mut out = Vec::new();
    encode_u64_vector(&values, VectorCodec::Plain, &mut out);
    let mut reader = Reader::new(&out);
    let decoded = decode_u64_vector(&mut reader, VectorCodec::Plain).expect("decode large u64");
    assert_eq!(decoded, values);
}

#[test]
fn wire_reader_position_and_zigzag_reader_paths() {
    let mut bytes = Vec::new();
    encode_varuint(encode_zigzag(-5), &mut bytes);
    let mut reader = Reader::new(&bytes);
    assert_eq!(reader.position(), 0);
    assert_eq!(reader.read_i64_zigzag().expect("zigzag"), -5);
    assert!(reader.position() > 0);
}

#[test]
fn session_shape_table_existing_registration_path() {
    let mut state = twilic_rust::session::SessionState::default();
    let keys = vec!["id".to_string(), "name".to_string()];
    let id0 = state.shape_table.register(keys.clone());
    let id1 = state.shape_table.register(keys.clone());
    assert_eq!(id0, id1);
    assert_eq!(state.shape_table.get_id(&keys), Some(id0));
    assert_eq!(
        state.shape_table.get_keys(id0).expect("shape keys").len(),
        2
    );
}

#[test]
fn shaped_object_presence_preserves_sparse_fields() {
    let mut codec = TwilicCodec::default();
    let value1 = Value::Map(vec![
        ("id".to_string(), Value::U64(1)),
        ("name".to_string(), Value::String("alice".to_string())),
        ("role".to_string(), Value::String("admin".to_string())),
    ]);
    let value2 = Value::Map(vec![
        ("id".to_string(), Value::U64(2)),
        ("role".to_string(), Value::String("viewer".to_string())),
    ]);

    let _ = codec.encode_value(&value1).expect("encode full");
    let bytes = codec.encode_value(&value2).expect("encode sparse");
    let decoded = codec.decode_value(&bytes).expect("decode sparse");
    assert_eq!(decoded, value2);
}

#[test]
fn encode_with_schema_rejects_missing_required_field() {
    let mut encoder = SessionEncoder::new(SessionOptions::default());
    let schema = twilic_rust::model::Schema {
        schema_id: 99,
        name: "Required".to_string(),
        fields: vec![twilic_rust::model::SchemaField {
            number: 1,
            name: "id".to_string(),
            logical_type: "u64".to_string(),
            required: true,
            default_value: None,
            min: None,
            max: None,
            enum_values: vec![],
        }],
    };
    let value = Value::Map(vec![]);
    assert!(matches!(
        encoder.encode_with_schema(&schema, &value),
        Err(TwilicError::InvalidData("missing required schema field"))
    ));
}

#[test]
fn inline_enum_control_is_applied_to_map_string_field() {
    let mut codec = TwilicCodec::default();
    let control = Message::Control(ControlMessage::PromoteStringFieldToEnum {
        field_identity: "role".to_string(),
        values: vec!["admin".to_string(), "viewer".to_string()],
    });
    let control_bytes = codec.encode_message(&control).expect("encode control");
    let _ = codec
        .decode_message(&control_bytes)
        .expect("decode control");

    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1)),
        ("role".to_string(), Value::String("viewer".to_string())),
    ]);
    let bytes = codec.encode_value(&value).expect("encode value");
    let decoded = codec.decode_value(&bytes).expect("decode value");
    assert_eq!(decoded, value);
}

#[test]
fn map_key_change_does_not_use_state_patch() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let base = Value::Map(vec![("id".to_string(), Value::U64(1))]);
    let changed_key = Value::Map(vec![("user_id".to_string(), Value::U64(1))]);

    let _ = enc.encode(&base).expect("encode base");
    let patch_bytes = enc.encode_patch(&changed_key).expect("encode patch");
    let decoded = enc.decode_message(&patch_bytes).expect("decode message");
    assert!(!matches!(decoded, Message::StatePatch { .. }));
}

#[test]
fn patch_threshold_prefers_full_message_when_change_ratio_is_high() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let base = Value::Map(
        (0..10)
            .map(|i| (format!("f{i}"), Value::U64(i as u64)))
            .collect(),
    );
    let changed = Value::Map(
        (0..10)
            .map(|i| {
                if i < 2 {
                    (format!("f{i}"), Value::U64((i + 100) as u64))
                } else {
                    (format!("f{i}"), Value::U64(i as u64))
                }
            })
            .collect(),
    );

    let _ = enc.encode(&base).expect("encode base");
    let bytes = enc.encode_patch(&changed).expect("encode patch candidate");
    let decoded = enc.decode_message(&bytes).expect("decode patch candidate");
    assert!(!matches!(decoded, Message::StatePatch { .. }));
}

#[test]
fn invalid_presence_flag_is_rejected() {
    let mut codec = TwilicCodec::default();
    let mut bytes = Vec::new();
    bytes.push(MessageKind::ShapedObject as u8);
    encode_varuint(0, &mut bytes);
    bytes.push(3);
    assert!(matches!(
        codec.decode_message(&bytes),
        Err(TwilicError::InvalidData("presence flag"))
    ));
}

#[test]
fn control_stream_rle_roundtrip() {
    let mut codec = TwilicCodec::default();
    let msg = Message::ControlStream {
        codec: ControlStreamCodec::Rle,
        payload: vec![1, 1, 1, 2, 2, 3, 3, 3, 3],
    };
    let bytes = codec.encode_message(&msg).expect("encode control stream");
    let decoded = codec.decode_message(&bytes).expect("decode control stream");
    assert_eq!(decoded, msg);
}
