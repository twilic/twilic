use twilic::model::{ControlStreamCodec, Message, MessageKind};
use twilic::wire::encode_bytes;
use twilic::TwilicCodec;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: control_stream_decode <codec> <hex>");
        std::process::exit(2);
    }
    let codec = match args[1].as_str() {
        "plain" => ControlStreamCodec::Plain,
        "rle" => ControlStreamCodec::Rle,
        "bitpack" => ControlStreamCodec::Bitpack,
        "huffman" => ControlStreamCodec::Huffman,
        "fse" => ControlStreamCodec::Fse,
        other => {
            eprintln!("unknown codec: {other}");
            std::process::exit(2);
        }
    };
    let encoded = decode_hex(&args[2]).expect("hex");
    let mut wire = vec![MessageKind::ControlStream as u8];
    wire.push(codec as u8);
    encode_bytes(&encoded, &mut wire);
    let mut twilic_codec = TwilicCodec::default();
    let msg = twilic_codec
        .decode_message(&wire)
        .expect("decode control stream message");
    let payload = match msg {
        Message::ControlStream { payload, .. } => payload,
        _ => panic!("expected control stream"),
    };
    print!("{}", encode_hex(&payload));
}

fn decode_hex(s: &str) -> Result<Vec<u8>, String> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return Err("odd hex length".into());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect()
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}
