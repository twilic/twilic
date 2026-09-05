# SPEC Test Traceability (current Zig coverage)

This file maps implemented `twilic/SPEC.md` behaviors to Zig tests in `twilic-zig/tests/main.zig`.

## 5. Dynamic Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 5.2 key table | First key literal, later key ref by id | `two-field map keeps map and uses key ids` |
| 5.3 shape table | Promote repeated map shape to shaped object | `shape promotes after second three-field map`, `register shape with key ids roundtrips` |
| 5.4 MAP | Map decode path, unknown key id policy behavior | `unknown key reference honors policies` |
| 5.5 ARRAY | Array vs typed-vector threshold behavior | `typed vector threshold is applied` |

## 6. Bound Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 6.1 schema | Required field validation | `schema id is sent first then omitted`, `encode with schema rejects missing required field` |
| 6.2 schema_id | First schema object includes id, subsequent message omits | `schema id is sent first then omitted` |
| 6.3 SCHEMA_OBJECT | Schema-aware object with presence bitmap and field-order encoding | `encode with schema rejects missing required field` |
| 6.4 BOUND_STREAM | Schema-bound compact record stream with presence strategy | `encode bound stream roundtrips and creates bound stream`, `encode bound stream public api roundtrips` |
| 6.5 compact record body | Compact record with presence bits, fixed bit group, byte payloads | (covered by BoundStream tests) |
| 6.6 field blocks | Byte-aligned field blocks for SCHEMA_OBJECT, bit-sized coalescing for compact streams | (covered by BoundStream + SchemaObject tests) |

## 8. Numeric Encoding

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 8.4 vector integer codecs | Simple8b roundtrip and malformed decode handling | `vector codecs roundtrip smoke`, `vector codec simple8b u64 edge cases`, `vector codec rejects malformed inputs` |
| 8.5 float vector codecs | XOR float roundtrip behavior | `vector codecs roundtrip smoke` |

## 10. Strings

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 10.2 LITERAL | Literal mode used on first string emission | `string modes empty ref and prefix delta are used`, `reset tables clears string interning` |
| 10.3 REF | Repeated string emits reference mode | `string modes empty ref and prefix delta are used`, `reset tables clears string interning` |
| 10.4 PREFIX_DELTA | Prefix-delta selected when profitable | `string modes empty ref and prefix delta are used` |
| 10.5 string table | ResetTables clears string intern state | `reset tables clears string interning` |

## 12. TYPED_VECTOR

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 12.2 header | Element type, count, codec, payload wire format | `vector codecs roundtrip smoke`, `typed vector threshold is applied` |

## 13. Batch / Stateful Extensions

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 13.1 ROW_BATCH | Small batch uses row batch | `batch threshold selects row vs column` |
| 13.2 COLUMN_BATCH | Large batch uses column batch | `batch threshold selects row vs column` |
| 13.5.1 session state | Unknown reference policy branch behavior | `unknown key reference honors policies`, `unknown base id honors stateless retry policy` |
| 13.5.2 BASE_SNAPSHOT | Base snapshot message roundtrip and registration | `base snapshot roundtrips and registers by id` |
| 13.5.3 STATE_PATCH | Patch message decode and map insert/delete reconstruction | `state patch uses recommended ratio threshold`, `state patch map insert and delete reconstructs previous message` |
| 13.5.5 TEMPLATE_BATCH | Micro-batch template reuse and changed-column mask | `micro batch reuses template and emits changed mask` |
| 13.5.6 CONTROL_STREAM | Control stream codec roundtrip and framing behavior | `control stream roundtrips for all declared codecs`, `control stream bitpack compacts repetitive payloads`, `control stream fse falls back to plain frame mode` |
| 13.5.8 RESET_STATE | Reset clears shape resolution | `reset state clears shape resolution` |

## 13.2A SCHEMA_BATCH

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 13.2A wire | Schema-aware columnar batch with schema_id, count, columns | `encode batch with schema roundtrips`, `encode batch with schema public api roundtrips` |
| 13.2A column | Per-column null_strategy, presence bitmap, codec, typed vector payload | (covered by SchemaBatch tests) |

## 6.4 BOUND_STREAM

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 6.4 wire | Bound stream with schema_id, count, presence_strategy, records | `encode bound stream roundtrips and creates bound stream`, `encode bound stream public api roundtrips` |
| 6.4 presence | presence_strategy byte: 0=normal, 1=inverted, 2=all-present | (covered by BoundStream tests) |

## 18. Encoder Auto-Selection Rules

| Rule cluster | Requirement (short) | Tests |
| --- | --- | --- |
| Dynamic map/shape rules | Repeat-map promotion and key-id reuse | `shape promotes after second three-field map`, `two-field map keeps map and uses key ids` |
| Typed vector rules | Minimum length threshold for typed vectors | `typed vector threshold is applied` |
| String mode rules | Empty/literal/ref/prefix-delta transitions | `string modes empty ref and prefix delta are used` |
| Batch selection rules | Row vs column threshold | `batch threshold selects row vs column` |

## Current gaps (explicit)

- Trained dictionary transport coverage (SPEC section 15) is pending.
- Stateful parity still needs deeper edge-path coverage for `StatePatch`/`TemplateBatch` beyond the currently ported core scenarios.
- Compact record body bit grouping (bool/enum/range_bits fields coalesced into a contiguous bit group per spec §6.5) is not yet implemented; field blocks are currently byte-aligned.
- `string_constraints` on `SchemaField` (spec §6.1) not yet added — same gap as Rust/Go references.
- ElementType table (spec §12.2) has 12 variants (u8, u16, u32, i8, i16, i32, etc.); all reference implementations (Rust/Go/Zig) use 7 variants — kept consistent with references.
