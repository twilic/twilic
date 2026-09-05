use twilic as twilic_rust;

use twilic_rust::{
    SessionEncoder, TwilicCodec, TwilicError,
    model::{
        BaseRef, Column, Message, MessageKind, NullStrategy, TypedVectorData, Value, VectorCodec,
    },
    session::{DictionaryFallback, DictionaryProfile, SessionOptions, UnknownReferencePolicy},
    wire::{Reader, encode_string, encode_varuint},
};

fn fnv1a64(input: &[u8]) -> u64 {
    const OFFSET: u64 = 0xcbf29ce484222325;
    const PRIME: u64 = 0x100000001b3;
    let mut hash = OFFSET;
    for byte in input {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

fn sample_schema() -> twilic_rust::model::Schema {
    twilic_rust::model::Schema {
        schema_id: 41,
        name: "User".to_string(),
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
            twilic_rust::model::SchemaField {
                number: 3,
                name: "score".to_string(),
                logical_type: "i64".to_string(),
                required: false,
                default_value: None,
                min: Some(0),
                max: Some(100),
                enum_values: vec![],
            },
        ],
    }
}

#[test]
fn schema_id_is_sent_first_then_omitted() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let schema = sample_schema();
    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1005)),
        ("name".to_string(), Value::String("alice".to_string())),
        ("score".to_string(), Value::I64(99)),
    ]);

    let first = enc
        .encode_with_schema(&schema, &value)
        .expect("encode first schema msg");
    let first_msg = enc.decode_message(&first).expect("decode first schema msg");
    assert!(matches!(
        first_msg,
        Message::SchemaObject {
            schema_id: Some(41),
            ..
        }
    ));

    let second = enc
        .encode_with_schema(&schema, &value)
        .expect("encode second schema msg");
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
fn batch_threshold_selects_row_vs_column() {
    let mut enc = SessionEncoder::new(SessionOptions::default());

    let rows_15: Vec<Value> = (0..15)
        .map(|i| Value::Map(vec![("id".to_string(), Value::U64(i))]))
        .collect();
    let b15 = enc.encode_batch(&rows_15).expect("encode batch 15");
    let m15 = enc.decode_message(&b15).expect("decode batch 15");
    assert!(matches!(m15, Message::RowBatch { .. }));

    let rows_16: Vec<Value> = (0..16)
        .map(|i| Value::Map(vec![("id".to_string(), Value::U64(i))]))
        .collect();
    let b16 = enc.encode_batch(&rows_16).expect("encode batch 16");
    let m16 = enc.decode_message(&b16).expect("decode batch 16");
    assert!(matches!(m16, Message::ColumnBatch { .. }));
}

#[test]
fn micro_batch_reuses_template_and_emits_changed_mask() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let rows1 = vec![
        Value::Map(vec![
            ("id".to_string(), Value::U64(1)),
            ("name".to_string(), Value::String("a".to_string())),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(2)),
            ("name".to_string(), Value::String("b".to_string())),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(3)),
            ("name".to_string(), Value::String("c".to_string())),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(4)),
            ("name".to_string(), Value::String("d".to_string())),
        ]),
    ];
    let first = enc.encode_micro_batch(&rows1).expect("encode first micro");
    let first_msg = enc.decode_message(&first).expect("decode first micro");
    let Message::TemplateBatch {
        template_id,
        changed_column_mask,
        ..
    } = first_msg
    else {
        panic!("expected template batch")
    };
    assert!(changed_column_mask.iter().all(|bit| *bit));

    let rows2 = vec![
        Value::Map(vec![
            ("id".to_string(), Value::U64(1)),
            ("name".to_string(), Value::String("aa".to_string())),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(2)),
            ("name".to_string(), Value::String("bb".to_string())),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(3)),
            ("name".to_string(), Value::String("cc".to_string())),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(4)),
            ("name".to_string(), Value::String("dd".to_string())),
        ]),
    ];
    let second = enc.encode_micro_batch(&rows2).expect("encode second micro");
    let second_msg = enc.decode_message(&second).expect("decode second micro");
    let Message::TemplateBatch {
        template_id: second_template,
        changed_column_mask,
        ..
    } = second_msg
    else {
        panic!("expected template batch")
    };
    assert_eq!(second_template, template_id);
    assert!(changed_column_mask.iter().any(|bit| !*bit));
}

#[test]
fn state_patch_uses_recommended_ratio_threshold() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let base_values: Vec<Value> = (0..100).map(Value::I64).collect();
    let mut one_change_values = base_values.clone();
    one_change_values[0] = Value::I64(10_000);
    let mut two_change_values = base_values.clone();
    for (idx, slot) in two_change_values.iter_mut().enumerate().take(12) {
        *slot = Value::I64(10_000 + idx as i64);
    }

    let base = Value::Array(base_values);
    let one_change = Value::Array(one_change_values);
    let two_change = Value::Array(two_change_values);

    let _ = enc.encode(&base).expect("encode base");

    let p1 = enc
        .encode_patch(&one_change)
        .expect("encode one-change patch");
    let m1 = enc.decode_message(&p1).expect("decode one-change patch");
    assert!(matches!(m1, Message::StatePatch { .. }));

    let p2 = enc
        .encode_patch(&two_change)
        .expect("encode two-change candidate");
    let m2 = enc
        .decode_message(&p2)
        .expect("decode two-change candidate");
    assert!(!matches!(m2, Message::StatePatch { .. }));
}

#[test]
fn unknown_base_id_honors_stateless_retry_policy() {
    let mut enc = SessionEncoder::new(SessionOptions {
        unknown_reference_policy: UnknownReferencePolicy::StatelessRetry,
        ..SessionOptions::default()
    });

    let patch = Message::StatePatch {
        base_ref: BaseRef::BaseId(12345),
        operations: vec![],
        literals: vec![],
    };
    let bytes = enc
        .decode_message(
            &twilic_rust::TwilicCodec::with_options(SessionOptions::default())
                .encode_message(&patch)
                .expect("encode patch"),
        )
        .expect_err("should require retry");
    assert!(matches!(
        bytes,
        TwilicError::StatelessRetryRequired("base_id", 12345)
    ));
}

#[test]
fn state_patch_map_insert_and_delete_roundtrip_via_reconstruction() {
    let mut codec = TwilicCodec::default();
    let base = Message::Map(vec![
        twilic_rust::model::MapEntry {
            key: twilic_rust::model::KeyRef::Literal("id".to_string()),
            value: Value::U64(1),
        },
        twilic_rust::model::MapEntry {
            key: twilic_rust::model::KeyRef::Literal("name".to_string()),
            value: Value::String("alice".to_string()),
        },
    ]);
    let base_bytes = codec.encode_message(&base).expect("encode base");
    let _ = codec.decode_message(&base_bytes).expect("decode base");

    let insert_patch = Message::StatePatch {
        base_ref: BaseRef::Previous,
        operations: vec![twilic_rust::model::PatchOperation {
            field_id: 2,
            opcode: twilic_rust::model::PatchOpcode::InsertField,
            value: Some(Value::Map(vec![(
                "role".to_string(),
                Value::String("admin".to_string()),
            )])),
        }],
        literals: vec![],
    };
    let insert_bytes = codec
        .encode_message(&insert_patch)
        .expect("encode insert patch");
    let _ = codec
        .decode_message(&insert_bytes)
        .expect("decode insert patch");
    let inserted = codec
        .state
        .previous_message
        .clone()
        .expect("reconstructed message");
    let Message::Map(inserted_entries) = inserted else {
        panic!("expected reconstructed map after insert")
    };
    assert_eq!(inserted_entries.len(), 3);

    let delete_patch = Message::StatePatch {
        base_ref: BaseRef::Previous,
        operations: vec![twilic_rust::model::PatchOperation {
            field_id: 2,
            opcode: twilic_rust::model::PatchOpcode::DeleteField,
            value: None,
        }],
        literals: vec![],
    };
    let delete_bytes = codec
        .encode_message(&delete_patch)
        .expect("encode delete patch");
    let _ = codec
        .decode_message(&delete_bytes)
        .expect("decode delete patch");
    let deleted = codec
        .state
        .previous_message
        .clone()
        .expect("reconstructed message");
    let Message::Map(deleted_entries) = deleted else {
        panic!("expected reconstructed map after delete")
    };
    assert_eq!(deleted_entries.len(), 2);
}

#[test]
fn column_batch_assigns_trained_dictionary_id_for_repeated_string_field() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let rows: Vec<Value> = (0..32)
        .map(|idx| {
            Value::Map(vec![
                ("id".to_string(), Value::U64(idx)),
                (
                    "role".to_string(),
                    Value::String(if idx % 2 == 0 { "admin" } else { "user" }.to_string()),
                ),
            ])
        })
        .collect();

    let bytes = enc.encode_batch(&rows).expect("encode batch");
    let decoded = enc.decode_message(&bytes).expect("decode batch");
    let Message::ColumnBatch { columns, .. } = decoded else {
        panic!("expected column batch")
    };
    assert!(columns.iter().any(|column| column.dictionary_id.is_some()));
}

#[test]
fn trained_dictionary_profile_is_transported_to_fresh_decoder() {
    let mut enc = SessionEncoder::new(SessionOptions::default());
    let rows: Vec<Value> = (0..32)
        .map(|idx| {
            Value::Map(vec![
                ("id".to_string(), Value::U64(idx)),
                (
                    "role".to_string(),
                    Value::String(if idx % 2 == 0 { "admin" } else { "user" }.to_string()),
                ),
            ])
        })
        .collect();
    let bytes = enc.encode_batch(&rows).expect("encode batch");

    let mut dec = TwilicCodec::default();
    let decoded = dec.decode_message(&bytes).expect("decode batch");
    let Message::ColumnBatch { columns, .. } = decoded else {
        panic!("expected column batch")
    };
    let dict_id = columns
        .iter()
        .find_map(|column| column.dictionary_id)
        .expect("dictionary id in batch");

    let payload = dec
        .state
        .dictionaries
        .get(&dict_id)
        .expect("transported dictionary payload");
    let profile = dec
        .state
        .dictionary_profiles
        .get(&dict_id)
        .expect("transported dictionary profile");

    assert_eq!(profile.version, 1);
    assert_eq!(profile.expires_at, 0);
    assert_eq!(profile.fallback, DictionaryFallback::FailFast);
    assert_eq!(profile.hash, fnv1a64(payload));
    let role_values = columns
        .iter()
        .find(|column| column.dictionary_id == Some(dict_id))
        .and_then(|column| match &column.values {
            TypedVectorData::String(values) => Some(values.clone()),
            _ => None,
        })
        .expect("role column values");
    assert_eq!(role_values.len(), 32);
    assert_eq!(role_values[0], "admin".to_string());
    assert_eq!(role_values[1], "user".to_string());
}

#[test]
fn invalid_dictionary_profile_hash_is_rejected() {
    let mut enc = TwilicCodec::default();
    let dict_id = 42;
    let payload = vec![1, 2, 3, 4];
    enc.state.dictionaries.insert(dict_id, payload);
    enc.state.dictionary_profiles.insert(
        dict_id,
        DictionaryProfile {
            version: 1,
            hash: 7,
            expires_at: 0,
            fallback: DictionaryFallback::FailFast,
        },
    );

    let msg = Message::ColumnBatch {
        count: 1,
        columns: vec![Column {
            field_id: 0,
            null_strategy: NullStrategy::AllPresentElided,
            presence: None,
            codec: VectorCodec::Dictionary,
            dictionary_id: Some(dict_id),
            values: TypedVectorData::String(vec!["admin".to_string()]),
        }],
    };
    let bytes = enc.encode_message(&msg).expect("encode column batch");

    let mut dec = TwilicCodec::default();
    assert!(matches!(
        dec.decode_message(&bytes),
        Err(TwilicError::InvalidData("dictionary profile hash mismatch"))
    ));
}

#[test]
fn trained_dictionary_reference_writes_compressed_block_after_dict_id() {
    let dict_id = 9;
    let mut codec = TwilicCodec::default();
    let mut payload = Vec::new();
    encode_varuint(2, &mut payload);
    encode_string("admin", &mut payload);
    encode_string("user", &mut payload);
    let hash = fnv1a64(&payload);
    codec.state.dictionaries.insert(dict_id, payload);
    codec.state.dictionary_profiles.insert(
        dict_id,
        DictionaryProfile {
            version: 1,
            hash,
            expires_at: 0,
            fallback: DictionaryFallback::FailFast,
        },
    );

    let msg = Message::ColumnBatch {
        count: 4,
        columns: vec![Column {
            field_id: 1,
            null_strategy: NullStrategy::AllPresentElided,
            presence: None,
            codec: VectorCodec::Dictionary,
            dictionary_id: Some(dict_id),
            values: TypedVectorData::String(vec![
                "admin".to_string(),
                "user".to_string(),
                "admin".to_string(),
                "user".to_string(),
            ]),
        }],
    };
    let bytes = codec.encode_message(&msg).expect("encode with dictionary");

    let mut reader = Reader::new(&bytes);
    assert_eq!(
        reader.read_u8().expect("kind"),
        MessageKind::ColumnBatch as u8
    );
    assert_eq!(reader.read_varuint().expect("count"), 4);
    assert_eq!(reader.read_varuint().expect("column count"), 1);
    assert_eq!(reader.read_varuint().expect("field id"), 1);
    assert_eq!(
        reader.read_u8().expect("null strategy"),
        NullStrategy::AllPresentElided as u8
    );
    assert_eq!(
        reader.read_u8().expect("codec"),
        VectorCodec::Dictionary as u8
    );
    assert_eq!(reader.read_u8().expect("dict flag"), 1);
    assert_eq!(reader.read_varuint().expect("dict id"), dict_id);
    assert_eq!(reader.read_u8().expect("profile flag"), 1);
    assert_eq!(reader.read_varuint().expect("version"), 1);
    assert_eq!(reader.read_varuint().expect("hash"), hash);
    assert_eq!(reader.read_varuint().expect("expires"), 0);
    assert_eq!(
        reader.read_u8().expect("fallback"),
        DictionaryFallback::FailFast as u8
    );
    let _dict_payload = reader.read_bytes().expect("dictionary payload");
    assert_eq!(reader.read_u8().expect("column payload mode"), 1);
    let compressed_block = reader.read_bytes().expect("compressed block");
    assert!(!compressed_block.is_empty());
    assert!(reader.is_eof());

    let mut fresh = TwilicCodec::default();
    let decoded = fresh
        .decode_message(&bytes)
        .expect("decode with compressed block");
    let Message::ColumnBatch { columns, .. } = decoded else {
        panic!("expected column batch")
    };
    let TypedVectorData::String(values) = &columns[0].values else {
        panic!("expected string values")
    };
    assert_eq!(
        values,
        &vec![
            "admin".to_string(),
            "user".to_string(),
            "admin".to_string(),
            "user".to_string()
        ]
    );
}
