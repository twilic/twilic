use std::fmt;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::de::{self, MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::value::RawValue;
use twilic::model::SchemaField;
use twilic::{
    create_session_encoder, decode, encode, encode_batch, encode_batch_with_schema,
    encode_bound_stream, encode_with_schema, Schema, SessionEncoder, SessionOptions, TwilicError,
    UnknownReferencePolicy, Value,
};

// ── SIMD-JSON helpers ───────────────────────────────────────────────────────
// simd_json::from_slice requires &mut [u8]. Owned JSON strings are converted via
// into_bytes() so simd-json can parse in place without an extra allocation.

/// Parse JSON using simd-json (fast SIMD path). Falls back gracefully since
/// simd_json implements serde's Deserializer trait.
#[inline(always)]
fn simd_from_mut_slice<'de, T: Deserialize<'de>>(bytes: &'de mut [u8]) -> Result<T> {
    simd_json::from_slice(bytes)
        .map_err(|e| BridgeError::new(format!("simd-json parse error: {e}")))
}

pub type Result<T> = std::result::Result<T, BridgeError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeError {
    message: String,
}

impl BridgeError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for BridgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for BridgeError {}

impl From<serde_json::Error> for BridgeError {
    fn from(value: serde_json::Error) -> Self {
        Self::new(format!("invalid json payload: {value}"))
    }
}

impl From<TwilicError> for BridgeError {
    fn from(value: TwilicError) -> Self {
        Self::new(value.to_string())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", content = "v")]
pub enum TransportValue {
    #[serde(rename = "null")]
    Null,
    #[serde(rename = "bool")]
    Bool(bool),
    #[serde(rename = "i64")]
    I64(String),
    #[serde(rename = "u64")]
    U64(String),
    #[serde(rename = "f64")]
    F64(f64),
    #[serde(rename = "string")]
    String(String),
    #[serde(rename = "binary")]
    Binary(String),
    #[serde(rename = "array")]
    Array(Vec<TransportValue>),
    #[serde(rename = "map")]
    Map(Vec<(String, TransportValue)>),
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
enum U64Like {
    Number(u64),
    String(String),
}

impl U64Like {
    fn parse(self, field_name: &'static str) -> Result<u64> {
        match self {
            Self::Number(value) => Ok(value),
            Self::String(raw) => raw
                .parse::<u64>()
                .map_err(|_| BridgeError::new(format!("invalid {field_name}: expected u64"))),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
enum I64Like {
    Number(i64),
    String(String),
}

impl I64Like {
    fn parse(self, field_name: &'static str) -> Result<i64> {
        match self {
            Self::Number(value) => Ok(value),
            Self::String(raw) => raw
                .parse::<i64>()
                .map_err(|_| BridgeError::new(format!("invalid {field_name}: expected i64"))),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransportSchema {
    schema_id: U64Like,
    name: String,
    fields: Vec<TransportSchemaField>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransportSchemaField {
    number: U64Like,
    name: String,
    logical_type: String,
    required: bool,
    #[serde(default)]
    default_value: Option<TransportValue>,
    #[serde(default)]
    min: Option<I64Like>,
    #[serde(default)]
    max: Option<I64Like>,
    #[serde(default)]
    enum_values: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct TransportSessionOptions {
    #[serde(default)]
    max_base_snapshots: Option<usize>,
    #[serde(default)]
    enable_state_patch: Option<bool>,
    #[serde(default)]
    enable_template_batch: Option<bool>,
    #[serde(default)]
    enable_trained_dictionary: Option<bool>,
    #[serde(default)]
    unknown_reference_policy: Option<String>,
}

pub fn encode_transport_json(value_json: String) -> Result<Vec<u8>> {
    let mut bytes = value_json.into_bytes();
    let transport: TransportValue = simd_from_mut_slice(&mut bytes)?;
    let value = transport_to_value(transport)?;
    encode(&value).map_err(Into::into)
}

pub fn decode_to_transport_json(bytes: &[u8]) -> Result<String> {
    let value = decode(bytes)?;
    let transport = value_to_transport(value);
    serde_json::to_string(&transport).map_err(Into::into)
}

pub fn decode_to_compact_json(bytes: &[u8]) -> Result<String> {
    let value = decode(bytes)?;
    let mut out = String::with_capacity(256);
    value_to_compact_json_str(&value, &mut out);
    Ok(out)
}

pub fn encode_with_schema_transport_json(
    schema_json: String,
    value_json: String,
) -> Result<Vec<u8>> {
    let schema = parse_schema_json(schema_json)?;
    let mut vbytes = value_json.into_bytes();
    let transport: TransportValue = simd_from_mut_slice(&mut vbytes)?;
    let value = transport_to_value(transport)?;
    encode_with_schema(&schema, &value).map_err(Into::into)
}

pub fn encode_batch_transport_json(values_json: String) -> Result<Vec<u8>> {
    let mut bytes = values_json.into_bytes();
    let transports: Vec<TransportValue> = simd_from_mut_slice(&mut bytes)?;
    let values: Vec<Value> = transports
        .into_iter()
        .map(transport_to_value)
        .collect::<Result<Vec<_>>>()?;
    encode_batch(&values).map_err(Into::into)
}

pub fn encode_bound_stream_transport_json(
    schema_json: String,
    values_json: String,
) -> Result<Vec<u8>> {
    let schema = parse_schema_json(schema_json)?;
    let values = parse_transport_values_json(values_json)?;
    encode_bound_stream(&schema, &values).map_err(Into::into)
}

pub fn encode_batch_with_schema_transport_json(
    schema_json: String,
    values_json: String,
) -> Result<Vec<u8>> {
    let schema = parse_schema_json(schema_json)?;
    let values = parse_transport_values_json(values_json)?;
    encode_batch_with_schema(&schema, &values).map_err(Into::into)
}

pub struct BridgeSessionEncoder {
    inner: SessionEncoder,
}

impl BridgeSessionEncoder {
    pub fn new(options_json: Option<&str>) -> Result<Self> {
        let options = parse_session_options_json(options_json)?;
        Ok(Self {
            inner: create_session_encoder(options),
        })
    }

    pub fn encode_transport_json(&mut self, value_json: String) -> Result<Vec<u8>> {
        let mut bytes = value_json.into_bytes();
        let transport: TransportValue = simd_from_mut_slice(&mut bytes)?;
        let value = transport_to_value(transport)?;
        self.inner.encode(&value).map_err(Into::into)
    }

    pub fn encode_with_schema_transport_json(
        &mut self,
        schema_json: String,
        value_json: String,
    ) -> Result<Vec<u8>> {
        let schema = parse_schema_json(schema_json)?;
        let mut vbytes = value_json.into_bytes();
        let transport: TransportValue = simd_from_mut_slice(&mut vbytes)?;
        let value = transport_to_value(transport)?;
        self.inner
            .encode_with_schema(&schema, &value)
            .map_err(Into::into)
    }

    pub fn encode_batch_transport_json(&mut self, values_json: String) -> Result<Vec<u8>> {
        let values = parse_transport_values_json(values_json)?;
        self.inner.encode_batch(&values).map_err(Into::into)
    }

    pub fn encode_bound_stream_transport_json(
        &mut self,
        schema_json: String,
        values_json: String,
    ) -> Result<Vec<u8>> {
        let schema = parse_schema_json(schema_json)?;
        let values = parse_transport_values_json(values_json)?;
        self.inner
            .encode_bound_stream(&schema, &values)
            .map_err(Into::into)
    }

    pub fn encode_batch_with_schema_transport_json(
        &mut self,
        schema_json: String,
        values_json: String,
    ) -> Result<Vec<u8>> {
        let schema = parse_schema_json(schema_json)?;
        let values = parse_transport_values_json(values_json)?;
        self.inner
            .encode_batch_with_schema(&schema, &values)
            .map_err(Into::into)
    }

    pub fn encode_patch_transport_json(&mut self, value_json: String) -> Result<Vec<u8>> {
        let mut bytes = value_json.into_bytes();
        let transport: TransportValue = simd_from_mut_slice(&mut bytes)?;
        let value = transport_to_value(transport)?;
        self.inner.encode_patch(&value).map_err(Into::into)
    }

    pub fn encode_micro_batch_transport_json(&mut self, values_json: String) -> Result<Vec<u8>> {
        let mut bytes = values_json.into_bytes();
        let transports: Vec<TransportValue> = simd_from_mut_slice(&mut bytes)?;
        let values: Vec<Value> = transports
            .into_iter()
            .map(transport_to_value)
            .collect::<Result<Vec<_>>>()?;
        self.inner.encode_micro_batch(&values).map_err(Into::into)
    }

    pub fn reset(&mut self) {
        self.inner.reset();
    }
}

fn parse_schema_json(schema_json: String) -> Result<Schema> {
    let mut bytes = schema_json.into_bytes();
    let schema: TransportSchema = simd_from_mut_slice(&mut bytes)?;
    transport_schema_to_schema(schema)
}

fn parse_transport_values_json(values_json: String) -> Result<Vec<Value>> {
    let mut bytes = values_json.into_bytes();
    let transports: Vec<TransportValue> = simd_from_mut_slice(&mut bytes)?;
    transports
        .into_iter()
        .map(transport_to_value)
        .collect::<Result<Vec<_>>>()
}

fn parse_session_options_json(options_json: Option<&str>) -> Result<SessionOptions> {
    let Some(raw) = options_json else {
        return Ok(SessionOptions::default());
    };
    // Session options parsing is cold path, use serde_json
    let options: TransportSessionOptions = serde_json::from_str(raw)?;
    transport_session_options_to_options(options)
}

fn transport_schema_to_schema(schema: TransportSchema) -> Result<Schema> {
    let schema_id = schema.schema_id.parse("schemaId")?;
    let fields = schema
        .fields
        .into_iter()
        .map(|field| {
            Ok(SchemaField {
                number: field.number.parse("field.number")?,
                name: field.name,
                logical_type: field.logical_type,
                required: field.required,
                default_value: field.default_value.map(transport_to_value).transpose()?,
                min: field.min.map(|v| v.parse("field.min")).transpose()?,
                max: field.max.map(|v| v.parse("field.max")).transpose()?,
                enum_values: field.enum_values,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(Schema {
        schema_id,
        name: schema.name,
        fields,
    })
}

fn transport_session_options_to_options(
    options: TransportSessionOptions,
) -> Result<SessionOptions> {
    let mut parsed = SessionOptions::default();
    if let Some(value) = options.max_base_snapshots {
        parsed.max_base_snapshots = value;
    }
    if let Some(value) = options.enable_state_patch {
        parsed.enable_state_patch = value;
    }
    if let Some(value) = options.enable_template_batch {
        parsed.enable_template_batch = value;
    }
    if let Some(value) = options.enable_trained_dictionary {
        parsed.enable_trained_dictionary = value;
    }
    if let Some(policy) = options.unknown_reference_policy {
        parsed.unknown_reference_policy = parse_unknown_reference_policy(&policy)?;
    }
    Ok(parsed)
}

fn parse_unknown_reference_policy(value: &str) -> Result<UnknownReferencePolicy> {
    match value {
        "failFast" | "fail_fast" | "FailFast" => Ok(UnknownReferencePolicy::FailFast),
        "statelessRetry" | "stateless_retry" | "StatelessRetry" => {
            Ok(UnknownReferencePolicy::StatelessRetry)
        }
        _ => Err(BridgeError::new(
            "unknownReferencePolicy must be failFast or statelessRetry",
        )),
    }
}

// ── Direct API (bypasses JSON string intermediate) ──────────────────────────

pub fn encode_direct(transport: TransportValue) -> Result<Vec<u8>> {
    let value = transport_to_value(transport)?;
    encode(&value).map_err(Into::into)
}

pub fn encode_direct_from_json(jv: serde_json::Value) -> Result<Vec<u8>> {
    let value = parse_value_from_json_value(jv)?;
    encode(&value).map_err(Into::into)
}

pub fn decode_direct(bytes: &[u8]) -> Result<TransportValue> {
    let value = decode(bytes)?;
    Ok(value_to_transport(value))
}

pub fn encode_batch_direct(transports: Vec<TransportValue>) -> Result<Vec<u8>> {
    let values: Vec<Value> = transports
        .into_iter()
        .map(transport_to_value)
        .collect::<Result<Vec<_>>>()?;
    encode_batch(&values).map_err(Into::into)
}

pub fn encode_batch_direct_from_json(jv: serde_json::Value) -> Result<Vec<u8>> {
    let values = parse_values_from_json_value(jv)?;
    encode_batch(&values).map_err(Into::into)
}

/// Encode a batch from a pre-converted Vec<Value> (conversion happens in NAPI layer).
pub fn encode_batch_native_raw(values: Vec<Value>) -> Result<Vec<u8>> {
    encode_batch(&values).map_err(Into::into)
}

impl BridgeSessionEncoder {
    pub fn encode_direct(&mut self, transport: TransportValue) -> Result<Vec<u8>> {
        let value = transport_to_value(transport)?;
        self.inner.encode(&value).map_err(Into::into)
    }

    pub fn encode_direct_from_json(&mut self, jv: serde_json::Value) -> Result<Vec<u8>> {
        let value = parse_value_from_json_value(jv)?;
        self.inner.encode(&value).map_err(Into::into)
    }

    pub fn encode_batch_direct(&mut self, transports: Vec<TransportValue>) -> Result<Vec<u8>> {
        let values: Vec<Value> = transports
            .into_iter()
            .map(transport_to_value)
            .collect::<Result<Vec<_>>>()?;
        self.inner.encode_batch(&values).map_err(Into::into)
    }

    pub fn encode_batch_direct_from_json(&mut self, jv: serde_json::Value) -> Result<Vec<u8>> {
        let values = parse_values_from_json_value(jv)?;
        self.inner.encode_batch(&values).map_err(Into::into)
    }

    pub fn encode_patch_direct(&mut self, transport: TransportValue) -> Result<Vec<u8>> {
        let value = transport_to_value(transport)?;
        self.inner.encode_patch(&value).map_err(Into::into)
    }

    pub fn encode_patch_direct_from_json(&mut self, jv: serde_json::Value) -> Result<Vec<u8>> {
        let value = parse_value_from_json_value(jv)?;
        self.inner.encode_patch(&value).map_err(Into::into)
    }

    pub fn encode_micro_batch_direct(
        &mut self,
        transports: Vec<TransportValue>,
    ) -> Result<Vec<u8>> {
        let values: Vec<Value> = transports
            .into_iter()
            .map(transport_to_value)
            .collect::<Result<Vec<_>>>()?;
        self.inner.encode_micro_batch(&values).map_err(Into::into)
    }

    pub fn encode_micro_batch_direct_from_json(
        &mut self,
        jv: serde_json::Value,
    ) -> Result<Vec<u8>> {
        let values = parse_values_from_json_value(jv)?;
        self.inner.encode_micro_batch(&values).map_err(Into::into)
    }
}

fn transport_to_value(value: TransportValue) -> Result<Value> {
    match value {
        TransportValue::Null => Ok(Value::Null),
        TransportValue::Bool(v) => Ok(Value::Bool(v)),
        TransportValue::I64(raw) => raw
            .parse::<i64>()
            .map(Value::I64)
            .map_err(|_| BridgeError::new("invalid i64 value")),
        TransportValue::U64(raw) => raw
            .parse::<u64>()
            .map(Value::U64)
            .map_err(|_| BridgeError::new("invalid u64 value")),
        TransportValue::F64(v) => Ok(Value::F64(v)),
        TransportValue::String(v) => Ok(Value::String(v)),
        TransportValue::Binary(raw) => BASE64
            .decode(raw)
            .map(Value::Binary)
            .map_err(|_| BridgeError::new("invalid base64 binary payload")),
        TransportValue::Array(values) => values
            .into_iter()
            .map(transport_to_value)
            .collect::<Result<Vec<_>>>()
            .map(Value::Array),
        TransportValue::Map(entries) => entries
            .into_iter()
            .map(|(k, v)| transport_to_value(v).map(|vv| (k, vv)))
            .collect::<Result<Vec<_>>>()
            .map(Value::Map),
    }
}

fn value_to_transport(value: Value) -> TransportValue {
    match value {
        Value::Null => TransportValue::Null,
        Value::Bool(v) => TransportValue::Bool(v),
        Value::I64(v) => TransportValue::I64(v.to_string()),
        Value::U64(v) => TransportValue::U64(v.to_string()),
        Value::F64(v) => TransportValue::F64(v),
        Value::String(v) => TransportValue::String(v),
        Value::Binary(v) => TransportValue::Binary(BASE64.encode(v)),
        Value::Array(values) => {
            TransportValue::Array(values.into_iter().map(value_to_transport).collect())
        }
        Value::Map(entries) => TransportValue::Map(
            entries
                .into_iter()
                .map(|(k, v)| (k, value_to_transport(v)))
                .collect(),
        ),
    }
}

// ── Compact transport format ────────────────────────────────────────────────
//
// Tags: 0=null, 1=bool, 2=i64, 3=u64, 4=f64, 5=string, 6=binary, 7=array, 8=map
// Format: [tag] for null, [tag, value] for everything else.
// Map value is a flat array: [key1, val1, key2, val2, ...]
//
// Uses a custom serde Deserialize impl for single-pass JSON → Value conversion.

/// Serialize a twilic::Value to compact JSON format, writing directly to a String.
/// This avoids building any intermediate serde or transport objects.
fn value_to_compact_json_str(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("[0]"),
        Value::Bool(true) => out.push_str("[1,true]"),
        Value::Bool(false) => out.push_str("[1,false]"),
        Value::I64(v) => {
            out.push_str("[2,\"");
            let mut buf = itoa::Buffer::new();
            out.push_str(buf.format(*v));
            out.push_str("\"]");
        }
        Value::U64(v) => {
            out.push_str("[3,\"");
            let mut buf = itoa::Buffer::new();
            out.push_str(buf.format(*v));
            out.push_str("\"]");
        }
        Value::F64(v) => {
            out.push_str("[4,");
            // Use ryu for fast f64 formatting
            let mut buf = ryu::Buffer::new();
            out.push_str(buf.format(*v));
            out.push(']');
        }
        Value::String(s) => {
            out.push_str("[5,");
            // JSON-escape the string
            write_json_string(s, out);
            out.push(']');
        }
        Value::Binary(b) => {
            out.push_str("[6,\"");
            out.push_str(&BASE64.encode(b));
            out.push_str("\"]");
        }
        Value::Array(items) => {
            out.push_str("[7,[");
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                value_to_compact_json_str(item, out);
            }
            out.push_str("]]");
        }
        Value::Map(entries) => {
            out.push_str("[8,[");
            for (i, (key, val)) in entries.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json_string(key, out);
                out.push(',');
                value_to_compact_json_str(val, out);
            }
            out.push_str("]]");
        }
    }
}

/// Write a JSON-escaped string (with surrounding quotes) to the output.
/// Optimized for the common case of ASCII strings with no special characters.
#[inline]
fn write_json_string(s: &str, out: &mut String) {
    out.push('"');
    let bytes = s.as_bytes();
    let mut start = 0;
    for (i, &b) in bytes.iter().enumerate() {
        let escape = match b {
            b'"' => "\\\"",
            b'\\' => "\\\\",
            b'\n' => "\\n",
            b'\r' => "\\r",
            b'\t' => "\\t",
            b if b < 0x20 => {
                // Flush any buffered bytes
                if start < i {
                    out.push_str(&s[start..i]);
                }
                // Write \u00XX escape
                static HEX: &[u8; 16] = b"0123456789abcdef";
                let hi = HEX[(b >> 4) as usize] as char;
                let lo = HEX[(b & 0xf) as usize] as char;
                out.push_str("\\u00");
                out.push(hi);
                out.push(lo);
                start = i + 1;
                continue;
            }
            _ => {
                continue;
            }
        };
        // Flush any buffered bytes before the escape
        if start < i {
            out.push_str(&s[start..i]);
        }
        out.push_str(escape);
        start = i + 1;
    }
    // Flush remaining
    if start < bytes.len() {
        out.push_str(&s[start..]);
    }
    out.push('"');
}

struct CompactValue(Value);

impl<'de> Deserialize<'de> for CompactValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        deserializer
            .deserialize_seq(CompactValueVisitor)
            .map(CompactValue)
    }
}

struct CompactValueVisitor;

impl<'de> Visitor<'de> for CompactValueVisitor {
    type Value = Value;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a compact value array [tag, value?]")
    }

    fn visit_seq<A: de::SeqAccess<'de>>(self, mut seq: A) -> std::result::Result<Value, A::Error> {
        let tag: u64 = seq
            .next_element()?
            .ok_or_else(|| de::Error::custom("compact value missing tag"))?;

        match tag {
            0 => {
                // null — no content element
                Ok(Value::Null)
            }
            1 => {
                // bool
                let v: bool = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact bool missing value"))?;
                Ok(Value::Bool(v))
            }
            2 => {
                // i64 (as string)
                let s: &str = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact i64 missing value"))?;
                let v: i64 = s
                    .parse()
                    .map_err(|_| de::Error::custom("compact i64 invalid"))?;
                Ok(Value::I64(v))
            }
            3 => {
                // u64 (as string)
                let s: &str = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact u64 missing value"))?;
                let v: u64 = s
                    .parse()
                    .map_err(|_| de::Error::custom("compact u64 invalid"))?;
                Ok(Value::U64(v))
            }
            4 => {
                // f64
                let v: f64 = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact f64 missing value"))?;
                Ok(Value::F64(v))
            }
            5 => {
                // string
                let v: String = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact string missing value"))?;
                Ok(Value::String(v))
            }
            6 => {
                // binary (base64)
                let encoded: &str = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact binary missing value"))?;
                let bytes = BASE64
                    .decode(encoded)
                    .map_err(|_| de::Error::custom("compact binary invalid base64"))?;
                Ok(Value::Binary(bytes))
            }
            7 => {
                // array of CompactValues
                let items: Vec<CompactValue> = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact array missing value"))?;
                Ok(Value::Array(items.into_iter().map(|v| v.0).collect()))
            }
            8 => {
                // map: flat array [key1, val1, key2, val2, ...]
                // We deserialize this as a custom visitor that reads alternating string/CompactValue pairs
                let entries: CompactMapEntries = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::custom("compact map missing value"))?;
                Ok(Value::Map(entries.0))
            }
            _ => Err(de::Error::custom(format!("compact unknown tag: {tag}"))),
        }
    }
}

/// Deserializes a flat array [key1, val1, key2, val2, ...] into Vec<(String, Value)>
struct CompactMapEntries(Vec<(String, Value)>);

impl<'de> Deserialize<'de> for CompactMapEntries {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        deserializer.deserialize_seq(CompactMapEntriesVisitor)
    }
}

struct CompactMapEntriesVisitor;

impl<'de> Visitor<'de> for CompactMapEntriesVisitor {
    type Value = CompactMapEntries;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a flat array of alternating key/value pairs")
    }

    fn visit_seq<A: de::SeqAccess<'de>>(
        self,
        mut seq: A,
    ) -> std::result::Result<CompactMapEntries, A::Error> {
        let mut entries = Vec::with_capacity(seq.size_hint().unwrap_or(0) / 2);
        loop {
            let key: Option<String> = seq.next_element()?;
            let Some(key) = key else { break };
            let val: CompactValue = seq
                .next_element()?
                .ok_or_else(|| de::Error::custom("compact map missing value for key"))?;
            entries.push((key, val.0));
        }
        Ok(CompactMapEntries(entries))
    }
}

fn parse_compact_str(json: &mut [u8]) -> Result<Value> {
    let compact: CompactValue = simd_json::from_slice(json)
        .map_err(|e| BridgeError::new(format!("simd-json compact parse error: {e}")))?;
    Ok(compact.0)
}

fn parse_compact_batch_str(json: &mut [u8]) -> Result<Vec<Value>> {
    let items: Vec<CompactValue> = simd_json::from_slice(json)
        .map_err(|e| BridgeError::new(format!("simd-json compact batch parse error: {e}")))?;
    Ok(items.into_iter().map(|v| v.0).collect())
}

pub fn encode_compact_json(json: String) -> Result<Vec<u8>> {
    let mut bytes = json.into_bytes();
    let value = parse_compact_str(&mut bytes)?;
    encode(&value).map_err(Into::into)
}

pub fn encode_batch_compact_json(json: String) -> Result<Vec<u8>> {
    let mut bytes = json.into_bytes();
    let values = parse_compact_batch_str(&mut bytes)?;
    encode_batch(&values).map_err(Into::into)
}

impl BridgeSessionEncoder {
    pub fn encode_compact_json(&mut self, json: String) -> Result<Vec<u8>> {
        let mut bytes = json.into_bytes();
        let value = parse_compact_str(&mut bytes)?;
        self.inner.encode(&value).map_err(Into::into)
    }

    pub fn encode_batch_compact_json(&mut self, json: String) -> Result<Vec<u8>> {
        let mut bytes = json.into_bytes();
        let values = parse_compact_batch_str(&mut bytes)?;
        self.inner.encode_batch(&values).map_err(Into::into)
    }

    pub fn encode_patch_compact_json(&mut self, json: String) -> Result<Vec<u8>> {
        let mut bytes = json.into_bytes();
        let value = parse_compact_str(&mut bytes)?;
        self.inner.encode_patch(&value).map_err(Into::into)
    }

    pub fn encode_micro_batch_compact_json(&mut self, json: String) -> Result<Vec<u8>> {
        let mut bytes = json.into_bytes();
        let values = parse_compact_batch_str(&mut bytes)?;
        self.inner.encode_micro_batch(&values).map_err(Into::into)
    }
}
//
// Deserializes the transport JSON format directly into twilic::Value,
// skipping the TransportValue intermediate entirely. This avoids:
// 1. Allocating TransportValue tree
// 2. Walking the tree a second time in transport_to_value()
// 3. String allocations for i64/u64 intermediates

struct FastValueVisitor;

impl<'de> Visitor<'de> for FastValueVisitor {
    type Value = Value;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a transport value object with 't' and optional 'v' fields")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> std::result::Result<Value, A::Error> {
        let mut tag: Option<String> = None;
        let mut content_value: Option<Box<RawValue>> = None;

        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "t" => {
                    tag = Some(map.next_value()?);
                }
                "v" => {
                    content_value = Some(map.next_value()?);
                }
                _ => {
                    map.next_value::<serde::de::IgnoredAny>()?;
                }
            }
        }

        let tag = tag.ok_or_else(|| de::Error::missing_field("t"))?;

        match tag.as_str() {
            "null" => Ok(Value::Null),
            "bool" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let v: bool = serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                Ok(Value::Bool(v))
            }
            "i64" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let s: &str = serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                let v: i64 = s.parse().map_err(|_| de::Error::custom("invalid i64"))?;
                Ok(Value::I64(v))
            }
            "u64" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let s: &str = serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                let v: u64 = s.parse().map_err(|_| de::Error::custom("invalid u64"))?;
                Ok(Value::U64(v))
            }
            "f64" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let v: f64 = serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                Ok(Value::F64(v))
            }
            "string" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let v: String = serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                Ok(Value::String(v))
            }
            "binary" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let encoded: String = serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                let bytes = BASE64
                    .decode(&encoded)
                    .map_err(|_| de::Error::custom("invalid base64"))?;
                Ok(Value::Binary(bytes))
            }
            "array" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let items: Vec<FastValue> =
                    serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                Ok(Value::Array(items.into_iter().map(|v| v.0).collect()))
            }
            "map" => {
                let raw = content_value.ok_or_else(|| de::Error::missing_field("v"))?;
                let entries: Vec<(String, FastValue)> =
                    serde_json::from_str(raw.get()).map_err(de::Error::custom)?;
                Ok(Value::Map(
                    entries.into_iter().map(|(k, v)| (k, v.0)).collect(),
                ))
            }
            other => Err(de::Error::unknown_variant(
                other,
                &[
                    "null", "bool", "i64", "u64", "f64", "string", "binary", "array", "map",
                ],
            )),
        }
    }
}

/// A newtype wrapper around `Value` that implements `Deserialize` using the
/// fast single-pass visitor that converts transport JSON directly to `Value`.
struct FastValue(Value);

impl<'de> Deserialize<'de> for FastValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        deserializer
            .deserialize_map(FastValueVisitor)
            .map(FastValue)
    }
}

/// Parse a serde_json::Value transport representation directly into twilic::Value.
fn parse_value_from_json_value(jv: serde_json::Value) -> Result<Value> {
    let fast: FastValue = serde_json::from_value(jv)?;
    Ok(fast.0)
}

/// Parse a serde_json::Value array of transport values.
fn parse_values_from_json_value(jv: serde_json::Value) -> Result<Vec<Value>> {
    let items: Vec<FastValue> = serde_json::from_value(jv)?;
    Ok(items.into_iter().map(|v| v.0).collect())
}
