use twilic::{Message, TwilicCodec, Value, wire::Reader};

#[test]
fn session_nesting_is_an_error_and_codec_remains_usable() {
    let mut value = Value::Null;
    for _ in 0..70 {
        value = Value::Array(vec![value]);
    }
    let mut encoder = TwilicCodec::default();
    let bytes = encoder.encode_message(&Message::Scalar(value)).unwrap();
    let mut decoder = TwilicCodec::default();
    assert!(
        decoder
            .decode_message(&bytes)
            .unwrap_err()
            .to_string()
            .contains("depth limit")
    );
    assert_eq!(decoder.decode_value(&[0, 0]).unwrap(), Value::Null);
}

#[test]
fn output_budget_is_shared_across_multiple_claims() {
    let mut reader = Reader::new(&[0]);
    reader.claim_output(100, 8).unwrap();
    assert!(reader.claim_output(100, 8).is_err());
}

#[test]
fn nested_message_envelopes_are_bounded() {
    let mut message = Message::Scalar(Value::Null);
    for _ in 0..70 {
        message = Message::BaseSnapshot {
            base_id: 0,
            schema_or_shape_ref: 0,
            payload: Box::new(message),
        };
    }
    let bytes = TwilicCodec::default().encode_message(&message).unwrap();
    assert!(TwilicCodec::default().decode_message(&bytes).is_err());
}

#[test]
fn rejected_message_does_not_commit_session_state() {
    let mut decoder = TwilicCodec::default();
    decoder.decode_value(&[0, 0]).unwrap();
    let previous = decoder.state.previous_message.clone();
    let mut bytes = TwilicCodec::default()
        .encode_message(&Message::BaseSnapshot {
            base_id: 7,
            schema_or_shape_ref: 0,
            payload: Box::new(Message::Scalar(Value::Null)),
        })
        .unwrap();
    bytes.push(0);
    assert!(decoder.decode_message(&bytes).is_err());
    assert_eq!(decoder.state.previous_message, previous);
    assert!(decoder.state.get_base_snapshot(7).is_none());
}
