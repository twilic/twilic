use twilic as twilic_rust;

use twilic_rust::{
    TwilicCodec,
    model::{ControlMessage, KeyRef, Message, MessageKind, StringMode, Value},
};

fn scalar_string_mode(bytes: &[u8]) -> u8 {
    assert_eq!(bytes[0], MessageKind::Scalar as u8);
    assert_eq!(bytes[1], 6);
    bytes[2]
}

#[test]
fn shape_promotes_after_second_three_field_map() {
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
fn two_field_map_keeps_map_and_uses_key_ids() {
    let mut codec = TwilicCodec::default();
    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1)),
        ("name".to_string(), Value::String("alice".to_string())),
    ]);

    let first = codec.encode_value(&value).expect("encode first");
    let first_msg = codec.decode_message(&first).expect("decode first");
    let Message::Map(first_entries) = first_msg else {
        panic!("expected first map")
    };
    assert!(
        first_entries
            .iter()
            .all(|entry| matches!(entry.key, KeyRef::Literal(_)))
    );

    let second = codec.encode_value(&value).expect("encode second");
    let second_msg = codec.decode_message(&second).expect("decode second");
    let Message::Map(second_entries) = second_msg else {
        panic!("expected second map")
    };
    assert!(
        second_entries
            .iter()
            .all(|entry| matches!(entry.key, KeyRef::Id(_)))
    );
}

#[test]
fn typed_vector_threshold_is_applied() {
    let mut codec = TwilicCodec::default();

    let short = Value::Array(vec![Value::I64(1), Value::I64(2), Value::I64(3)]);
    let short_bytes = codec.encode_value(&short).expect("encode short");
    let short_msg = codec.decode_message(&short_bytes).expect("decode short");
    assert!(matches!(short_msg, Message::Array(_)));

    let long = Value::Array(vec![
        Value::I64(1),
        Value::I64(2),
        Value::I64(3),
        Value::I64(4),
    ]);
    let long_bytes = codec.encode_value(&long).expect("encode long");
    let long_msg = codec.decode_message(&long_bytes).expect("decode long");
    assert!(matches!(long_msg, Message::TypedVector(_)));
}

#[test]
fn string_modes_empty_ref_and_prefix_delta_are_used() {
    let mut codec = TwilicCodec::default();

    let empty = codec
        .encode_value(&Value::String(String::new()))
        .expect("encode empty");
    assert_eq!(scalar_string_mode(&empty), StringMode::Empty as u8);

    let lit = codec
        .encode_value(&Value::String("alpha".to_string()))
        .expect("encode literal");
    assert_eq!(scalar_string_mode(&lit), StringMode::Literal as u8);

    let r = codec
        .encode_value(&Value::String("alpha".to_string()))
        .expect("encode ref");
    assert_eq!(scalar_string_mode(&r), StringMode::Ref as u8);

    let _ = codec
        .encode_value(&Value::String("prefix_common_aaaa".to_string()))
        .expect("encode prefix base");
    let pd = codec
        .encode_value(&Value::String("prefix_common_bbbb".to_string()))
        .expect("encode prefix delta");
    assert_eq!(scalar_string_mode(&pd), StringMode::PrefixDelta as u8);
}

#[test]
fn reset_tables_clears_string_interning() {
    let mut codec = TwilicCodec::default();
    let _ = codec
        .encode_value(&Value::String("ephemeral".to_string()))
        .expect("encode before reset");
    let reused = codec
        .encode_value(&Value::String("ephemeral".to_string()))
        .expect("encode reused");
    assert_eq!(scalar_string_mode(&reused), StringMode::Ref as u8);

    let reset = codec
        .encode_message(&Message::Control(ControlMessage::ResetTables))
        .expect("encode reset");
    let _ = codec.decode_message(&reset).expect("decode reset");

    let after_reset = codec
        .encode_value(&Value::String("ephemeral".to_string()))
        .expect("encode after reset");
    assert_eq!(scalar_string_mode(&after_reset), StringMode::Literal as u8);
}
