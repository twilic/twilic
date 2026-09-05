# SPEC Test Traceability (5/6/8/10/13/15/18)

This file maps `twilic/SPEC.md` requirements to Ruby tests in `twilic-ruby`.

## 5. Dynamic Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 5.2 key table | First key literal, later key ref by id | `DynamicProfileSpecTest#test_two_field_map_keeps_map_and_uses_key_ids` |
| 5.3 shape table | Repeated shape registration/promotion behavior | `DynamicProfileSpecTest#test_shape_promotes_after_second_three_field_map` |
| 5.4 MAP | Map roundtrip and key-ref decode behavior | `DynamicProfileSpecTest#test_two_field_map_keeps_map_and_uses_key_ids`, `TwilicTest#test_codec_roundtrip_dynamic_value` |
| 5.5 ARRAY | ARRAY vs typed vector threshold behavior | `DynamicProfileSpecTest#test_typed_vector_threshold_is_applied` |

## 6. Bound Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 6.1 schema | Required field handling, schema decode | _not yet covered_ |
| 6.2 schema_id | Emit on first use, omit in same context | _not yet covered_ |
| 6.3 SCHEMA_OBJECT | Schema object message roundtrip | _not yet covered_ |

## 8. Numeric Encoding

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 8.1 scalar integer | Zigzag/varuint scalar integer behavior | _not yet covered_ |
| 8.2 range-aware bit packing | Bounded integer handling in schema context with fixed-width range offsets | _not yet covered_ |
| 8.4 vector integer codecs | Plain/direct/delta/FOR/delta-FOR/delta-delta/RLE/patched/Simple8b | _not yet covered_ |
| 8.5 float vector codecs | XOR float vs plain behavior | _not yet covered_ |

## 10. Strings

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 10.2 LITERAL | Literal mode encode/decode | _not yet covered_ |
| 10.3 REF | String ref reuse behavior | _not yet covered_ |
| 10.4 PREFIX_DELTA | Prefix-delta mode encode/decode | _not yet covered_ |
| 10.5 string table | Reset clears string table state | _not yet covered_ |
| 10.6 field-local dictionary | String dictionary/ref behavior in column codec path | _not yet covered_ |
| 10.8 INLINE_ENUM | Control-driven enum promotion path | _not yet covered_ |

## 13. Batch / Stateful Extensions

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 13.1 ROW_BATCH | Small batch uses row batch | _not yet covered_ |
| 13.2 COLUMN_BATCH | Large batch uses column batch and null strategy paths | _not yet covered_ |
| 13.5.1 session state | Unknown reference policy behavior (base/template/dict families) | `TwilicTest#test_unknown_reference_policy_supports_stateless_retry` |
| 13.5.2 BASE_SNAPSHOT | Snapshot registration/reference | `InteropFixturesTest#test_codec_encode_decode_roundtrip` |
| 13.5.3 STATE_PATCH | Patch roundtrip and bounds checks | `TwilicTest#test_session_patch_and_micro_batch`, `InteropFixturesTest#test_session_encode_decode_roundtrip` |
| 13.5.4 previous-message patch | Previous-message patch selection | _not yet covered_ |
| 13.5.5 TEMPLATE_BATCH | Template create/reuse and changed mask | `TwilicTest#test_session_patch_and_micro_batch`, `InteropFixturesTest#test_session_encode_decode_roundtrip` |
| 13.5.6 CONTROL_STREAM | Plain/RLE/Bitpack/Huffman/Fse paths and compaction behavior | `InteropFixturesTest#test_decode_rust_server_frames` |
| 13.5.7 trained dictionary | Dictionary id assignment and `dict_id + compressed block` path in column encoding | _not yet covered_ |
| 13.5.8 RESET_STATE | Reset clears tables/state references | _not yet covered_ |

## 18. Encoder Auto-Selection Rules

| Rule cluster | Requirement (short) | Tests |
| --- | --- | --- |
| Dynamic map/shape rules | Repeated-shape promotion, map fallback, key refs | `DynamicProfileSpecTest#test_shape_promotes_after_second_three_field_map`, `DynamicProfileSpecTest#test_two_field_map_keeps_map_and_uses_key_ids` |
| Typed vector rules | Array cardinality/type based vectorization | `DynamicProfileSpecTest#test_typed_vector_threshold_is_applied` |
| String mode rules | Empty/literal/ref/prefix-delta transitions | _not yet covered_ |
| Batch selection rules | Row vs column threshold, micro-batch shape requirement | _not yet covered_ |
| Stateful patch threshold | Prefer patch only at low change ratio | _not yet covered_ |
| Numeric codec choice | i64/u64/float codec heuristics | _not yet covered_ |

## 15. Trained Dictionary Transport

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 15.4 trained dictionary transport | Dictionary transport carries id/version/hash/invalidation/fallback metadata and validates payload hash | _not yet covered_ |

## Interop Coverage

| Area | Tests |
| --- | --- |
| Ruby fixture encode/decode roundtrip | `InteropFixturesTest#test_codec_encode_decode_roundtrip`, `InteropFixturesTest#test_session_encode_decode_roundtrip` |
| Rust server -> Ruby client | `InteropFixturesTest#test_decode_rust_server_frames`, `scripts/check-ruby-client-interop.sh` |
| Ruby server -> Rust client | `InteropFixturesTest#test_rust_decodes_ruby_frames_with_same_values`, `scripts/check-rust-client-interop.sh` |

## Current Gaps (explicit)

- Most bound-profile, numeric codec, string mode, batch selection, and trained-dictionary spec sections are not yet covered by dedicated Ruby tests.
- Optional-only extension note: Section 6.4 (zero-copy layout) is not implemented as a conformance target.
- Optional-only extension note: Section 10.7 (static dictionary) is not implemented as a conformance target.
- Rust-dependent interop tests use the monorepo's `../rust` runtime (or `TWILIC_RUST_ROOT`).
