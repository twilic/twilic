# SPEC Test Traceability (5/6/8/10/13/15/18)

This file maps `twilic/SPEC.md` requirements to Python tests in `twilic-python`.

## 5. Dynamic Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 5.2 key table | First key literal, later key ref by id | `test_dynamic_profile_two_field_map_keeps_map_and_uses_key_ids` |
| 5.3 shape table | Repeated shape registration/promotion behavior | `test_dynamic_profile_shape_promotes_after_second_three_field_map` |
| 5.4 MAP | Map roundtrip and key-ref decode behavior | `test_dynamic_profile_two_field_map_keeps_map_and_uses_key_ids` |
| 5.5 ARRAY | ARRAY vs typed vector threshold behavior | `test_dynamic_profile_typed_vector_threshold_is_applied` |

## 6. Bound Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 6.2 schema_id | Emit on first use, omit in same context | `test_bound_batch_stateful_schema_id_is_sent_first_then_omitted` |
| 6.3 SCHEMA_OBJECT | Schema object message roundtrip | `test_bound_batch_stateful_schema_id_is_sent_first_then_omitted` |

## 8. Numeric Encoding

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 8.4 vector integer codecs | Plain/direct/delta/FOR/delta-FOR/delta-delta/RLE/patched/Simple8b | `test_codec_spec_vectors_simple8b_i64_roundtrip_small_values`, `test_codec_spec_vectors_simple8b_u64_roundtrip_with_long_zero_runs`, `test_codec_spec_vectors_simple8b_u64_falls_back_for_large_values`, `test_codec_spec_vectors_for_u64_overflow_is_rejected`, `test_codec_spec_vectors_direct_bitpack_invalid_width_is_rejected` |
| 8.5 float vector codecs | XOR float vs plain behavior | `test_codec_spec_vectors_xor_float_roundtrip_smooth_series` |

## 10. Strings

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 10.2 LITERAL | Literal mode encode/decode | `test_dynamic_profile_string_modes_empty_ref_and_prefix_delta_are_used` |
| 10.3 REF | String ref reuse behavior | `test_dynamic_profile_string_modes_empty_ref_and_prefix_delta_are_used`, `test_dynamic_profile_reset_tables_clears_string_interning` |
| 10.4 PREFIX_DELTA | Prefix-delta mode encode/decode | `test_dynamic_profile_string_modes_empty_ref_and_prefix_delta_are_used` |
| 10.5 string table | Reset clears string table state | `test_dynamic_profile_reset_tables_clears_string_interning` |
| 10.6 field-local dictionary | String dictionary/ref behavior in column codec path | `test_bound_batch_stateful_column_batch_assigns_dictionary_id_for_repeated_string_field` |

## 13. Batch / Stateful Extensions

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 13.1 ROW_BATCH | Small batch uses row batch | `test_bound_batch_stateful_batch_threshold_selects_row_vs_column` |
| 13.2 COLUMN_BATCH | Large batch uses column batch and null strategy paths | `test_bound_batch_stateful_batch_threshold_selects_row_vs_column`, `test_bound_batch_stateful_column_batch_assigns_dictionary_id_for_repeated_string_field` |
| 13.5.1 session state | Unknown reference policy behavior (base/template/dict families) | `test_bound_batch_stateful_unknown_base_id_honors_stateless_retry_policy` |
| 13.5.3 STATE_PATCH | Patch roundtrip and bounds checks | `test_bound_batch_stateful_state_patch_map_insert_and_delete_roundtrip_via_reconstruction` |
| 13.5.4 previous-message patch | Previous-message patch selection | `test_bound_batch_stateful_state_patch_uses_recommended_ratio_threshold` |
| 13.5.5 TEMPLATE_BATCH | Template create/reuse and changed mask | `test_bound_batch_stateful_micro_batch_reuses_template_and_emits_changed_mask` |
| 13.5.6 CONTROL_STREAM | Plain/RLE/Bitpack/Huffman/Fse paths and compaction behavior | `test_control_stream_and_control_spec_control_stream_roundtrips_for_all_declared_codecs`, `test_control_stream_and_control_spec_control_stream_bitpack_huffman_fse_compact_repetitive_payloads`, `test_control_stream_and_control_spec_control_stream_fse_uses_fse_frame_mode` |
| 13.5.7 trained dictionary | Dictionary id assignment and `dict_id + compressed block` path in column encoding | `test_bound_batch_stateful_column_batch_assigns_dictionary_id_for_repeated_string_field`, `test_bound_batch_stateful_trained_dictionary_profile_is_transported_to_fresh_decoder`, `test_bound_batch_stateful_trained_dictionary_reference_writes_compressed_block_after_dict_id` |
| 13.5.8 RESET_STATE | Reset clears tables/state references | `test_control_stream_and_control_spec_reset_state_clears_shape_resolution` |

## 18. Encoder Auto-Selection Rules

| Rule cluster | Requirement (short) | Tests |
| --- | --- | --- |
| Dynamic map/shape rules | Repeated-shape promotion, map fallback, key refs | `test_dynamic_profile_shape_promotes_after_second_three_field_map`, `test_dynamic_profile_two_field_map_keeps_map_and_uses_key_ids` |
| Typed vector rules | Array cardinality/type based vectorization | `test_dynamic_profile_typed_vector_threshold_is_applied` |
| String mode rules | Empty/literal/ref/prefix-delta transitions | `test_dynamic_profile_string_modes_empty_ref_and_prefix_delta_are_used` |
| Batch selection rules | Row vs column threshold, micro-batch shape requirement | `test_bound_batch_stateful_batch_threshold_selects_row_vs_column`, `test_bound_batch_stateful_micro_batch_reuses_template_and_emits_changed_mask` |
| Stateful patch threshold | Prefer patch only at low change ratio | `test_bound_batch_stateful_state_patch_uses_recommended_ratio_threshold` |
| Numeric codec choice | i64/u64/float codec heuristics | `test_codec_spec_vectors_xor_float_roundtrip_smooth_series` |

## 15. Trained Dictionary Transport

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 15.4 trained dictionary transport | Dictionary transport carries id/version/hash/invalidation/fallback metadata and validates payload hash | `test_bound_batch_stateful_trained_dictionary_profile_is_transported_to_fresh_decoder`, `test_bound_batch_stateful_invalid_dictionary_profile_hash_is_rejected`, `test_bound_batch_stateful_trained_dictionary_reference_writes_compressed_block_after_dict_id` |

## Cross-Language Interop

| Requirement (short) | Tests |
| --- | --- |
| Fixture encode/decode roundtrip (codec + session streams) | `test_interop_fixtures_codec_encode_decode_roundtrip`, `test_interop_fixtures_session_encode_decode_roundtrip` |
| Decode Rust server fixtures | `test_interop_fixtures_decode_rust_server_frames` |
| Rust client validates Python fixture values | `test_interop_fixtures_rust_decodes_go_frames_with_same_values` |

## Current Gaps (explicit)

- Coverage-boost tests from `twilic-go` (e.g. `TestCoverageBoost_*`) are not yet ported.
- Optional-only extension note: Section 6.4 (zero-copy layout) is not implemented as a conformance target.
- Optional-only extension note: Section 10.7 (static dictionary) is not implemented as a conformance target.
