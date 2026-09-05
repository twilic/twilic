use std::io::{self, Read};

use twilic::model::{Message, Value};
use twilic::TwilicCodec;

fn decode_hex(input: &str) -> Result<Vec<u8>, String> {
    if input.len() % 2 != 0 {
        return Err("hex length must be even".to_string());
    }
    let mut out = Vec::with_capacity(input.len() / 2);
    let bytes = input.as_bytes();
    let mut idx = 0usize;
    while idx < bytes.len() {
        let hi = from_hex(bytes[idx]).ok_or_else(|| "invalid hex".to_string())?;
        let lo = from_hex(bytes[idx + 1]).ok_or_else(|| "invalid hex".to_string())?;
        out.push((hi << 4) | lo);
        idx += 2;
    }
    Ok(out)
}

fn from_hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
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

fn assert_codec(label: &str, codec: &mut TwilicCodec, frame: &[u8]) -> Result<(), String> {
    match label {
        "control_stream_bitpack" | "control_stream_huffman" | "control_stream_fse" => {
            let msg = codec
                .decode_message(frame)
                .map_err(|e| format!("{label}: decode failed: {e}"))?;
            let Message::ControlStream { payload, .. } = msg else {
                return Err(format!("{label}: expected control stream"));
            };
            if payload.is_empty() {
                return Err(format!("{label}: payload empty"));
            }
        }
        "base_snapshot" => {
            let msg = codec
                .decode_message(frame)
                .map_err(|e| format!("{label}: decode failed: {e}"))?;
            let Message::BaseSnapshot {
                base_id, payload, ..
            } = msg
            else {
                return Err(format!("{label}: expected base snapshot"));
            };
            if base_id != 77 {
                return Err(format!("{label}: base_id got {base_id} want 77"));
            }
            let Message::Scalar(Value::I64(42)) = payload.as_ref() else {
                return Err(format!("{label}: payload mismatch"));
            };
        }
        other => {
            let got = codec
                .decode_value(frame)
                .map_err(|e| format!("{other}: decode_value failed: {e}"))?;
            let want = match other {
                "scalar_string" => Value::String("alpha".to_string()),
                "map_two_fields_first" | "map_two_fields_second" => id_name_map(1, "alice"),
                "map_three_fields_first" | "map_three_fields_second" => {
                    id_name_role_map(1, "alice", "admin")
                }
                label if label.starts_with("bulk_map_") => {
                    let idx: u64 = label
                        .trim_start_matches("bulk_map_")
                        .parse()
                        .map_err(|_| format!("invalid bulk label {label}"))?;
                    id_name_map(10 + idx, &format!("user-{idx}"))
                }
                other => return Err(format!("no codec expectation for {other}")),
            };
            if got != want {
                return Err(format!("{other}: got {got:?} want {want:?}"));
            }
        }
    }
    Ok(())
}

fn assert_session(label: &str, codec: &mut TwilicCodec, frame: &[u8]) -> Result<(), String> {
    match label {
        "session_base_array" => {
            let got = codec
                .decode_value(frame)
                .map_err(|e| format!("{label}: decode_value failed: {e}"))?;
            let want = Value::Array((0..100).map(|i| Value::I64(i as i64)).collect());
            if got != want {
                return Err(format!("{label}: array value mismatch"));
            }
        }
        "session_patch_one_change" => {
            let got = codec
                .decode_value(frame)
                .map_err(|e| format!("{label}: decode_value failed: {e}"))?;
            let mut want = Value::Array((0..100).map(|i| Value::I64(i as i64)).collect());
            if let Value::Array(items) = &mut want {
                items[0] = Value::I64(10_000);
            }
            if got != want {
                return Err(format!("{label}: patched array mismatch"));
            }
        }
        other => {
            let msg = codec
                .decode_message(frame)
                .map_err(|e| format!("{label}: decode failed: {e}"))?;
            match other {
                "session_patch_many_changes" => {
                    if !matches!(
                        msg,
                        Message::StatePatch { .. } | Message::TypedVector(_) | Message::Array(_)
                    ) {
                        return Err(format!("{label}: expected patch or array message"));
                    }
                }
                label if label.starts_with("session_patch_iter_") => {
                    if !matches!(
                        msg,
                        Message::StatePatch { .. } | Message::TypedVector(_) | Message::Array(_)
                    ) {
                        return Err(format!("{label}: expected patch or array message"));
                    }
                }
                "session_micro_batch_first" | "session_micro_batch_second" => {
                    let Message::TemplateBatch { count, .. } = msg else {
                        return Err(format!("{label}: expected template batch"));
                    };
                    if count != 4 {
                        return Err(format!("{label}: expected 4 rows, got {count}"));
                    }
                }
                other => return Err(format!("no session expectation for {other}")),
            }
        }
    }
    Ok(())
}

fn main() -> Result<(), String> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| format!("failed to read stdin: {e}"))?;

    let mut codec_stream = TwilicCodec::default();
    let mut session_stream = TwilicCodec::default();
    let mut count = 0usize;

    for (line_no, raw_line) in input.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        let mut parts = line.splitn(3, '|');
        let stream = parts
            .next()
            .ok_or_else(|| format!("line {}: missing stream", line_no + 1))?;
        let label = parts
            .next()
            .ok_or_else(|| format!("line {}: missing label", line_no + 1))?;
        let hex = parts
            .next()
            .ok_or_else(|| format!("line {}: missing hex", line_no + 1))?;

        let bytes = decode_hex(hex)?;
        let decoder = match stream {
            "codec" => &mut codec_stream,
            "session" => &mut session_stream,
            _ => {
                return Err(format!(
                    "line {}: unknown stream '{}', label='{}'",
                    line_no + 1,
                    stream,
                    label
                ))
            }
        };

        match stream {
            "codec" => {
                assert_codec(label, decoder, &bytes)
                    .map_err(|e| format!("line {} ({}): {e}", line_no + 1, label))?;
            }
            "session" => {
                assert_session(label, decoder, &bytes)
                    .map_err(|e| format!("line {} ({}): {e}", line_no + 1, label))?;
            }
            _ => {}
        }
        count += 1;
    }

    if count == 0 {
        return Err("no fixture frames found".to_string());
    }

    println!("Rust client decode and value checks passed for {count} Ruby frames");
    Ok(())
}
