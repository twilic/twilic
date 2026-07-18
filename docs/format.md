# Format Guide (v3)

This document describes the Twilic v3 wire layout in practical terms. It mirrors the normative rules in `SPEC.md`, but keeps the focus on byte structure and decode shape.

## 1. Wire Model Overview

v3 uses profile-specific wire models. Dynamic Profile uses the compact tag-table model. Bound and Batch Profiles use message-kind envelopes when self-delimiting payloads are needed. `BOUND_STREAM` (`0x0F`) binds a schema for compact record streams, and `SCHEMA_BATCH` (`0x0E`) is the schema-aware columnar form.

A decoder MUST know the active profile before interpreting byte 0. Dynamic `row_batch`/`col_batch` use `0xDB`/`0xDC`; envelope `ROW_BATCH`/`COLUMN_BATCH` use `0x06`/`0x07`.

In the v3 reference profile, Bound/Batch byte-0 values outside `0x00..0x0F` are reserved and fail decode unless negotiated.

### 1.1 First-byte compact families

- `0x00..0x7F`: positive fixint (`0..127`)
- `0x80..0x9F`: fixstr (`len=0..31`)
- `0xA0..0xAF`: fixarray (`count=0..15`)
- `0xB0..0xBF`: fixmap (`count=0..15`)
- `0xE0..0xFF`: negative fixint (`-32..-1`)

### 1.2 Extended tags (`0xC0..0xDF`)

| Tag / Range  | Meaning           |
| ------------ | ----------------- |
| `0xC0`       | null              |
| `0xC1`       | false             |
| `0xC2`       | true              |
| `0xC3`       | float64 LE        |
| `0xC4..0xC7` | u8/u16/u32/u64    |
| `0xC8..0xCB` | i8/i16/i32/i64    |
| `0xCC..0xCE` | bin8/bin16/bin32  |
| `0xCF..0xD1` | str8/str16/str32  |
| `0xD2..0xD3` | array16/array32   |
| `0xD4..0xD5` | map16/map32       |
| `0xD6`       | `shape_def`       |
| `0xD7`       | `shape_ref`       |
| `0xD8`       | `key_ref`         |
| `0xD9`       | `str_ref`         |
| `0xDA`       | `typed_vec`       |
| `0xDB`       | `row_batch`       |
| `0xDC`       | `col_batch`       |
| `0xDD`       | `state_patch`     |
| `0xDE`       | `template_batch`  |
| `0xDF`       | extension (`ext`) |

## 2. Dynamic Container Shapes

### 2.1 Map body

Canonical map payload:

```text
[fixmap|map16|map32][key][value]...
```

Key representations:

- key literal (`fixstr` / `str8` / `str16` / `str32`)
- `key_ref`: `0xD8 [varuint key_id]`

Unknown `key_ref` id is a hard decode error.

### 2.2 Array body

Canonical array payload:

```text
[fixarray|array16|array32][value_0][value_1]...
```

Array may remain generic, or be promoted to:

- `typed_vec` for homogeneous primitive arrays
- shape forms for homogeneous map arrays

## 3. Message-Local Reuse Forms

Dynamic Profile does not require session state for structural reuse in one message.

### 3.1 `shape_def` (`0xD6`)

Defines an ordered key sequence and registers `shape_id` in the current message.

```text
0xD6 [shape_id][key_count][key_0]...[key_n]
```

`shape_def` is a declaration, not a decoded application value. In array bodies, declarations may appear before elements and do not count toward decoded array element count.

### 3.2 `shape_ref` (`0xD7`)

References prior shape in the current message and encodes only values.

```text
0xD7 [shape_id][value_0]...[value_n]
```

Unknown `shape_ref` id is a decode error.

### 3.3 `key_ref` / `str_ref`

- `key_ref` (`0xD8`) references key literals already emitted in the message.
- `str_ref` (`0xD9`) references string value literals already emitted in the message.

All intern tables (`key_id`, `str_id`, `shape_id`) reset at each top-level message boundary.

## 4. Batch and Stateful Forms

### 4.0 Bound object

`SCHEMA_OBJECT` (`0x04`) is the independently decodable Bound object form when the resolved schema is known:

```text
0x04 [has_schema_id][schema_id?][has_presence][presence bytes?][field payloads...]
```

`has_schema_id` and `has_presence` are one-byte flags: `0x00 = false`, `0x01 = true`; other values fail decode. Field payloads are in schema order. Absent optional fields emit no payload. Variable-width fields are self-delimiting by length or varuint termination.

Compact `SCHEMA_OBJECT` field payloads use `[fixed bit group][byte payloads...]` after presence bytes, following compact record-body bit order and padding rules.

### 4.1 Dynamic batch

- `0xDB`: `row_batch`
- `0xDC`: `col_batch`

Both remain optional Dynamic forms.

### 4.2 Bound batch

`SCHEMA_BATCH` (`0x0E`) is the schema-aware columnar batch form:

```text
0x0E [schema_id?][count][column_count?][columns...]
```

`schema_id` is omitted only when the enclosing context uniquely binds the schema. The profile predeclares whether `column_count` and `field_id` are present. Each column carries optional schema field id, null strategy, codec, and typed vector payload. `field_id` may be omitted in strict schema-order compact mode. `null_strategy` values are `0 = all present`, `1 = normal bitmap`, `2 = inverted bitmap`. Presence bitmaps use row order, least-significant-bit first, with zero padding. Nullable column payloads encode present values only.

The v3 reference profile includes `column_count` and omits `field_id` in strict schema-order compact mode.

### 4.3 Bound stream

`BOUND_STREAM` (`0x0F`) is the schema-bound compact stream form:

```text
0x0F [schema_id?][count?][presence_strategy][record_body...]
```

The enclosing profile predeclares whether `schema_id` and `count` are present. If schema id and count are supplied by the transport or benchmark harness, they are external framing and are not part of raw record-body bytes. Each record body is decoded using schema order:

The v3 reference profile includes `schema_id` and `count` unless an enclosing transport/profile explicitly declares external schema identity and framing.

If `count` is omitted, external framing MUST supply record count, byte extent, or terminal end-of-stream. Multiplexed/framed transports MUST provide count or byte extent. `presence_strategy` values are `0 = normal bitmap per record`, `1 = inverted bitmap per record`, `2 = all-present elided`.

```text
[presence bits?][fixed bit group][byte payloads...]
```

Presence is bit-packed before the fixed bit group when optional fields can be absent. Presence bits are least-significant-bit first in schema optional-field order and are zero-padded to a byte boundary. The fixed bit group packs bool, enum, and `range_bits` fields bit-contiguously, least-significant-bit first in schema order. Byte payloads contain `fixed_le`, float, varints, strings, binary values, and other byte-aligned fields in schema order. Non-zero padding bits fail decode.

### 4.4 Stateful

- `0xDD`: `state_patch`
- `0xDE`: `template_batch`

These forms may carry session references (`base_id`, `template_id`, dictionary ids) and therefore require transport-level state agreement.

## 5. Informative Encode Promotion Flow

Typical encoder decisions:

1. Emit fix families whenever representable.
2. Register key/string literals in message-local tables.
3. Replace repeats with `key_ref`/`str_ref`.
4. Detect homogeneous map arrays and emit `shape_def` plus value rows.
5. Promote homogeneous primitive arrays to `typed_vec`.
6. Use Bound bitstream fields when a shared schema is provided.
7. Use `BOUND_STREAM` when repeated schema-bound records are compared against raw Avro or unframed Protocol Buffers streams.
8. Use `SCHEMA_BATCH` for repeated records with the same schema when columnar gains are available.
9. Use stateful forms only when session guarantees exist.

## 6. Compatibility and Versioning

- v3 is a clean break from v2 for Bound Profile field/record-body payloads.
- Dynamic Profile may remain v2-compatible where tags are unchanged.
- Implementations supporting multiple profiles or versions MUST use an explicit external profile and version discriminator; payload auto-detection is not defined.
