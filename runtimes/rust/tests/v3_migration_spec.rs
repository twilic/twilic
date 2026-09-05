use twilic::{SessionEncoder, TwilicCodec, TwilicError, Value};

use twilic::model::{Message, MessageKind, NullStrategy, PresenceStrategy, Schema, SchemaField};
use twilic::wire::{Reader, encode_varuint};

fn schema_with_sparse_field() -> Schema {
    Schema {
        schema_id: 41,
        name: "User".to_string(),
        fields: vec![
            SchemaField {
                number: 99,
                name: "id".to_string(),
                logical_type: "u64".to_string(),
                required: true,
                default_value: None,
                min: None,
                max: None,
                enum_values: vec![],
            },
            SchemaField {
                number: 100,
                name: "name".to_string(),
                logical_type: "string".to_string(),
                required: true,
                default_value: None,
                min: None,
                max: None,
                enum_values: vec![],
            },
            SchemaField {
                number: 101,
                name: "score".to_string(),
                logical_type: "i64".to_string(),
                required: false,
                default_value: None,
                min: None,
                max: None,
                enum_values: vec![],
            },
        ],
    }
}

#[test]
fn v3_dynamic_rejects_overlong_varuint_refs() {
    let bytes = [0xB2, 0x81, b'a', 0x01, 0xD8, 0x80, 0x00, 0x02];
    let err = twilic::decode(&bytes).expect_err("overlong key_ref varuint must fail");
    assert!(matches!(err, TwilicError::InvalidData("varuint overlong")));
}

#[test]
fn v3_dynamic_rejects_non_canonical_integer_widths() {
    let err = twilic::decode(&[0xC4, 0x7F]).expect_err("127 must use positive fixint");
    assert!(matches!(
        err,
        TwilicError::InvalidData("non-canonical integer encoding")
    ));

    let err = twilic::decode(&[0xC8, 0xFF]).expect_err("-1 must use negative fixint");
    assert!(matches!(
        err,
        TwilicError::InvalidData("non-canonical integer encoding")
    ));
}

#[test]
fn twilic_pv_rejects_overlong_and_accepts_max_u64() {
    let mut overlong = Reader::new(&[0x80, 0x00]);
    assert!(matches!(
        overlong.read_varuint(),
        Err(TwilicError::InvalidData("varuint overlong"))
    ));

    let mut encoded = Vec::new();
    encode_varuint(u64::MAX, &mut encoded);
    let mut reader = Reader::new(&encoded);
    assert_eq!(reader.read_varuint().expect("u64 max"), u64::MAX);
}

#[test]
fn v3_schema_batch_uses_schema_order_envelope() {
    let schema = schema_with_sparse_field();
    let rows = vec![
        Value::Map(vec![
            ("id".to_string(), Value::U64(1)),
            ("name".to_string(), Value::String("alice".to_string())),
            ("score".to_string(), Value::I64(10)),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(2)),
            ("name".to_string(), Value::String("bob".to_string())),
        ]),
    ];
    let mut enc = SessionEncoder::new(Default::default());
    let bytes = enc
        .encode_batch_with_schema(&schema, &rows)
        .expect("schema batch");
    assert_eq!(bytes[0], MessageKind::SchemaBatch as u8);

    let mut reader = Reader::new(&bytes);
    assert_eq!(
        reader.read_u8().expect("kind"),
        MessageKind::SchemaBatch as u8
    );
    assert_eq!(reader.read_varuint().expect("schema id"), 41);
    assert_eq!(reader.read_varuint().expect("count"), 2);
    assert_eq!(reader.read_varuint().expect("column count"), 3);
    assert_eq!(reader.read_u8().expect("first column null strategy"), 0);

    let decoded = enc.decode_message(&bytes).expect("decode schema batch");
    let Message::SchemaBatch {
        schema_id,
        count,
        columns,
    } = decoded
    else {
        panic!("expected schema batch")
    };
    assert_eq!(schema_id, 41);
    assert_eq!(count, 2);
    assert_eq!(columns[0].field_id, 99);
    assert_eq!(columns[2].null_strategy, NullStrategy::PresenceBitmap);
}

#[test]
fn v3_bound_stream_uses_new_envelope_kind() {
    let schema = schema_with_sparse_field();
    let rows = vec![
        Value::Map(vec![
            ("id".to_string(), Value::U64(1)),
            ("name".to_string(), Value::String("alice".to_string())),
            ("score".to_string(), Value::I64(10)),
        ]),
        Value::Map(vec![
            ("id".to_string(), Value::U64(2)),
            ("name".to_string(), Value::String("bob".to_string())),
        ]),
    ];

    let mut enc = SessionEncoder::new(Default::default());
    let bytes = enc
        .encode_bound_stream(&schema, &rows)
        .expect("bound stream");
    assert_eq!(bytes[0], MessageKind::BoundStream as u8);

    let decoded = enc.decode_message(&bytes).expect("decode bound stream");
    let Message::BoundStream {
        schema_id,
        presence_strategy,
        records,
    } = decoded
    else {
        panic!("expected bound stream")
    };
    assert_eq!(schema_id, 41);
    assert_eq!(presence_strategy, PresenceStrategy::Normal);
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].fields.len(), 3);
    assert_eq!(records[1].fields.len(), 2);
}

#[test]
fn v3_bound_stream_requires_schema_context_on_decode() {
    let schema = schema_with_sparse_field();
    let rows = vec![Value::Map(vec![
        ("id".to_string(), Value::U64(1)),
        ("name".to_string(), Value::String("alice".to_string())),
    ])];
    let mut enc = SessionEncoder::new(Default::default());
    let bytes = enc
        .encode_bound_stream(&schema, &rows)
        .expect("bound stream");

    let mut fresh = TwilicCodec::default();
    assert!(matches!(
        fresh.decode_message(&bytes),
        Err(TwilicError::UnknownReference("schema_id", 41))
    ));
}
