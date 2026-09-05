use std::io::{self, Read};

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

fn main() -> Result<(), String> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| format!("failed to read stdin: {e}"))?;

    let mut codec_stream = twilic::TwilicCodec::default();
    let mut session_stream = twilic::TwilicCodec::default();
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

        decoder
            .decode_message(&bytes)
            .map_err(|e| format!("line {} ({}): rust decode failed: {e}", line_no + 1, label))?;
        count += 1;
    }

    if count == 0 {
        return Err("no fixture frames found".to_string());
    }

    println!("Rust client decode succeeded for {count} Zig frames");
    Ok(())
}
