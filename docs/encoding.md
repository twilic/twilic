# Encoding Guide (v3)

This guide covers scalar, reference, vector, Bound, and batch encoding behavior for Twilic v3. It is detailed by encode-time rule so implementations can stay deterministic and interoperable.

## 1. Lengths and IDs

Lengths and ids use varuint for:

- dynamic lengths
- `key_id`, `str_id`, `shape_id`
- `base_id`, `template_id`, and other state ids when session features are enabled

Varuint domains in v3 are used for metadata and for Bound integer fields whose physical encoding is `varuint` or `zigzag_varuint`.

## 2. Scalar Rules

### 2.1 Dynamic integers

- Use fixint for `-32..127` first.
- Otherwise use fixed-width `i8/i16/i32/i64` or `u8/u16/u32/u64`.
- Encoder SHOULD choose smallest valid width.

Recommended width order:

- signed: `fixint` -> `i8` -> `i16` -> `i32` -> `i64`
- unsigned: `fixint` -> `u8` -> `u16` -> `u32` -> `u64`

### 2.2 Bound integers

Bound fields are schema-declared and do not carry per-field type tags.

- Logical aliases `u8/u16/u32/u64` use the unsigned encoding path.
- Logical aliases `i8/i16/i32/i64` use the signed encoding path.
- `min` and `max` validate the domain for every integer encoding.
- `range_bits` stores `value - min` using exactly `ceil(log2(max - min + 1))` bits.
- `varuint` and `zigzag_varuint` remain valid even when `min` and `max` are present, and SHOULD be preferred for wide ranges in single-record streams.
- `fixed_le` stores the logical alias width in little-endian order.
- Out-of-range values MUST fail encode.

### 2.3 Bound booleans and enums

- A boolean field uses 1 bit.
- An enum field with `N` values uses `ceil(log2(N))` bits.
- Enum code order is the schema `enumValues` order.
- Unknown enum values MUST fail encode.
- Presence bits and fixed-bit values SHOULD be packed without per-field byte rounding in Bound streams.

### 2.4 Float

- Dynamic scalar float uses `f64` (`0xC3`).
- Bound `f64` uses 64 bits little-endian.

### 2.5 Strings and Binary

- Dynamic uses `fixstr` for short strings (`<=31` bytes) and `str8/str16/str32` for larger strings.
- Bound non-enum strings use length varuint followed by UTF-8 bytes.
- Binary uses `bin8/bin16/bin32` in Dynamic and length varuint followed by raw bytes in Bound.

Length fields MUST match actual payload byte length exactly.

## 3. Per-Message Interning

### 3.1 Keys

Literal map keys are registered in first-seen order and may be replaced with `key_ref`.

Registration order is part of deterministic behavior and cannot be implementation-random.

### 3.2 String Values

Literal string values are registered in first-seen order and may be replaced with `str_ref`.

Interning state resets at each top-level message boundary.

Unknown `key_ref`/`str_ref` ids MUST fail decode.

### 3.3 Shape IDs

Shape ids are message-local and first-seen assigned when `shape_def` appears. `shape_ref` may only target prior shape ids in the same top-level message.

## 4. Typed Vector Encoding

`typed_vec` payload:

```text
0xDA [element_type][count][codec][payload]
```

Supported numeric/vector codecs include:

- `DIRECT_BITPACK`
- `DELTA_BITPACK`
- `FOR_BITPACK`
- `DELTA_FOR_BITPACK`
- `DELTA_DELTA_BITPACK`
- `RLE`
- `PATCHED_FOR`
- `SIMPLE8B`
- `XOR_FLOAT` for float vectors

Codec choice SHOULD be deterministic for equal input statistics and equal profile configuration.

## 5. Shape-Optimized Arrays

For same-shape map arrays:

- emit one `shape_def`
- emit row values without repeated key literals

This optimization is valid within one message and does not require session state.

Fallback behavior:

- if shape stability is not detected, encode as regular maps
- if unsupported value appears mid-stream, encoder may fall back to generic map/array tags

## 6. Schema-Bound Batches

For repeated records under a shared schema, `schema_batch` is the canonical compact form.

- one column per schema field in schema order
- presence bitmaps use one bit per row
- integer columns use deterministic bit-packing, delta, frame-of-reference, or RLE codecs
- repeated string columns use dictionary or reference codecs when they reduce size
- enum fields use fixed-width schema-derived bits

## 7. Bound Record Streams

For schema-shared record streams, bind schema once and then emit compact record bodies.

- record bodies do not carry schema id, field count, field numbers, field names, type tags, or per-field mode bytes
- optional fields use one presence bit per optional field unless an all-present strategy is declared
- presence bits precede the fixed bit group when optional fields can be absent
- bool, enum, and `range_bits` fields are packed bit-contiguously into the fixed bit group
- varint, string, and binary fields follow in schema order after the fixed bit group byte boundary
- fallback literal encodings are not available inside compact Bound record bodies

`SCHEMA_OBJECT` remains available for independently decodable Bound records, but raw size comparisons against Avro raw streams SHOULD use `BOUND_STREAM` or equivalent external stream framing.

## 8. Determinism

Implementations MUST keep deterministic encode decisions for identical input and state:

- same fix-family selection
- same intern id assignment order
- same vector codec tie-break behavior

Additional deterministic expectations:

- same traversal order for map key emission under the same runtime representation
- same shape id assignment for equivalent arrays
- same fallback threshold behavior when optional codecs are available

## 9. Compatibility Contract

- v3 is a clean break from v2 for Bound Profile field payloads.
- Dynamic Profile may retain v2-compatible tag behavior.
- If multiple versions are supported, select version explicitly outside this encoding layer.
- v3 decoders are not required to decode v2 Bound payloads.

## 10. Encode Error Conditions

Encoders should fail early on:

- integer overflow for selected numeric domain
- unsupported value type for target profile
- invalid reference construction (negative ids, out-of-range ids)
- inconsistent typed vector payload length or codec metadata

Decoders should fail early on:

- unknown `key_ref` / `str_ref` / `shape_ref`
- malformed length fields
- truncated payload
- mismatched container element counts
