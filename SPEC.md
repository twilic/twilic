# Twilic Specification v3

## 1. Purpose

This specification defines a binary format that keeps MessagePack-like usability while providing schema-bound and batch payloads designed to be competitive with Protocol Buffers and Avro on explicitly benchmarked schema-fixed workloads.

- Objects with the same shape appear repeatedly.
- Messages under the same schema appear repeatedly.
- Repeated strings and similar strings are common.
- Homogeneous arrays and typed vectors are common.
- Multiple records with the same schema can be sent together.
- Optional-field distributions and integer series are biased.

The goal is to combine self-describing, schema-less convenience with the compression efficiency of schema-aware, columnar, dictionary, and bit-packing approaches in a single format family. v3 additionally targets fast native encode/decode paths that do not require intermediate JSON text.

This specification does not claim that every arbitrary self-describing JSON value can be smaller than a schema-first format. Dynamic Profile must carry structural information sufficient to decode without an external schema. The comparable benchmark targets are:

- Dynamic targets smaller output than MessagePack on repeated keys, repeated strings, homogeneous arrays, and same-shape object arrays.
- Bound targets comparable output to Protocol Buffers and Avro on schema-fixed single-record streams.
- Batch targets smaller output than Protocol Buffers and Avro on homogeneous repeated-record payloads where columnar codecs apply.

---

## 2. Design Principles

This specification follows these principles.

1. **Usable through the same API family**
   - Provide a dynamic mode that can encode/decode arbitrary values as-is.
   - Allow promotion to compact mode when a schema is provided.
   - Implementations may expose separate convenience APIs for schema, stream, batch, and session modes.

2. **Deferred optimization**
   - The first transmission may be self-describing.
   - Once repeated shape/key set/string/field distribution is observed, automatically switch to a more compact representation.

3. **Minimize one-shot cost**
   - Do not introduce excessive control metadata for small one-shot values.
   - Control information used for learning or dictionaries must be local and recoverable.

4. **Win on repetition**
   - shape interning
   - key interning
   - string interning
   - typed vector
   - columnar batch
   - delta / frame-of-reference / dictionary / RLE

5. **Deterministic wire format**
   - Under the same profile and learning state, the same value maps to the same bytes.

6. **Optional stateful optimization**
   - Stateless one-shot messages remain directly usable.
   - Stateful patching/shared dictionary/template reuse can be used only when a session or channel exists.
   - Receivers that do not use stateful mode must still be able to fall back to stateless mode.

7. **Fast paths without intermediate text**
   - Native implementations SHOULD encode directly from runtime values.
   - JSON text serialization is a compatibility path, not the required hot path.
   - Fast paths MUST preserve decode depth, count, byte-length, and decoded-output limits.

---

## 3. Profiles

This specification defines three primary data profiles and one optional Stateful Profile.

### 3.1 Dynamic Profile

A MessagePack-like profile.

- Any root value can be sent.
- No schema definition is required.
- Map/list/scalar/binary/string can be represented directly.
- If message-local shape/key/string reuse is possible, compact forms may be used automatically.
- Otherwise, fall back to self-describing forms.

### 3.2 Bound Profile

A profile based on a shared schema.

- Message type is unique by schema id or context.
- Field order is fixed.
- Field names are not sent.
- Type tags and per-field fallback mode bytes are not sent.
- Integer physical encodings are selected by schema or deterministic profile rules.
- Enums, booleans, optional presence, and range-bit integers are packed into schema-derived bit groups.
- Stream mode can bind a schema once and then emit record bodies without per-record envelopes.

### 3.3 Batch Profile

A profile that bundles multiple records with the same shape or schema.

- row-wise batch
- columnar batch
- schema-aware columnar batch
- per-column codec selection
- optional generic compression

### 3.4 Stateful Profile

A profile that compresses against previous messages and shared dictionaries over the same stream/session/channel.

- previous-message patch
- base snapshot reference
- session-local template reuse
- trained dictionary reference
- control-stream entropy coding
- micro-batch reuse

This profile is optional. On transports that cannot support it, Dynamic/Bound/Batch alone must be sufficient.

---

## 4. v3 Wire Model

v3 uses profile-specific first-byte models. Dynamic Profile retains the v2 tag-table model. Bound and Batch Profiles use v1-compatible message-kind envelopes, with `SCHEMA_BATCH` added for schema-aware columnar batches and `BOUND_STREAM` added for compact schema-bound record streams.

The Dynamic tag table and the Bound/Batch message-kind table are disjoint profile-selected first-byte models. A decoder MUST know the active profile before interpreting byte 0. Dynamic `row_batch` and `col_batch` use `0xDB` and `0xDC`; envelope `ROW_BATCH` and `COLUMN_BATCH` use `0x06` and `0x07`.

### 4.1 Dynamic tags

| Range        | Meaning                          |
| ------------ | -------------------------------- |
| `0x00..0x7F` | positive fixint (`0..127`)       |
| `0x80..0x9F` | fixstr (`len=0..31`)             |
| `0xA0..0xAF` | fixarray (`count=0..15`)         |
| `0xB0..0xBF` | fixmap (`count=0..15`)           |
| `0xC0`       | null                             |
| `0xC1`       | false                            |
| `0xC2`       | true                             |
| `0xC3`       | float64 LE                       |
| `0xC4..0xC7` | uint8 / uint16 / uint32 / uint64 |
| `0xC8..0xCB` | int8 / int16 / int32 / int64     |
| `0xCC..0xCE` | bin8 / bin16 / bin32             |
| `0xCF..0xD1` | str8 / str16 / str32             |
| `0xD2..0xD3` | array16 / array32                |
| `0xD4..0xD5` | map16 / map32                    |
| `0xD6`       | `shape_def`                      |
| `0xD7`       | `shape_ref`                      |
| `0xD8`       | `key_ref`                        |
| `0xD9`       | `str_ref`                        |
| `0xDA`       | `typed_vec`                      |
| `0xDB`       | `row_batch`                      |
| `0xDC`       | `col_batch`                      |
| `0xDD`       | `state_patch`                    |
| `0xDE`       | `template_batch`                 |
| `0xDF`       | `ext`                            |
| `0xE0..0xFF` | negative fixint (`-32..-1`)      |

v3 Dynamic Profile is wire-compatible with v2 for unchanged tags.

Dynamic fixed-width integer payloads and fixed-width length/count fields are little-endian. This applies to `u16`/`u32`/`u64`, `i16`/`i32`/`i64`, `bin16`/`bin32`, `str16`/`str32`, `array16`/`array32`, and `map16`/`map32`.

### 4.2 Bound and Batch tags

| Kind   | Name           | Purpose                                  |
| ------ | -------------- | ---------------------------------------- |
| `0x00` | SCALAR         | scalar root                              |
| `0x01` | ARRAY          | dynamic heterogeneous array              |
| `0x02` | MAP            | dynamic map                              |
| `0x03` | SHAPED_OBJECT  | object using a session shape             |
| `0x04` | SCHEMA_OBJECT  | schema-aware object                      |
| `0x05` | TYPED_VECTOR   | homogeneous typed vector                 |
| `0x06` | ROW_BATCH      | row-wise batch                           |
| `0x07` | COLUMN_BATCH   | schema-less or shape-bound column batch  |
| `0x08` | CONTROL        | table and profile updates                |
| `0x09` | EXT            | extension                                |
| `0x0A` | STATE_PATCH    | patch against a base                     |
| `0x0B` | TEMPLATE_BATCH | micro-batch based on a template          |
| `0x0C` | CONTROL_STREAM | control lane for packed control payloads |
| `0x0D` | BASE_SNAPSHOT  | snapshot used by patches                 |
| `0x0E` | SCHEMA_BATCH   | schema-aware columnar batch              |
| `0x0F` | BOUND_STREAM   | schema-bound compact record stream       |

`SCHEMA_BATCH` and `BOUND_STREAM` are new in v3. Other kind values retain their existing meaning. In Bound/Batch Profile, byte-0 values outside `0x00..0x0F` are reserved and MUST fail decode unless explicitly negotiated.

### 4.3 Compatibility

- v3 is a clean break from v2 for Bound Profile field/record-body payloads.
- A v3 decoder MUST select profile and version explicitly.
- A decoder is not required to accept an incompatible Bound payload from another version.
- Dynamic Profile MAY remain wire-compatible with v2 where tags are unchanged.

### 4.4 v3 reference-profile defaults

Unless an enclosing transport/profile explicitly declares otherwise, the v3 reference profile uses these defaults:

| Area | Default |
| --- | --- |
| Bound layout | `layout_kind = compact` |
| Schema identity | `schema_id` present in `SCHEMA_OBJECT`, `BOUND_STREAM`, and `SCHEMA_BATCH` |
| Bound stream count | `count` present in `BOUND_STREAM` |
| Schema batch count | `column_count` present in `SCHEMA_BATCH` |
| Schema batch field | `field_id` omitted in strict schema-order compact mode |
| Integer `auto` | not allowed on the wire; schemas MUST resolve `auto` before `SCHEMA_OBJECT`/stream use |

A given resolved schema identity MUST NOT refer to multiple incompatible `layout_kind` or resolved physical-encoding choices.

---

## 5. Dynamic Profile

## 5.1 Purpose

Dynamic Profile keeps schema-less usability and can be smaller for one-shot payloads with intra-message repetition.

## 5.2 Message-local key interning

Maintain a key table per top-level message.

- First-seen keys are sent as literals and assigned `key_id`.
- Repeated keys in the same message may be sent via `key_ref` (`0xD8`).
- Tables MUST reset at each new top-level message.

`key_id` values are zero-based Twilic-PV ids assigned once per top-level message in first eligible key-literal registration order. Repeated key literals reuse the original id. Eligible key literals are keys emitted in Dynamic map key position; keys inside `shape_def` register only in the shape table and do not allocate `key_id` unless later emitted as Dynamic map key literals.

## 5.3 Message-local shape table

A shape is an ordered key sequence for map-like objects.

- Arrays of same-shape maps SHOULD use one `shape_def` (`0xD6`).
- Following rows MAY use `shape_ref` (`0xD7`) with value-only rows.
- Shape ids are explicit in `shape_def` and MUST be unique within the current top-level message. Encoders SHOULD assign them in first-seen order.

`shape_def` is a message-local declaration, not a decoded application value. In an array body, declarations may appear before encoded elements and do not count toward the decoded array element count. A decoder processes declarations until it has produced the declared array element count. `shape_ref` produces one decoded object value.

## 5.4 MAP

Maps are encoded as:

```text
[fixmap|map16|map32][key][value]...
```

Key forms:

- key literal string
- `key_ref` + `key_id`

Unknown `key_ref` id MUST fail decode.

## 5.5 ARRAY

Default array encoding:

```text
[fixarray|array16|array32][element_0][element_1]...
```

Optimized forms remain available:

- `typed_vec` for homogeneous primitive arrays
- `shape_def`/`shape_ref` for homogeneous map arrays

## 6. Bound Profile

## 6.1 schema

A schema-aware object assumes a shared schema.

Field numbers MUST be unique within a schema. Field names are metadata and are not sent in Bound payloads. Schema order is the declared field-array order and is part of the resolved schema identity.

Each field has at least:

- field number
- field name
- logical type
- physical encoding
- required / optional
- default value
- value range or allowed set
- string constraints

Logical integer aliases are normative:

- `u8`, `u16`, `u32`, `u64` are unsigned integer fields.
- `i8`, `i16`, `i32`, `i64` are signed integer fields.

`min` and `max` constrain the allowed value domain. They do not by themselves require fixed-width storage. Integer storage is selected by the field's physical encoding:

- `varuint` for unsigned integer varint payloads
- `zigzag_varuint` for signed integer varint payloads
- `range_bits` for `value - min` fixed-width bit payloads
- `fixed_le` for fixed-width little-endian integer payloads

If physical encoding is `auto`, an implementation MUST resolve it before `SCHEMA_OBJECT` or `BOUND_STREAM` bytes are emitted. The resolved physical encoding is part of the resolved schema/profile. For Bound single-record streams, `auto` SHOULD prefer varint encodings for wide ranges and `range_bits` only when the schema range is small enough to beat varint for the expected domain. For `SCHEMA_BATCH`, the column header codec supplies the selected physical column layout and may select bit-packing, delta, frame-of-reference, RLE, or patched forms.

A string field with `enumValues` is an enum field. Enum values MUST be unique and are indexed in schema order. Reordering, inserting before existing values, or removing values is schema-breaking unless a new schema identity is used.

Field identity for enum, dictionary, and trained state MUST be scoped by resolved schema identity and field number. Resolved schema identity is the in-band `schema_id` or an out-of-band schema fingerprint/context id. A bare field name MUST NOT be used as a global identity.

## 6.2 schema_id

If the message type is unique in context, schema_id may be omitted.

Attach schema_id only when mixed message types must be disambiguated.

## 6.3 SCHEMA_OBJECT

```text
0x04
[has_schema_id][schema_id?]
[has_presence][presence bytes?]
[field block bytes...]
```

- required fields are always sent
- optional fields follow the presence bitmap
- field numbers and field names are not sent
- schema-declared primitive fields do not carry per-field fallback mode bytes

`SCHEMA_OBJECT` is the self-delimiting Bound object form. It is useful when individual records must be independently decodable or when transport framing is unavailable. For schema-shared streams where Avro raw stream or Protocol Buffers raw messages are the baseline, implementations SHOULD prefer `BOUND_STREAM` or an externally framed Bound record stream so schema identity and object envelope bytes are not repeated per record.

`has_schema_id` and `has_presence` are one-byte flags: `0x00 = false`, `0x01 = true`; other values MUST fail decode. If optional fields exist and all-present elision is not declared by schema/profile, `has_presence` MUST be `0x01`. An all-absent optional set is encoded as a bitmap of zero bits, not by omitting the bitmap.

`SCHEMA_OBJECT has_presence = 1` encodes a normal bitmap only. Inverted presence is unavailable for `SCHEMA_OBJECT` unless a layout/profile adds an explicit `presence_strategy`.

`SCHEMA_OBJECT` is self-delimiting given the resolved schema. Variable-length fields MUST carry their own lengths or varuint termination, and compact-vs-byte-aligned field-block layout MUST be fixed by schema/profile.

For compact `SCHEMA_OBJECT`, after `presence bytes?` encode `[fixed bit group][byte payloads...]` using the same rules as compact record bodies, excluding a second presence region.

## 6.4 BOUND_STREAM

`BOUND_STREAM` (`0x0F`) binds one schema for consecutive compact records.

```text
0x0F
[schema_id?]
[count?]
[presence_strategy]
[record_body_0]
[record_body_1]
...
```

The exact presence of `schema_id` and `count` is determined by the enclosing transport/profile. The enclosing profile MUST predeclare `has_schema_id` and `has_count`; otherwise these fields MUST be encoded with explicit flags or always present. If schema and record count are already supplied out of band, they MUST NOT be included when reporting raw record-body bytes against raw Avro or unframed Protocol Buffers streams.

Before decoding the first `record_body`, the decoder MUST know exactly one bound schema from either in-band `schema_id` or out-of-band context. If `count` is omitted, the enclosing transport/frame MUST provide record count, byte extent, or an end-of-stream signal; otherwise `BOUND_STREAM` MUST include `count`. An end-of-stream delimiter is valid only for a terminal stream; multiplexed or framed transports MUST provide count or byte extent.

`presence_strategy` is one byte: `0x00 = normal bitmap per record`, `0x01 = inverted bitmap per record`, `0x02 = all-present elided`; other values are reserved and MUST fail decode unless negotiated by an extension.

Each `record_body` is decoded using the bound schema and contains no field names, field numbers, type tags, field count, schema id, or per-field mode bytes.

## 6.5 compact record body

Compact record bodies are serialized in schema order using three logical regions:

```text
[presence bits?]
[fixed bit group]
[byte payloads...]
```

- `presence bits` contain one bit per optional field unless the stream/schema declares an all-present strategy.
- `fixed bit group` contains required fields and present optional fields encoded as bool, enum, or `range_bits` values in schema order, bit-contiguously.
- `byte payloads` contain `fixed_le`, `f32`/`f64`, varuint, string, binary, and other byte-aligned fields in schema order for fields that are present.

The fixed bit group is byte-aligned as a whole. Individual fields inside the group MUST NOT be rounded up to whole bytes. Variable payloads start at the next byte boundary after the fixed bit group.

Presence bits are emitted for optional fields in schema order, least-significant bit first within each byte. The presence bitmap is padded with zero bits to the next byte. The fixed bit group then starts at the next byte, emits fields in schema order least-significant bit first, and is padded with zero bits to the next byte before byte payloads. Absent optional fields contribute zero bits and no payload. Decoders MUST reject non-zero padding bits in presence bitmaps and fixed bit groups.

Values outside the declared range or enum set MUST fail encode. They MUST NOT be silently encoded as fallback values.

Inside Bound Profile field payloads, including `SCHEMA_OBJECT`, `BOUND_STREAM`, and `SCHEMA_BATCH` columns, fallback dynamic/literal encodings and per-field mode bytes are prohibited unless a separately negotiated extension explicitly changes the layout. Any extension that changes Bound field layout MUST be negotiated before schema/stream decode and included in the resolved schema/layout identity. Unknown layout extensions MUST fail before reading record bodies.

## 6.6 field blocks

Field payloads are serialized in schema order. For `SCHEMA_OBJECT`, implementations MAY use byte-aligned field blocks when independent random access is more important than size. For compact Bound streams, bit-sized fields SHOULD be coalesced into the compact record body bit group.

Absent optional fields emit no payload. Fixed-size fields are schema-sized; strings, binary, and varuint fields are self-delimiting by their own length or varuint termination. Field blocks MAY be emitted one after another without per-field lengths because all bit widths and variable boundaries are derivable from schema and presence. Independent random access to variable-width fields requires an explicit offset/length table; otherwise decoders must scan preceding fields.

---

## 6.7 Zero-Copy Layout (optional)

In Bound Profile implementations that require extremely fast decode/encode, a **zero-copy layout** may be selected. In this layout, in-memory structure and wire layout are made nearly identical. Fields are aligned naturally, and offsets/pointers are represented as relative values so data can be memory-mapped and accessed directly. This follows a Cap'n Proto-like design philosophy and can reduce copying and decode/encode work for suitable fixed-layout schemas. However, because padding and pointer overhead can increase size, compact layout should be preferred when minimizing size is the primary goal.

Zero-copy is a distinct `layout_kind` declared by schema/profile and resolved before record-body decode. It is not wire-compatible with compact record bodies. A zero-copy schema MUST define field offsets, alignment, padding byte values, relative-offset width/base, endianness, and presence representation. Zero-copy layouts MUST preserve the same required/optional/default/null semantics as compact layouts. Compact `BOUND_STREAM` size comparisons MUST use `layout_kind = compact`, not zero-copy.

---

## 7. Null / Presence

## 7.1 presence bitmap

Use a presence bitmap for objects with optional fields.

- 1 = present
- 0 = absent

Bound presence is not nullability. `null` is illegal in Bound payloads unless the logical type explicitly includes null and defines its encoding. Missing required fields MUST fail encode/decode. An absent optional field reconstructs its declared default if one exists; otherwise it decodes as absent/unset. Presence MUST reflect input unless default-elision is explicitly declared.

## 7.2 inverted presence bitmap

Inversion is selected by the profile-specific `presence_strategy` or `null_strategy` value. In inverted mode, interpret 0 = present and 1 = absent.

## 7.3 all-present elision

Even with optional fields, if all fields are known to be present, the presence bitmap may be omitted.

This behavior must be fixed by schema or profile. All-present elision means every optional field or row value is present and its payload is encoded; it never means absent/use default.

---

## 8. Numeric Encoding

## 8.1 scalar integer

The v3 reference profile MUST encode Dynamic single integers as fixint first, then smallest-width fixed integer encoding.

- -32..-1 -> negative fixint
- 0..127 -> positive fixint
- 128..255 -> uint8
- 256..65535 -> uint16
- 65536..2^32-1 -> uint32
- above that -> uint64

Dynamic negative integers use negative fixint or fixed-width `i8`/`i16`/`i32`/`i64`. `zigzag_varuint` is only for Bound fields declared `zigzag_varuint`.

## 8.2 Bound integer physical encodings

Bound integer fields use the physical encoding declared by schema or selected by deterministic profile rules.

- `varuint`: unsigned value encoded as metadata varuint, with `min`/`max` validation when those constraints are declared.
- `zigzag_varuint`: signed value encoded as zigzag followed by metadata varuint, with `min`/`max` validation when those constraints are declared.
- `range_bits`: `value - min` encoded with a schema-derived bit width.
- `fixed_le`: fixed-width little-endian integer using the logical alias width, with no implicit alignment padding in compact Bound layouts.

`min` and `max` are validation constraints for all encodings. They become storage parameters only for `range_bits`.

`varuint` is valid only for logical unsigned aliases and non-negative constrained domains. `zigzag_varuint` is valid only for logical signed aliases. Encoding a value outside the logical alias domain or declared range MUST fail.

## 8.3 range-aware bit packing

When physical encoding is `range_bits`, store `value - min` with the minimum required bit width.

```text
offset = value - min
bits = ceil(log2(max - min + 1))
```

The offset uses exactly `bits` bits. A zero-width range consumes zero bits and reconstructs `min`. v3 implementations MUST NOT round this logical width up to a field payload byte and then add another per-field mode byte.

`range_bits` requires integral `min` and `max` with `max >= min`. Bounds are inclusive. Compute `domain_size = max - min + 1` using exact integer arithmetic; schemas whose domain size cannot be represented by the implementation MUST be rejected. Encode unsigned `offset = value - min`; offsets outside `0..domain_size - 1` MUST fail encode/decode. `range_bits` MUST NOT be used without both `min` and `max`.

## 8.4 metadata varuint

Use Twilic-PV for metadata such as lengths, IDs, and counts, and for Bound integer fields whose physical encoding is `varuint` or `zigzag_varuint`. Dynamic scalar integer selection SHOULD NOT use Twilic-PV.

Twilic-PV is an unsigned base-128 varuint. Each byte stores 7 payload bits in little-endian group order. The high bit is the continuation bit: `1` means another byte follows, `0` means this is the final byte. Encoders MUST use the shortest representation. Decoders MUST reject overlong representations.

Decoders MUST reject varuint values exceeding the target domain, declared limit, or implementation maximum. `u64`/`i64` Bound varuints MUST reject encodings above the logical alias domain.

Signed `zigzag_varuint` maps signed integers to unsigned integers as `encoded = (value << 1) ^ (value >> (width - 1))` for the logical alias width. Implementations with wider internal arithmetic MUST preserve the same result for the logical alias domain.

Targets:

- lengths
- counts
- key_id
- str_id
- shape_id
- schema_id
- prefix_len

## 8.5 vector integer codecs

For integer series in batch/typed vectors, the following column codecs are allowed.

- DIRECT_BITPACK
- DELTA_BITPACK
- FOR_BITPACK
- DELTA_FOR_BITPACK
- DELTA_DELTA_BITPACK
- RLE
- PATCHED_FOR
- SIMPLE8B

### 8.5.1 DIRECT_BITPACK

Compute the maximum bit width in a block and pack with a fixed width.

### 8.5.2 DELTA_BITPACK

Take deltas first, then apply bit packing.

### 8.5.3 FOR_BITPACK

Subtract the block minimum, then bit-pack.

### 8.5.4 DELTA_FOR_BITPACK

Take deltas, then subtract the minimum delta in the block, then bit-pack.

### 8.5.5 PATCHED_FOR

Use a patch-list scheme when most values fit in a small bit width and only some values overflow.

Implementations may adopt ORC/Parquet-style patched-base strategies.

### 8.5.6 DELTA_DELTA_BITPACK

**Delta-of-delta bit packing** is a codec for efficiently representing integer series where adjacent deltas are nearly constant, such as time series. Send the first two values and the first delta, then encode `delta_i - delta_{i-1}` with zigzag and store continuously with minimal required bit width. This is especially effective for monotonic increases and regular-step sequences.

### 8.5.7 SIMPLE8B

**Simple-8b** packs variable-length integers into 60-bit blocks, using a 4-bit header per block to indicate value count and per-value bit width. Because all integers in a block share one bit width, headers are simple and decoding is fast. When outliers exist, other codecs may be more advantageous.

---

## 8.6 float vector codecs

Floating-point series have error characteristics different from integer series, so specialized codecs are used. In time-series data especially, adjacent values are often similar, and XOR-based compression is effective.

### 8.6.1 XOR_FLOAT

The **XOR_FLOAT** codec converts each 64-bit float to its bit pattern and XORs consecutive values to detect similarity. The first value is sent as a full 64 bits. For subsequent values, XOR is taken against the previous value; if the result is zero, only a 1-bit flag is emitted. If nonzero, encode leading/trailing zero lengths of the XOR word and send only meaningful bits. This is particularly effective for smoothly changing series.

- Prefer XOR_FLOAT for time series with small incremental changes.
- If values fluctuate widely and XOR differences are unstable, prefer plain or generic compression.

---

## 9. Boolean / Enum

## 9.1 bool

Store bool in 1 bit.

Boolean bit `0` means false and bit `1` means true.

## 9.2 enum

Store enum in `ceil(log2(N))` bits.

Enum code is the zero-based index in schema `enumValues` order. `N = 0` is invalid. A single-value enum consumes zero bits and reconstructs the sole allowed value. Unknown enum values MUST fail encode. Decoded enum codes `>= N` MUST fail decode. Enum identity MUST be scoped by resolved schema identity and field number.

## 9.3 bool stream

In batch/typed vectors, bool columns may be emitted as a bitstream and then processed with byte-RLE or generic compression.

---

## 10. Strings

## 10.1 string policy

Because strings are often a weak point of MessagePack, the following modes are defined.

- EMPTY
- LITERAL
- REF
- PREFIX_DELTA
- INLINE_ENUM

## 10.2 LITERAL

```text
[length][utf8 bytes]
```

Send first-seen strings as-is.

## 10.3 REF

```text
[str_id]
```

Reference previously seen strings.

Every literal string value that is eligible for `REF` is registered in first-seen order by the active string table scope. `str_id` values are zero-based Twilic-PV ids assigned once per scope; repeated literal values reuse the original id. In Dynamic Profile, eligible literals are string values emitted in value position, excluding map keys and `shape_def` keys. Dynamic Profile uses message-local string tables unless a stateful extension explicitly changes the scope.

## 10.4 PREFIX_DELTA

```text
[base_ref][prefix_len][suffix_len][suffix bytes]
```

`suffix_len` is required unless an enclosing element length makes the suffix boundary explicit.

## 10.5 string table

A string table is message-local by default in Dynamic Profile. Stream-scope or shape/schema-scope string tables require a shared schema or an explicitly negotiated stateful extension.

- literals may be registered
- reconstructed prefix_delta results may also be registered
- REF may point only to already registered values

## 10.6 field-local dictionary

When repeated strings concentrate in a specific field, a field-local dictionary may be used.

This often yields a smaller id width than a broader string table.

Field-local dictionary encoding is available only when the selected column/stateful profile declares dictionary scope, literal order, id width, lifetime, and reset/invalidation behavior. Otherwise implementations MUST use literal or other self-delimiting string modes.

## 10.7 static dictionary

If a profile/application has fixed vocabularies, a static dictionary may be predefined.

Examples:

- status
- method
- role
- locale
- country

## 10.8 INLINE_ENUM

Even in dynamic mode, if a string field takes only a small fixed set of values, it may be promoted to inline enum by control message.

```text
CONTROL PROMOTE_STRING_FIELD_TO_ENUM
[field identity]
[value_count]
[string literals...]
```

After that, the field is sent using compact integer codes.

---

## 11. binary / string pooling

In Dynamic Profile, FlexBuffers-like automatic pooling is allowed.

- repeated key strings
- repeated string values
- repeated binary blobs

Also, offset/width/id/count may be automatically narrowed to smallest-width 8/16/32/64.

---

## 12. TYPED_VECTOR

## 12.1 Purpose

Homogeneous arrays are usually smaller when represented as TYPED_VECTOR instead of ARRAY.

## 12.2 header

```text
[element_type][count][codec][payload]
```

`element_type` is a Twilic-PV enum in the v3 reference profile:

| Code | Type   |
| ---- | ------ |
| `0`  | bool   |
| `1`  | u8     |
| `2`  | u16    |
| `3`  | u32    |
| `4`  | u64    |
| `5`  | i8     |
| `6`  | i16    |
| `7`  | i32    |
| `8`  | i64    |
| `9`  | f64    |
| `10` | string |
| `11` | binary |

Unknown `element_type` codes are reserved and MUST fail decode unless negotiated.

Reference-profile typed-vector and column payloads use the selected codec's payload grammar.

For `PLAIN`, present values are encoded in element/row order:

| Value kind         | Payload per present value                        |
| ------------------ | ------------------------------------------------ |
| unsigned integer   | fixed-width little-endian logical alias width    |
| signed integer     | two's-complement fixed-width little-endian width |
| `varuint` field    | Twilic-PV value                                  |
| `zigzag_varuint`   | zigzag then Twilic-PV                            |
| `fixed_le` field   | fixed-width little-endian logical alias width    |
| `f64`              | 64-bit little-endian IEEE 754                    |
| string             | Twilic-PV byte length followed by UTF-8 bytes    |
| binary             | Twilic-PV byte length followed by raw bytes      |
| bool               | bitstream, least-significant-bit first, zero-pad |
| enum               | fixed-width code bitstream, schema enum order    |
| `range_bits` field | fixed-width offset bitstream, field range width  |

For `DIRECT_BITPACK`, payload is `[bit_width][bitstream]`, where `bit_width` is Twilic-PV and the bitstream emits unsigned codes least-significant-bit first in element/row order with zero padding. Unsigned element types use the value as the code. Signed element types use zigzag over the logical alias width before bit packing. For schema columns, enum values use their schema enum code and `range_bits` values use `value - min`. Codes MUST be `< 2^bit_width`; `bit_width = 0` permits only code `0` and emits no bits.

## 12.3 benefits

- per-element type tags can be omitted
- bit packing/delta/FOR can be applied to homogeneous numeric series
- bool series can be emitted as bitstreams
- repeated scalar lists can be packed

## 12.4 typed string vector

For string arrays, the following are allowed.

- offsets + values
- dictionary ids
- prefix_delta sequence
- run-end encoding for repeated strings

---

## 13. Batch

## 13.1 ROW_BATCH

Concatenate records with the same shape/schema in row-wise form.

```text
[count][row_0][row_1]...[row_n-1]
```

## 13.2 COLUMN_BATCH

Store records with the same shape/schema in column-wise form.

```text
[count]
[column_0 header][column_0 payload]
[column_1 header][column_1 payload]
...
```

Each column header includes:

- field identity
- null strategy
- codec
- optional dictionary info

## 13.2A SCHEMA_BATCH

`SCHEMA_BATCH` (`0x0E`) is the schema-aware columnar form.

```text
0x0E
[schema_id?]
[count]
[column_count?]
[column_0]
[column_1]
...
```

`schema_id` is REQUIRED unless the enclosing transport/profile has already bound exactly one schema. If omitted for raw benchmark reporting, schema identity MUST be reported as external framing. Columns are in schema order. The profile MUST predeclare whether `column_count` and `field_id` are present. `column_count` MUST equal the number of schema fields unless the enclosing compact mode derives column count from schema.

Each column contains:

```text
[field_id?]
[null_strategy]
[presence bits?]
[codec]
[typed vector payload]
```

`field_id` is the schema field number. It MAY be omitted in strict schema-order compact mode; when omitted, field identity is derived from column position. If included, `field_id` is validation metadata and MUST be included in Twilic byte counts. If included and it mismatches the schema-order position, decode MUST fail. Implementations SHOULD keep fields numbered densely and in schema order so `field_id` is small and predictable.

`null_strategy` is a metadata varuint enum: `0 = no presence bitmap/all rows present`, `1 = normal bitmap`, `2 = inverted bitmap`; other values are reserved and MUST fail decode unless negotiated. The name is historical; it represents presence/absence, not explicit null, unless the logical type explicitly includes null and defines its encoding. Presence bitmaps are present only for `null_strategy = 1` or `2`, use one bit per row in row order, least-significant bit first within each byte, and are zero-padded to `ceil(count / 8)` bytes. Decoders MUST reject non-zero padding bits. For nullable/optional columns, typed-vector payload encodes present values only, in row order; element count is derived from `popcount(presence)`, or equals `count` for `null_strategy = 0`. The column typed-vector payload excludes element count and codec when those are already supplied by the enclosing column header.

## 13.3 column codecs

Each column may choose from:

- PLAIN
- DIRECT_BITPACK
- DELTA_BITPACK
- FOR_BITPACK
- DELTA_FOR_BITPACK
- DELTA_DELTA_BITPACK
- RLE
- DICTIONARY
- PATCHED_FOR
- SIMPLE8B
- STRING_REF
- PREFIX_DELTA
- XOR_FLOAT

Column and vector `codec` is a Twilic-PV enum in the v3 reference profile:

| Code | Codec               |
| ---- | ------------------- |
| `0`  | PLAIN               |
| `1`  | DIRECT_BITPACK      |
| `2`  | DELTA_BITPACK       |
| `3`  | FOR_BITPACK         |
| `4`  | DELTA_FOR_BITPACK   |
| `5`  | DELTA_DELTA_BITPACK |
| `6`  | RLE                 |
| `7`  | DICTIONARY          |
| `8`  | PATCHED_FOR         |
| `9`  | SIMPLE8B            |
| `10` | STRING_REF          |
| `11` | PREFIX_DELTA        |
| `12` | XOR_FLOAT           |

Unknown `codec` codes are reserved and MUST fail decode unless negotiated.

The v3 reference interoperability profile defines payload grammar for `PLAIN` and `DIRECT_BITPACK`. Other registered codec codes are reserved extension points unless a profile defines their exact payload grammar, including headers, bit order, block sizing, dictionary tables, id widths, run formats, and reset/lifetime rules. Benchmarks that use extension codecs MUST publish that codec profile and label those results separately from reference-profile interoperability results.

## 13.4 codec selection guidance

Implementations may choose codecs based on statistics.

- monotonic integers -> DELTA_BITPACK / DELTA_FOR_BITPACK
- clustered integers -> FOR_BITPACK
- low-cardinality strings -> DICTIONARY
- repeated values -> RLE
- mostly-null / mostly-present -> bitmap with inversion

Inversion does not reduce raw bitmap byte count by itself; prefer it when it improves downstream RLE/control-stream/generic compression or when required by profile heuristics.

---

## 13.5 Stateful Transport Extensions

## 13.5.1 session state

In stateful mode, encoder/decoder share session state.

Stateful mode requires a transport/profile that defines exact wire forms for state references, patch opcodes, reset controls, dictionary ids, and retention rules. The v3 reference interoperability profile is stateless unless such a profile is explicitly negotiated.

State may include at least:

- field-local dictionary
- recent base snapshots
- recent template ids
- optional trained compression dictionary id

State is session-local and must not be implicitly inherited across transports.

Per-message key/string/shape interning tables are message-local by default. Only explicitly negotiated stateful table extensions may persist shape/key/string tables across messages.

Negotiated persistent key/string/shape table extensions are session state and MUST be invalidated by `RESET_STATE`.

## 13.5.2 BASE_SNAPSHOT

`BASE_SNAPSHOT` is a full message used as a base for later patch references.

```text
[base_id][schema_or_shape_ref][payload]
```

The encoder may register reusable objects/rows/batches as snapshots.

The decoder must maintain a base-retention window, and base_id outside the window must be unreferenceable.

## 13.5.3 STATE_PATCH

`STATE_PATCH` sends only the delta from the previous message or a specified `base_id`.

```text
[base_ref][patch_opcode_stream][changed_fields][optional appended literals]
```

Patch opcodes may define at least:

- KEEP
- REPLACE_SCALAR
- REPLACE_VECTOR
- APPEND_VECTOR
- TRUNCATE_VECTOR
- DELETE_FIELD
- INSERT_FIELD
- STRING_REF
- PREFIX_DELTA

In Bound Profile where field order is fixed, patches may target field position instead of field number only within an immutable resolved schema layout; otherwise patches MUST target schema field numbers.

## 13.5.4 previous-message patch

When similarity to the immediately previous message is high, implicit previous-message may be used as `base_ref`.

This is highly effective for messages such as:

- status updates
- telemetry ticks
- periodically refreshed objects
- paginated responses containing cursor/offset
- nearly identical API response families

## 13.5.5 TEMPLATE_BATCH

To gain columnar benefits without waiting for a large batch, define `TEMPLATE_BATCH`.

```text
[template_id][count][changed-column-mask][column payloads]
```

`template_id` represents the same schema/shape/null strategy/codec set as a recent batch.

Unchanged column headers are not retransmitted.

## 13.5.6 CONTROL_STREAM

Control information such as presence bitmaps, enum streams, patch opcode streams, and string-mode streams may be separated from data payload and grouped into `CONTROL_STREAM`.

The following may be applied to the control stream.

- RLE
- bitpack
- Huffman
- FSE

By compacting frequent opcodes such as KEEP/PRESENT/SAME_STRING, stateful patch efficiency can be maximized.

## 13.5.7 trained dictionary reference

In small-message families, a trained dictionary may be referenced by `dict_id`.

```text
[dict_id][compressed block]
```

Dictionaries are recommended to be separated per data family. Methods for dictionary training, distribution, and invalidation must be fixed by transport profile.

## 13.5.8 RESET_STATE

To prevent state divergence, the encoder may send `RESET_STATE` control at any time.

After reset, the decoder must treat all base snapshot/template/dictionary references as invalid.

`base_ref` MUST include a discriminator for previous-message reference versus explicit `base_id` when both forms are supported by a stateful profile. `RESET_STATE` MUST be encoded by a negotiated CONTROL operation before it can affect decode state.

---

## 14. zero packing

For row-wise objects and fixed-width payloads, word-level zero packing may be applied optionally.

Method:

- 1-byte tag per 8-byte word
- bytes with tag bit = 1 are stored literally in payload
- bytes with tag bit = 0 are interpreted as zero
- special handling may be defined for all-zero/all-nonzero words

Use cases:

- structs with many default values
- integer series with many high-order zero bytes
- sparse fixed-width payloads

---

## 15. generic compression

## 15.1 principle

Apply data-aware encoding first, then apply generic compression at block level.

## 15.2 recommendations

- small correlated records -> zstd dictionary
- high-speed transport -> LZ4
- larger blocks -> zstd
- very high ratio with reasonable speed -> FSE

## 15.3 dictionary scope

Dictionaries are recommended to be separated by data family.

Examples:

- user records dictionary
- log records dictionary
- event records dictionary
- paginated API response dictionary
- telemetry tick dictionary

## 15.4 trained dictionary transport

Dictionaries may be distributed statically or negotiated at session start.

For small messages, trained dictionaries can strongly compress correlated families, and may be preferred over stateless zstd.

A dictionary transport profile must include at least:

- dictionary id
- version
- hash
- expiration/invalidation rule
- fallback behavior

---

## 16. API Policy For Usability

Implementations of this specification are recommended to provide at least these APIs.

```ts
encode(value);
encodeWithSchema(schema, value);
encodeBoundStream(schema, values, options?);
encodeBatchWithSchema(schema, values);
encodeBatch(shapeOrSchema, values);
createSessionEncoder(options);
```

### 16.1 contractless mode

`encode(value)` accepts object/array/scalar directly like MessagePack.

Internal optimization order:

1. represent as dynamic scalar/map/array
2. use `key_ref` / `str_ref` if message-local tables contain the literal
3. use `shape_def` / `shape_ref` within the current top-level message when same-shape arrays appear
4. use TYPED_VECTOR if homogeneous array
5. use ROW_BATCH or COLUMN_BATCH when batching is possible

### 16.2 schema mode

`encodeWithSchema(schema, value)` uses Bound Profile.

`encodeBoundStream(schema, values, options?)` binds schema once and emits compact record bodies suitable for raw schema-shared stream comparisons.

`encodeBoundStream` options MUST declare schema-id inclusion, count inclusion/framing, and presence strategy for reproducible byte counts.

### 16.3 batch mode

`encodeBatch(...)` selects per-column codecs based on column statistics. If a schema is passed to `encodeBatch`, it MUST delegate to `encodeBatchWithSchema(...)` or otherwise produce `SCHEMA_BATCH`. `encodeBatchWithSchema(...)` uses `SCHEMA_BATCH` and schema-derived column identity.

For reproducible byte counts, `encodeBatchWithSchema` options MUST declare schema-id inclusion, column-count inclusion, field-id inclusion, codec tie-break rules, compression policy, and dictionary policy.

### 16.4 session encoder mode

`createSessionEncoder(options)` returns an encoder that handles stateful profiles.

Typical API:

```ts
const enc = createSessionEncoder({
  maxBaseSnapshots: 8,
  enableStatePatch: true,
  enableTemplateBatch: true,
  enableTrainedDictionary: true,
});

enc.encode(value);
enc.encodePatch(value);
enc.encodeMicroBatch(values);
enc.reset();
```

The session encoder may automatically choose stateless or stateful mode based on previous-message similarity, recent base/template, and dictionary state.

---

## 17. Compatibility

## 17.1 v3 baseline

- v3 is the active wire profile family for new implementations
- Dynamic Profile top-level message-local ids (`key_id`, `str_id`, `shape_id`) MUST reset per message
- unknown `key_ref` / `str_ref` / `shape_ref` ids MUST fail decode
- Bound Profile MUST use schema-derived field payloads without per-field fallback mode bytes; compact streams SHOULD coalesce bit-sized fields into record-body bit groups

## 17.2 v2 coexistence

- v3 decoders are not required to decode v2 Bound payloads
- Dynamic Profile may remain v2-compatible where tags are unchanged
- if an implementation supports both versions, it MUST use an explicit external profile and version discriminator
- this specification does not define auto-detection between v2 and v3 Bound payloads

## 17.3 Stateful forms

- base_id, template_id, and dict_id are session-local
- unknown state references must follow configured policy (fail-fast or stateless retry)
- when state divergence is detected, encoder must be able to send RESET_STATE and then a stateless full message

---

## 18. Encoder Auto-Selection Rules

Implementations are recommended to observe value or batch statistics and automatically select representation in the order below.

Implementations may provide both lightweight and high-compression profiles, but decision rules must be deterministic within the same profile.

### 18.1 Basic policy

1. determine the shape of the root value first
2. classify into scalar/dynamic map/dynamic array/schema object/batch/stateful patch
3. prioritize interning when repetition can be detected
4. prioritize typed representation when homogeneous data is visible
5. prioritize columnar over row-wise when batch is sufficiently large
6. choose integer/string/float codec based on column statistics
7. consider stateful patch when overlap with previous message or recent base is large
8. apply generic compression last at block level

### 18.1A Stateful selection

#### Rule ST1: previous-message patch

Use `STATE_PATCH(previous)` as a candidate when:

- same schema / same shape
- changed_field_ratio <= 0.25
- appended_literal_bytes is sufficiently smaller than full_message_bytes

Strongly recommended thresholds:

- changed_field_ratio <= 0.10
- most fields can be expressed as KEEP

#### Rule ST2: base snapshot patch

Even when not against the previous message, if estimated patch size against a recent base snapshot is below 70% of full message size, consider `STATE_PATCH(base_id)`.

#### Rule ST3: template batch

If 4 or more small messages of the same schema/shape gather in a short time but waiting for a full column batch is too costly, consider `TEMPLATE_BATCH`.

#### Rule ST4: trained dictionary

If the payload family is stable and single-message encoded size is between 128B and 8KB, consider trained dictionary.

#### Rule ST5: stateless fallback

Keep stateless full message if any of the following applies.

- transport may reorder or lose messages
- base synchronization is weak
- changed_field_ratio is high
- decoder capability is unknown

### 18.2 Dynamic object selection

For input objects, decide in this order.

#### Rule D1: promotion to schema object

- if the call is `encodeWithSchema(schema, value)`, always use SCHEMA_OBJECT
- even in `encode(value)`, SCHEMA_OBJECT may be used only when the active profile/session supplies a resolved schema to both encoder and decoder; otherwise encode Dynamic

#### Rule D2: promotion to shaped object

If the same key sequence appears at least twice in the current top-level message, treat it as a message-local shape candidate.

When all conditions below hold, send `shape_def` and then use `shape_ref` rows. Session-scoped `SHAPED_OBJECT` or persistent shape registration requires an explicitly negotiated stateful extension.

- field_count >= 2
- same key sequence observation count >= 2
- `sum(key_literal_sizes) >= shape_registration_cost / expected_reuse_count`

For a simplified profile, the following threshold is acceptable.

- if field_count >= 3 and same key sequence appears >= 2 times, register shape

#### Rule D3: keep MAP

Keep MAP when any of the following is true.

- field_count <= 1
- key sequence is not reused
- object is estimated to be one-shot
- registration cost exceeds reuse benefit

### 18.3 key table selection

#### Rule K1: key interning

If one key literal is observed at least twice in the current top-level message, treat it as a key-table registration candidate.

Recommended thresholds:

- key byte length >= 3
- same key occurrences >= 2

Even short keys may be registered when occurrence count is high.

#### Rule K2: keep key literal

Literal form is acceptable when:

- key byte length <= 2 and occurrences are low
- temporary keys used only in that object

### 18.4 array selection

#### Rule A1: promotion to typed vector

If all elements fit a single physical type, consider TYPED_VECTOR.

Recommended thresholds:

- primitive homogeneous array with count >= 4
- strongly recommend typed vector for bool arrays when count >= 8
- integer arrays: candidate when count >= 4
- float arrays: candidate when count >= 4
- string arrays: typed string vector candidate when count >= 4

#### Rule A2: keep dynamic ARRAY

Keep ARRAY when:

- heterogeneous array
- count <= 3
- mixed scalar/object/array is common

### 18.5 Presence / Null selection

#### Rule P1: presence bitmap elision

Even with optional fields, if schema/profile guarantees all fields are present, the presence bitmap may be omitted.

#### Rule P2: inverted presence bitmap

Let optional-field count be M, present count P, absent count A.

- if A < P, consider inverted bitmap
- as a simple threshold, recommend inverted when `A <= M / 4`
- if `A = 0` and all-present elision is allowed, bitmap itself may be omitted

#### Rule P3: normal bitmap

- recommend normal bitmap when `A > M / 4`

### 18.6 integer selection

#### Rule I1: scalar integer

For one-shot Dynamic integers, use fixint first, then smallest-width fixed integer.

- -32..-1 -> negative fixint
- 0..127 -> positive fixint
- 128..255 -> uint8
- 256..65535 -> uint16
- 65536..2^32-1 -> uint32
- above that -> uint64

Use Twilic-PV for metadata count/id/length and for Bound integer fields whose physical encoding is `varuint` or `zigzag_varuint`. Dynamic scalar integers MUST NOT use Twilic-PV.

#### Rule I2: schema-aware bounded integer

If a schema declares `physical_encoding = auto` and provides `min`/`max`, consider `range_bits`. Prefer `range_bits` only when estimated encoded size beats `varuint` or `zigzag_varuint` for the active profile. Declared `varuint`, `zigzag_varuint`, `range_bits`, or `fixed_le` MUST NOT be overridden. Declared `min`/`max` MUST be validated for every integer encoding.

#### Rule I3: integer vector codec selection

For an integer vector or integer column, compute per block:

- count
- min
- max
- range = max - min
- adjacent deltas
- min_delta
- max_delta
- delta_range = max_delta - min_delta
- run count

Then choose codec in the following order.

##### Rule I3-0: DELTA_DELTA_BITPACK

- `count >= 8` and `non_zero_delta_of_delta_ratio <= 0.25`
- or `delta_range_bits <= 2`
- strongly recommended for nearly constant adjacent-delta series such as regular-interval timestamps

##### Rule I3-1: RLE

- average run length of the most frequent value >= 3
- or total_run_savings > direct_bitpack_savings
- simple threshold: `repeated_ratio >= 0.5` and average run length >= 3

##### Rule I3-2: FOR_BITPACK

- `bit_width(max - min) + header_cost < plain_width`
- simple threshold: `range_bits <= plain_bits - 4`

##### Rule I3-3: DELTA_FOR_BITPACK

- count >= 8
- delta_range_bits < range_bits
- monotonic or nearly monotonic
- simple threshold: `delta_range_bits <= range_bits - 3`

##### Rule I3-4: DELTA_BITPACK

- `max_abs_delta_bits <= plain_bits - 3`
- may be preferred when header is cheaper than FOR

##### Rule I3-5: PATCHED_FOR

- 90% or more fit in `base_width`
- patch_count / count <= 0.1

##### Rule I3-6: DIRECT_BITPACK

- does not match rules above but is still smaller than plain integer

##### Rule I3-7: PLAIN

- use PLAIN when count < 4
- keep plain when block is too small or header overhead does not pay off

##### Rule I3-8: SIMPLE8B

- `count >= 8`
- `max_bit_width <= 16`
- not monotonic and gains from delta-of-delta/FOR are limited
- little benefit from run-length or patched-base strategies

### 18.6A floating-point vector selection

#### Rule F1: XOR_FLOAT

- strongly recommended when adjacent deltas are small and average non-zero XOR bit width is <= 16 bits
- select when 50% or more of XOR differences are representable as 0 or 1 bit
- effective for temporally smooth values

#### Rule F2: PLAIN / generic

- if XOR bit widths vary widely and remain large, consider plain encoding or downstream generic compression
- when float values are integer-like and narrow in range, integer conversion plus integer codec may be used

### 18.7 string selection

For string fields or string vectors, observe:

- unique_count
- unique_ratio = unique_count / count
- average_length
- repeated_count
- prefix similarity
- static dictionary hit ratio

#### Rule S1: EMPTY

Use EMPTY when length is zero.

#### Rule S2: REF

If the same string exists in table, treat REF as candidate.

Recommended thresholds:

- `ref_cost < literal_cost`
- simple rule: recommend REF when `str_id` fits in 1 or 2 bytes and literal length >= 2

#### Rule S3: PREFIX_DELTA

Let longest common prefix length with base string be L and suffix length be S.

- L >= 2
- `base_ref_cost + prefix_len_cost + suffix_cost < literal_cost`
- simple threshold: `L >= 3` and `S <= literal_length - 2`

#### Rule S4: field-local dictionary

- count >= 8
- unique_ratio <= 0.5
- average_length >= 3
- strongly recommended threshold: count >= 16 and unique_ratio <= 0.25

#### Rule S5: static dictionary

- candidate when hit_ratio >= 0.5
- strongly recommended when hit_ratio >= 0.8

#### Rule S6: INLINE_ENUM

- count >= 16
- unique_count <= 8
- unique_ratio <= 0.25
- low new-value appearance rate

#### Rule S7: LITERAL

Use LITERAL when none of the above applies.

### 18.8 Batch selection

#### Rule B1: row batch

If there are at least 4 rows with the same shape/schema, consider ROW_BATCH.

#### Rule B1A: schema batch

If all rows are represented by one shared schema, consider `SCHEMA_BATCH` instead of schema-less COLUMN_BATCH. For schema-fixed homogeneous records, `SCHEMA_BATCH` is the preferred baseline for Protobuf/Avro comparisons.

#### Rule B2: column batch

If there are at least 16 rows with the same shape/schema, consider COLUMN_BATCH.

Further, strongly recommend COLUMN_BATCH when any of the following holds.

- integer column exists and delta/FOR is effective
- low-cardinality string column exists
- many optional fields exist
- count >= 32

#### Rule B3: keep row-wise

Keep row-wise when:

- count <= 3
- row shapes are not stable
- fields have high entropy and column codecs are unlikely to help
- low latency is prioritized and waiting for batch formation is not acceptable

### 18.9 zero packing selection

#### Rule Z1: apply zero packing

Zero packing may be applied when zero-byte ratio is high in fixed-width payload or row-wise structs.

Recommended thresholds:

- candidate when zero_byte_ratio >= 0.25
- strongly recommended when zero_byte_ratio >= 0.5

#### Rule Z2: do not apply zero packing

- payload is too small
- zero-byte ratio is low
- downstream compression is clearly superior

### 18.10 generic compression selection

#### Rule G1: conditions to apply generic compression

- encoded_block_size >= 256 bytes
- or batch contains multiple records

#### Rule G2: zstd dictionary

- small correlated records
- stable record family
- relatively small encoded_block_size where one-shot zstd tends to be less favorable

#### Rule G3: LZ4

Recommended when low latency is prioritized and moderate repetition exists.

#### Rule G4: no compression

- block is too small
- already compact enough from bit packing/dictionary/delta
- CPU cost constraints are strict

### 18.11 scoring method

Implementations may estimate size for each candidate codec and choose the smallest.

```text
score(codec) = estimated_encoded_size(codec) + switching_penalty(codec)
```

- `estimated_encoded_size(codec)` includes header, table updates, patch lists, dictionary, and bitmap total
- `switching_penalty(codec)` is a hysteresis term for profile stability or low-latency behavior

### 18.12 simplified recommended heuristics

For minimal implementations, the following simplified rules may be used.

- use message-local `shape_def` / `shape_ref` after the same key sequence appears twice in one top-level message
- use typed vector for homogeneous primitive arrays with count >= 4
- use bound stream for repeated schema-bound records when row latency or stream semantics matter
- use SCHEMA_BATCH for 16+ rows of the same shared schema; use COLUMN_BATCH for schema-less or shape-bound rows
- use dictionary for string columns with unique_ratio <= 0.25
- use DELTA_FOR_BITPACK for monotonic integer columns
- use DELTA_DELTA_BITPACK for regular integer sequences
- use XOR_FLOAT for smooth float columns
- use RLE for columns with repeated_ratio >= 0.5
- use previous-message patch for same-schema objects with changed_field_ratio <= 0.10
- treat small messages in the 128B..8KB range within the same family as trained-dictionary candidates
- use zero packing for fixed payload with zero_byte_ratio >= 0.5
- treat encoded block >= 256 bytes as generic-compression candidate

---

## 18.13 Benchmark Contract

Implementations SHOULD publish size and throughput results under explicit profile conditions.

Required comparisons:

- Dynamic stateless repeated-data fixtures versus MessagePack and CBOR
- Bound stream versus schema-shared Protocol Buffers and Avro raw record stream
- Batch pack versus Protocol Buffers repeated embedded messages for record batches, with concatenated messages or packed repeated scalar fields reported separately where applicable, and Avro raw record stream

Schema assumptions MUST be explicit:

- If Twilic shares schema out of band, baselines must share schema out of band.
- If Twilic reports `BOUND_STREAM` raw record-body bytes, schema id, count, and transport framing must be reported separately unless equivalent framing is included for every baseline.
- For `BOUND_STREAM`, report both message bytes and raw record-body bytes. Message bytes include `0x0F`, schema/count when present, presence strategy, and record bodies. Raw record-body bytes include only `record_body_*`; excluded envelope/framing bytes MUST be reported separately and excluded for baselines only under equivalent assumptions.
- For `SCHEMA_BATCH`, report raw column payload bytes, Twilic batch bytes including `0x0E`, in-band `schema_id` when present, count, in-band `column_count` when present, column headers, presence, codec metadata, and payloads, and external framing bytes including schema identity if omitted.
- Batch targets apply to Twilic batch bytes, not raw column payload bytes. Raw column payload bytes are reported separately only for analysis.
- If Twilic results include generic compression or trained dictionaries, report uncompressed Twilic too and either apply the same compressor/dictionary policy to baselines or label compressed results separately. Compressed byte counts MUST include compression wrapper bytes, `dict_id`, dictionary negotiation metadata, static dictionary distribution cost, or an explicit amortization policy.
- Avro Object Container Files and transport framing must be reported separately from raw record payload bytes.
- Protocol Buffers stream messages must not include length prefixes unless the Twilic stream also includes framing. Length prefixes may be excluded only when an equivalent external record count, byte extent, or record-boundary mechanism is supplied for all formats.

Benchmark targets for fixtures where the Twilic profile's schema-derived bit packing, batching, or column codecs apply:

- Bound stream target: comparable to, and on applicable compact-bitstream fixtures no larger than, the smaller of Protobuf and Avro raw stream.
- Batch pack target: smaller than both Protobuf repeated-message or packed-scalar baselines and Avro raw stream for homogeneous repeated records.
- Dynamic stateless repeated-data target: smaller than plain MessagePack and plain CBOR on repeated-key/string, homogeneous-array, and same-shape-object-array fixtures.
- Benchmarks MUST label JSON-text compatibility paths separately from native-vs-native comparisons.

---

## 19. Why It Can Beat MessagePack on Repeated Data

The main reasons this specification can outperform MessagePack on repeated data are:

1. object keys are not sent every time
2. repeated shapes can be encoded as shape_id
3. repeated strings can be encoded as str_id
4. homogeneous arrays can become typed vectors
5. bounded integers can be bit-packed
6. advanced integer codecs such as delta-of-delta and Simple-8b are available
7. XOR_FLOAT compression can be applied to float columns
8. columnar + dictionary + delta/FOR can be used in batch
9. zero packing can be applied to default-heavy payloads
10. zstd/FSE can be layered after data-aware encoding
11. zero-copy layout can reduce copying and decode/encode work for suitable fixed-layout schemas
12. previous-message patch can further reduce mostly-unchanged message families
13. template batch can bring forward columnar gains even for small consecutive messages
14. trained dictionary reference can strongly compress small, highly correlated message families

On the other hand, for one-shot tiny scalar/short-string/tiny-array payloads, size may be close to MessagePack compact paths or occasionally worse. Therefore, this specification explicitly targets repeated-data amortization and stateful reuse rather than single-shot worst-case wins.

---

## 20. Summary

This specification integrates all of the following into one format family.

- MessagePack-like dynamic usability
- schema-derived bit blocks via shared schema
- schema-aware columnar batches
- learning of repeated shape/key/string patterns
- typed vectors
- columnar batch
- per-column adaptive codecs
- float optimization including XOR_FLOAT
- optional zero-copy layout
- previous-message patch / base snapshot reuse
- template batch / control-stream separation
- optional zero packing
- optional zstd/FSE/trained-dictionary compression

As a result, it is easy to use at first transmission and can automatically migrate to smaller representations as soon as repetition or batching appears. In environments where sessions can be maintained, stateful patching and dictionary reuse can reduce transfer size far beyond one-shot stateless mode.
