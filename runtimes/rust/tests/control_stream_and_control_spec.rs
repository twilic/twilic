use twilic as twilic_rust;

use twilic_rust::{
    TwilicCodec, TwilicError,
    model::{ControlMessage, ControlStreamCodec, KeyRef, Message, MessageKind, Value},
    wire::{DECODE_OUTPUT_RATIO_MSG, Reader, encode_varuint},
};

fn encode_control_stream_wire(codec: ControlStreamCodec, encoded_payload: &[u8]) -> Vec<u8> {
    let mut out = vec![MessageKind::ControlStream as u8, codec as u8];
    encode_varuint(encoded_payload.len() as u64, &mut out);
    out.extend_from_slice(encoded_payload);
    out
}

#[test]
fn control_stream_rle_rejects_decompression_bomb() {
    let mut rle = Vec::new();
    encode_varuint(1, &mut rle);
    encode_varuint(100_000, &mut rle);
    rle.push(0x00);
    let bytes = encode_control_stream_wire(ControlStreamCodec::Rle, &rle);
    let mut codec = TwilicCodec::default();
    let err = codec
        .decode_message(&bytes)
        .expect_err("expected rle output ratio error");
    assert!(err.to_string().contains(DECODE_OUTPUT_RATIO_MSG));
}

#[test]
fn control_stream_huffman_rejects_decompression_bomb() {
    let mut huff = vec![1];
    encode_varuint(1, &mut huff);
    huff.push(0x00);
    encode_varuint(100_000, &mut huff);
    let bytes = encode_control_stream_wire(ControlStreamCodec::Huffman, &huff);
    let mut codec = TwilicCodec::default();
    let err = codec
        .decode_message(&bytes)
        .expect_err("expected huffman output ratio error");
    assert!(err.to_string().contains(DECODE_OUTPUT_RATIO_MSG));
}

#[test]
fn control_stream_fse_rejects_decompression_bomb() {
    let mut frame = vec![1];
    encode_varuint(100_000, &mut frame);
    encode_varuint(1, &mut frame);
    frame.push(0x00);
    encode_varuint(2, &mut frame);
    encode_varuint(0, &mut frame);
    let mut fse = vec![3];
    fse.extend_from_slice(&frame);
    let bytes = encode_control_stream_wire(ControlStreamCodec::Fse, &fse);
    let mut codec = TwilicCodec::default();
    let err = codec
        .decode_message(&bytes)
        .expect_err("expected fse output ratio error");
    assert!(err.to_string().contains(DECODE_OUTPUT_RATIO_MSG));
}

#[test]
fn control_stream_roundtrips_for_all_declared_codecs() {
    let mut codec = TwilicCodec::default();
    let payload = vec![0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4];
    for c in [
        ControlStreamCodec::Plain,
        ControlStreamCodec::Rle,
        ControlStreamCodec::Bitpack,
        ControlStreamCodec::Huffman,
        ControlStreamCodec::Fse,
    ] {
        let msg = Message::ControlStream {
            codec: c,
            payload: payload.clone(),
        };
        let bytes = codec.encode_message(&msg).expect("encode control stream");
        let decoded = codec.decode_message(&bytes).expect("decode control stream");
        assert_eq!(decoded, msg);
    }
}

fn encoded_control_stream_len(codec: ControlStreamCodec, payload: Vec<u8>) -> usize {
    let mut codec_impl = TwilicCodec::default();
    let msg = Message::ControlStream { codec, payload };
    codec_impl
        .encode_message(&msg)
        .expect("encode control stream")
        .len()
}

#[test]
fn control_stream_bitpack_huffman_fse_compact_repetitive_payloads() {
    let binary_payload: Vec<u8> = (0..512).map(|idx| (idx % 2) as u8).collect();
    let plain_binary_len =
        encoded_control_stream_len(ControlStreamCodec::Plain, binary_payload.clone());
    let bitpack_len = encoded_control_stream_len(ControlStreamCodec::Bitpack, binary_payload);
    assert!(bitpack_len < plain_binary_len);

    let rle_friendly_payload = vec![7u8; 512];
    let plain_rle_len =
        encoded_control_stream_len(ControlStreamCodec::Plain, rle_friendly_payload.clone());
    let huffman_len =
        encoded_control_stream_len(ControlStreamCodec::Huffman, rle_friendly_payload.clone());
    assert!(huffman_len < plain_rle_len);

    let low_cardinality_payload: Vec<u8> = (0..512).map(|idx| (idx % 4) as u8).collect();
    let plain_low_card_len =
        encoded_control_stream_len(ControlStreamCodec::Plain, low_cardinality_payload.clone());
    let fse_len = encoded_control_stream_len(ControlStreamCodec::Fse, low_cardinality_payload);
    assert!(fse_len < plain_low_card_len);
}

#[test]
fn control_stream_fse_uses_fse_frame_mode() {
    let mut codec = TwilicCodec::default();
    let payload: Vec<u8> = (0..512).map(|idx| (idx % 4) as u8).collect();
    let msg = Message::ControlStream {
        codec: ControlStreamCodec::Fse,
        payload,
    };
    let bytes = codec
        .encode_message(&msg)
        .expect("encode fse control stream");

    let mut reader = Reader::new(&bytes);
    assert_eq!(
        reader.read_u8().expect("message kind"),
        MessageKind::ControlStream as u8
    );
    assert_eq!(
        reader.read_u8().expect("codec"),
        ControlStreamCodec::Fse as u8
    );
    let framed = reader.read_bytes().expect("framed control payload");
    assert_eq!(framed.first().copied(), Some(3));
}

#[test]
fn register_shape_with_key_ids_roundtrips() {
    let mut codec = TwilicCodec::default();

    let reg_keys = Message::Control(ControlMessage::RegisterKeys(vec![
        "id".to_string(),
        "name".to_string(),
    ]));
    let reg_keys_bytes = codec
        .encode_message(&reg_keys)
        .expect("encode register keys");
    let _ = codec
        .decode_message(&reg_keys_bytes)
        .expect("decode register keys");

    let reg_shape = Message::Control(ControlMessage::RegisterShape {
        shape_id: 99,
        keys: vec![KeyRef::Id(0), KeyRef::Id(1)],
    });
    let reg_shape_bytes = codec
        .encode_message(&reg_shape)
        .expect("encode register shape");
    let decoded = codec
        .decode_message(&reg_shape_bytes)
        .expect("decode register shape");
    assert_eq!(decoded, reg_shape);

    let shaped = Message::ShapedObject {
        shape_id: 99,
        presence: None,
        values: vec![Value::U64(1), Value::String("alice".to_string())],
    };
    let shaped_bytes = codec.encode_message(&shaped).expect("encode shaped");
    let value = codec.decode_value(&shaped_bytes).expect("decode shaped");
    assert_eq!(
        value,
        Value::Map(vec![
            ("id".to_string(), Value::U64(1)),
            ("name".to_string(), Value::String("alice".to_string()))
        ])
    );
}

#[test]
fn reset_state_clears_shape_resolution() {
    let mut codec = TwilicCodec::default();

    let reg_shape = Message::Control(ControlMessage::RegisterShape {
        shape_id: 7,
        keys: vec![
            KeyRef::Literal("id".to_string()),
            KeyRef::Literal("name".to_string()),
        ],
    });
    let reg_bytes = codec
        .encode_message(&reg_shape)
        .expect("encode register shape");
    let _ = codec
        .decode_message(&reg_bytes)
        .expect("decode register shape");

    let reset = Message::Control(ControlMessage::ResetState);
    let reset_bytes = codec.encode_message(&reset).expect("encode reset state");
    let _ = codec
        .decode_message(&reset_bytes)
        .expect("decode reset state");

    let shaped = Message::ShapedObject {
        shape_id: 7,
        presence: None,
        values: vec![Value::U64(1), Value::String("alice".to_string())],
    };
    let shaped_bytes = codec.encode_message(&shaped).expect("encode shaped object");
    let err = codec
        .decode_value(&shaped_bytes)
        .expect_err("shape should be unknown");
    assert!(matches!(err, TwilicError::UnknownReference("shape_id", 7)));
}
