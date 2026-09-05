# SPEC Test Traceability (5/6/8/10/13/15/18)

This file maps `twilic/SPEC.md` requirements to Rust tests in `twilic-rust/tests`.

## 5. Dynamic Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 5.2 key table | First key literal, later key ref by id | `tests/dynamic_profile_spec.rs::two_field_map_keeps_map_and_uses_key_ids` |
| 5.3 shape table | Repeated shape registration/promotion behavior | `tests/dynamic_profile_spec.rs::shape_promotes_after_second_three_field_map`, `tests/coverage_boost.rs::session_shape_table_existing_registration_path` |
| 5.4 MAP | Map roundtrip and key-ref decode behavior | `tests/coverage_boost.rs::protocol_error_and_control_branches`, `tests/dynamic_profile_spec.rs::two_field_map_keeps_map_and_uses_key_ids` |
| 5.5 ARRAY | ARRAY vs typed vector threshold behavior | `tests/dynamic_profile_spec.rs::typed_vector_threshold_is_applied`, `tests/coverage_boost.rs::protocol_decode_value_for_scalar_array_typed_vector_and_shaped_object` |

## 6. Bound Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 6.1 schema | Required field handling, schema decode | `tests/coverage_boost.rs::encode_with_schema_rejects_missing_required_field`, `tests/coverage_boost.rs::schema_mode_uses_registered_schema_and_range_packing` |
| 6.2 schema_id | Emit on first use, omit in same context | `tests/bound_batch_stateful_spec.rs::schema_id_is_sent_first_then_omitted`, `tests/coverage_boost.rs::schema_id_is_emitted_then_omitted_in_schema_context` |
| 6.3 SCHEMA_OBJECT | Schema object message roundtrip | `tests/coverage_boost.rs::schema_mode_uses_registered_schema_and_range_packing` |

## 8. Numeric Encoding

Integer bitpack wire compatibility (§8.5.1–8.5.4, §8.5.6) is additionally checked by `tests/integer_bitpack_compat.rs`. Its independent bit-at-a-time encoder covers all widths from 1 to 64, signed/unsigned limits, empty and short blocks, varied block lengths, deterministic random input, and appending to an existing buffer.

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 8.1 scalar integer | Zigzag/varuint scalar integer behavior | `tests/coverage_boost.rs::wire_reader_position_and_zigzag_reader_paths` |
| 8.2 range-aware bit packing | Bounded integer handling in schema context with fixed-width range offsets | `tests/coverage_boost.rs::schema_mode_uses_registered_schema_and_range_packing`, `tests/coverage_boost.rs::schema_range_mode_writes_fixed_width_offset_bits` |
| 8.4 vector integer codecs | Plain/direct/delta/FOR/delta-FOR/delta-delta/RLE/patched/Simple8b | `tests/coverage_boost.rs::codec_variants_roundtrip_and_error_path`, `tests/coverage_boost.rs::codec_empty_paths_are_covered`, `tests/codec_spec_vectors.rs::simple8b_i64_roundtrip_small_values`, `tests/codec_spec_vectors.rs::simple8b_u64_roundtrip_with_long_zero_runs`, `tests/codec_spec_vectors.rs::simple8b_u64_falls_back_for_large_values`, `tests/codec_spec_vectors.rs::for_u64_overflow_is_rejected`, `tests/codec_spec_vectors.rs::direct_bitpack_invalid_width_is_rejected` |
| 8.5 float vector codecs | XOR float vs plain behavior | `tests/coverage_boost.rs::codec_variants_roundtrip_and_error_path`, `tests/codec_spec_vectors.rs::xor_float_roundtrip_smooth_series` |

## 10. Strings

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 10.2 LITERAL | Literal mode encode/decode | `tests/dynamic_profile_spec.rs::string_modes_empty_ref_and_prefix_delta_are_used` |
| 10.3 REF | String ref reuse behavior | `tests/dynamic_profile_spec.rs::string_modes_empty_ref_and_prefix_delta_are_used`, `tests/dynamic_profile_spec.rs::reset_tables_clears_string_interning` |
| 10.4 PREFIX_DELTA | Prefix-delta mode encode/decode | `tests/dynamic_profile_spec.rs::string_modes_empty_ref_and_prefix_delta_are_used`, `tests/coverage_boost.rs::protocol_error_and_control_branches` |
| 10.5 string table | Reset clears string table state | `tests/dynamic_profile_spec.rs::reset_tables_clears_string_interning`, `tests/coverage_boost.rs::protocol_error_and_control_branches` |
| 10.6 field-local dictionary | String dictionary/ref behavior in column codec path | `tests/coverage_boost.rs::batch_codec_selection_and_null_strategy_paths` |
| 10.8 INLINE_ENUM | Control-driven enum promotion path | `tests/coverage_boost.rs::inline_enum_control_is_applied_to_map_string_field`, `tests/coverage_boost.rs::encode_decode_all_control_message_variants` |

## 13. Batch / Stateful Extensions

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 13.1 ROW_BATCH | Small batch uses row batch | `tests/bound_batch_stateful_spec.rs::batch_threshold_selects_row_vs_column`, `tests/coverage_boost.rs::micro_batch_falls_back_when_shape_is_not_uniform` |
| 13.2 COLUMN_BATCH | Large batch uses column batch and null strategy paths | `tests/bound_batch_stateful_spec.rs::batch_threshold_selects_row_vs_column`, `tests/coverage_boost.rs::batch_codec_selection_and_null_strategy_paths` |
| 13.5.1 session state | Unknown reference policy behavior (base/template/dict families) | `tests/coverage_boost.rs::unknown_reference_stateless_retry_paths`, `tests/coverage_boost.rs::unknown_dict_reference_fail_fast_path`, `tests/bound_batch_stateful_spec.rs::unknown_base_id_honors_stateless_retry_policy` |
| 13.5.2 BASE_SNAPSHOT | Snapshot registration/reference | `tests/coverage_boost.rs::register_and_use_base_snapshot_reference` |
| 13.5.3 STATE_PATCH | Patch roundtrip and bounds checks | `tests/coverage_boost.rs::register_and_use_base_snapshot_reference`, `tests/coverage_boost.rs::map_key_change_does_not_use_state_patch` |
| 13.5.4 previous-message patch | Previous-message patch selection | `tests/bound_batch_stateful_spec.rs::state_patch_uses_recommended_ratio_threshold`, `src/lib.rs::tests::patch_selection_uses_previous_base_for_safe_interop` |
| 13.5.5 TEMPLATE_BATCH | Template create/reuse and changed mask | `tests/bound_batch_stateful_spec.rs::micro_batch_reuses_template_and_emits_changed_mask` |
| 13.5.6 CONTROL_STREAM | Plain/RLE/Bitpack/Huffman/Fse paths and compaction behavior | `tests/control_stream_and_control_spec.rs::control_stream_roundtrips_for_all_declared_codecs`, `tests/control_stream_and_control_spec.rs::control_stream_bitpack_huffman_fse_compact_repetitive_payloads`, `tests/control_stream_and_control_spec.rs::control_stream_fse_uses_fse_frame_mode`, `tests/coverage_boost.rs::control_stream_rle_roundtrip` |
| 13.5.7 trained dictionary | Dictionary id assignment and `dict_id + compressed block` path in column encoding | `tests/coverage_boost.rs::batch_codec_selection_and_null_strategy_paths`, `tests/bound_batch_stateful_spec.rs::column_batch_assigns_trained_dictionary_id_for_repeated_string_field`, `tests/bound_batch_stateful_spec.rs::trained_dictionary_profile_is_transported_to_fresh_decoder`, `tests/bound_batch_stateful_spec.rs::trained_dictionary_reference_writes_compressed_block_after_dict_id` |
| 13.5.8 RESET_STATE | Reset clears tables/state references | `tests/control_stream_and_control_spec.rs::reset_state_clears_shape_resolution`, `tests/coverage_boost.rs::protocol_error_and_control_branches` |

## 18. Encoder Auto-Selection Rules

| Rule cluster | Requirement (short) | Tests |
| --- | --- | --- |
| Dynamic map/shape rules | Repeated-shape promotion, map fallback, key refs | `tests/dynamic_profile_spec.rs::shape_promotes_after_second_three_field_map`, `tests/dynamic_profile_spec.rs::two_field_map_keeps_map_and_uses_key_ids` |
| Typed vector rules | Array cardinality/type based vectorization | `tests/dynamic_profile_spec.rs::typed_vector_threshold_is_applied`, `tests/coverage_boost.rs::try_make_typed_vector_paths_for_all_primitive_families` |
| String mode rules | Empty/literal/ref/prefix-delta transitions | `tests/dynamic_profile_spec.rs::string_modes_empty_ref_and_prefix_delta_are_used` |
| Batch selection rules | Row vs column threshold, micro-batch shape requirement | `tests/bound_batch_stateful_spec.rs::batch_threshold_selects_row_vs_column`, `tests/coverage_boost.rs::micro_batch_falls_back_when_shape_is_not_uniform` |
| Stateful patch threshold | Prefer patch only at low change ratio | `tests/bound_batch_stateful_spec.rs::state_patch_uses_recommended_ratio_threshold`, `tests/coverage_boost.rs::patch_threshold_prefers_full_message_when_change_ratio_is_high` |
| Numeric codec choice | i64/u64/float codec heuristics | `tests/coverage_boost.rs::codec_variants_roundtrip_and_error_path`, `src/lib.rs::tests::codec_selection_uses_delta_delta_for_regular_series`, `tests/codec_spec_vectors.rs::xor_float_roundtrip_smooth_series` |
| Deterministic template selection | Reused template descriptors resolve to the lowest matching template id deterministically | `src/protocol.rs::tests::find_template_id_prefers_lowest_matching_id` |

## 15. Trained Dictionary Transport

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 15.4 trained dictionary transport | Dictionary transport carries id/version/hash/invalidation/fallback metadata and validates payload hash | `tests/bound_batch_stateful_spec.rs::trained_dictionary_profile_is_transported_to_fresh_decoder`, `tests/bound_batch_stateful_spec.rs::invalid_dictionary_profile_hash_is_rejected`, `tests/bound_batch_stateful_spec.rs::trained_dictionary_reference_writes_compressed_block_after_dict_id` |

## Current Gaps (explicit)

- No mandatory-gap items are currently tracked.
- Optional-only extension note: Section 6.4 (zero-copy layout) is not implemented as a conformance target.
- Optional-only extension note: Section 10.7 (static dictionary) is not implemented as a conformance target.
