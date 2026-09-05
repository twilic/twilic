use twilic::{
    model::{ControlStreamCodec, Message, MessageKind, Value},
    wire::Reader,
    SessionEncoder, SessionOptions, TwilicCodec,
};

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

fn emit(stream: &str, label: &str, bytes: &[u8]) {
    println!("{stream}|{label}|{}", encode_hex(bytes));
}

fn reset_encode_shape_observation(codec: &mut TwilicCodec, keys: &[&str]) {
    let key: Vec<String> = keys.iter().map(|k| (*k).to_string()).collect();
    codec.state.encode_shape_observations.remove(&key);
}

fn id_name_map(id: u64, name: &str) -> Value {
    Value::Map(vec![
        ("id".to_string(), Value::U64(id)),
        ("name".to_string(), Value::String(name.to_string())),
    ])
}

fn id_name_role_map(id: u64, name: &str, role: &str) -> Value {
    Value::Map(vec![
        ("id".to_string(), Value::U64(id)),
        ("name".to_string(), Value::String(name.to_string())),
        ("role".to_string(), Value::String(role.to_string())),
    ])
}

fn make_i64_array(len: usize, start: i64) -> Value {
    Value::Array((0..len).map(|i| Value::I64(start + i as i64)).collect())
}

fn make_user_rows(names: &[&str]) -> Vec<Value> {
    names
        .iter()
        .enumerate()
        .map(|(idx, name)| {
            Value::Map(vec![
                ("id".to_string(), Value::U64((idx + 1) as u64)),
                ("name".to_string(), Value::String((*name).to_string())),
            ])
        })
        .collect()
}

fn control_stream_frame_mode(bytes: &[u8]) -> Result<u8, String> {
    let mut reader = Reader::new(bytes);
    let kind = reader
        .read_u8()
        .map_err(|e| format!("read message kind: {e}"))?;
    if kind != MessageKind::ControlStream as u8 {
        return Err(format!("expected ControlStream kind, got {kind}"));
    }
    let _codec = reader.read_u8().map_err(|e| format!("read codec: {e}"))?;
    let framed = reader
        .read_bytes()
        .map_err(|e| format!("read framed payload: {e}"))?;
    framed
        .first()
        .copied()
        .ok_or_else(|| "missing framed mode byte".to_string())
}

fn main() -> Result<(), String> {
    let mut codec = TwilicCodec::default();

    let scalar_string = Value::String("alpha".to_string());
    let bytes = codec
        .encode_value(&scalar_string)
        .map_err(|e| format!("encode scalar_string: {e}"))?;
    emit("codec", "scalar_string", &bytes);

    let map_two = id_name_map(1, "alice");
    let bytes = codec
        .encode_value(&map_two)
        .map_err(|e| format!("encode map_two_fields_first: {e}"))?;
    emit("codec", "map_two_fields_first", &bytes);
    reset_encode_shape_observation(&mut codec, &["id", "name"]);
    let bytes = codec
        .encode_value(&map_two)
        .map_err(|e| format!("encode map_two_fields_second: {e}"))?;
    emit("codec", "map_two_fields_second", &bytes);

    let map_three = id_name_role_map(1, "alice", "admin");
    let bytes = codec
        .encode_value(&map_three)
        .map_err(|e| format!("encode map_three_fields_first: {e}"))?;
    emit("codec", "map_three_fields_first", &bytes);
    reset_encode_shape_observation(&mut codec, &["id", "name", "role"]);
    let bytes = codec
        .encode_value(&map_three)
        .map_err(|e| format!("encode map_three_fields_second: {e}"))?;
    emit("codec", "map_three_fields_second", &bytes);

    for idx in 0..8u64 {
        let value = id_name_map(10 + idx, &format!("user-{idx}"));
        let bytes = codec
            .encode_value(&value)
            .map_err(|e| format!("encode bulk_map_{idx}: {e}"))?;
        emit("codec", &format!("bulk_map_{idx}"), &bytes);
    }

    let bitpack_payload: Vec<u8> = (0..512).map(|idx| (idx % 2) as u8).collect();
    let msg = Message::ControlStream {
        codec: ControlStreamCodec::Bitpack,
        payload: bitpack_payload,
    };
    let bytes = codec
        .encode_message(&msg)
        .map_err(|e| format!("encode control_stream_bitpack: {e}"))?;
    let bitpack_mode = control_stream_frame_mode(&bytes)?;
    if bitpack_mode == 0 {
        return Err("bitpack payload unexpectedly fell back to raw mode".to_string());
    }
    emit("codec", "control_stream_bitpack", &bytes);

    let huffman_payload = vec![7u8; 512];
    let msg = Message::ControlStream {
        codec: ControlStreamCodec::Huffman,
        payload: huffman_payload,
    };
    let bytes = codec
        .encode_message(&msg)
        .map_err(|e| format!("encode control_stream_huffman: {e}"))?;
    let huff_mode = control_stream_frame_mode(&bytes)?;
    if huff_mode != 1 {
        return Err(format!("expected huffman frame mode 1, got {huff_mode}"));
    }
    emit("codec", "control_stream_huffman", &bytes);

    let fse_payload: Vec<u8> = (0..512).map(|idx| (idx % 4) as u8).collect();
    let msg = Message::ControlStream {
        codec: ControlStreamCodec::Fse,
        payload: fse_payload,
    };
    let bytes = codec
        .encode_message(&msg)
        .map_err(|e| format!("encode control_stream_fse: {e}"))?;
    let fse_mode = control_stream_frame_mode(&bytes)?;
    if fse_mode != 3 {
        return Err(format!("expected fse frame mode 3, got {fse_mode}"));
    }
    emit("codec", "control_stream_fse", &bytes);

    let msg = Message::BaseSnapshot {
        base_id: 77,
        schema_or_shape_ref: 0,
        payload: Box::new(Message::Scalar(Value::I64(42))),
    };
    let bytes = codec
        .encode_message(&msg)
        .map_err(|e| format!("encode base_snapshot: {e}"))?;
    emit("codec", "base_snapshot", &bytes);

    let mut session = SessionEncoder::new(SessionOptions::default());
    let base = make_i64_array(100, 0);
    let bytes = session
        .encode(&base)
        .map_err(|e| format!("encode session_base_array: {e}"))?;
    emit("session", "session_base_array", &bytes);

    let mut one_change = make_i64_array(100, 0);
    if let Value::Array(values) = &mut one_change {
        values[0] = Value::I64(10_000);
    }
    let bytes = session
        .encode_patch(&one_change)
        .map_err(|e| format!("encode session_patch_one_change: {e}"))?;
    emit("session", "session_patch_one_change", &bytes);

    for idx in 0..4usize {
        let mut iterative = make_i64_array(100, 0);
        if let Value::Array(values) = &mut iterative {
            values[idx] = Value::I64(20_000 + idx as i64);
        }
        let bytes = session
            .encode_patch(&iterative)
            .map_err(|e| format!("encode session_patch_iter_{idx}: {e}"))?;
        emit("session", &format!("session_patch_iter_{idx}"), &bytes);
    }

    let mut many_change = make_i64_array(100, 0);
    if let Value::Array(values) = &mut many_change {
        for (idx, slot) in values[0..12].iter_mut().enumerate() {
            *slot = Value::I64(10_000 + idx as i64);
        }
    }
    let bytes = session
        .encode_patch(&many_change)
        .map_err(|e| format!("encode session_patch_many_changes: {e}"))?;
    emit("session", "session_patch_many_changes", &bytes);

    let rows1 = make_user_rows(&["a", "b", "c", "d"]);
    let bytes = session
        .encode_micro_batch(&rows1)
        .map_err(|e| format!("encode session_micro_batch_first: {e}"))?;
    emit("session", "session_micro_batch_first", &bytes);

    let rows2 = make_user_rows(&["aa", "bb", "cc", "dd"]);
    let bytes = session
        .encode_micro_batch(&rows2)
        .map_err(|e| format!("encode session_micro_batch_second: {e}"))?;
    emit("session", "session_micro_batch_second", &bytes);

    Ok(())
}
