# SPEC Test Traceability (5/6/8/10/13/15/18)

This file maps `twilic/SPEC.md` requirements to JUnit tests in `twilic-kotlin` (Java test sources).

## 5. Dynamic Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 5.2 key table | First key literal, later key ref by id | `DynamicProfileSpecTest.twoFieldMapKeepsMapAndUsesKeyIds` |
| 5.3 shape table | Repeated shape registration/promotion behavior | `DynamicProfileSpecTest.shapePromotesAfterSecondThreeFieldMap` |
| 5.4 MAP | Map roundtrip and key-ref decode behavior | `DynamicProfileSpecTest.twoFieldMapKeepsMapAndUsesKeyIds` |
| 5.5 ARRAY | ARRAY vs typed vector threshold behavior | `DynamicProfileSpecTest.typedVectorThresholdIsApplied` |

## 6. Bound Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 6.2 schema_id | Emit on first use, omit in same context | `BoundBatchStatefulSpecTest.schemaIdIsSentFirstThenOmitted` |
| 6.3 SCHEMA_OBJECT | Schema object message roundtrip | `BoundBatchStatefulSpecTest.schemaIdIsSentFirstThenOmitted` |

## 8. Numeric Encoding

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 8.4 vector integer codecs | Plain/direct/delta/FOR/delta-FOR/delta-delta/RLE/patched/Simple8b | `CodecSpecVectorsTest.simple8bI64RoundtripSmallValues`, `CodecSpecVectorsTest.simple8bU64RoundtripWithLongZeroRuns`, `CodecSpecVectorsTest.simple8bU64FallsBackForLargeValues`, `CodecSpecVectorsTest.forU64OverflowIsRejected`, `CodecSpecVectorsTest.directBitpackInvalidWidthIsRejected` |
| 8.5 float vector codecs | XOR float vs plain behavior | `CodecSpecVectorsTest.xorFloatRoundtripSmoothSeries` |

## 10. Strings

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 10.2 LITERAL | Literal mode encode/decode | `DynamicProfileSpecTest.stringModesEmptyRefAndPrefixDeltaAreUsed` |
| 10.3 REF | String ref reuse behavior | `DynamicProfileSpecTest.stringModesEmptyRefAndPrefixDeltaAreUsed`, `DynamicProfileSpecTest.resetTablesClearsStringInterning` |
| 10.4 PREFIX_DELTA | Prefix-delta mode encode/decode | `DynamicProfileSpecTest.stringModesEmptyRefAndPrefixDeltaAreUsed` |
| 10.5 string table | Reset clears string table state | `DynamicProfileSpecTest.resetTablesClearsStringInterning` |
| 10.6 field-local dictionary | String dictionary/ref behavior in column codec path | `BoundBatchStatefulSpecTest.columnBatchAssignsDictionaryIdForRepeatedStringField` |

## 13. Batch / Stateful Extensions

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 13.1 ROW_BATCH | Small batch uses row batch | `BoundBatchStatefulSpecTest.batchThresholdSelectsRowVsColumn` |
| 13.2 COLUMN_BATCH | Large batch uses column batch and null strategy paths | `BoundBatchStatefulSpecTest.batchThresholdSelectsRowVsColumn`, `BoundBatchStatefulSpecTest.columnBatchAssignsDictionaryIdForRepeatedStringField` |
| 13.5.1 session state | Unknown reference policy behavior (base/template/dict families) | `BoundBatchStatefulSpecTest.unknownBaseIdHonorsStatelessRetryPolicy` |
| 13.5.3 STATE_PATCH | Patch roundtrip and bounds checks | `BoundBatchStatefulSpecTest.statePatchMapInsertAndDeleteRoundtripViaReconstruction` |
| 13.5.4 previous-message patch | Previous-message patch selection | `BoundBatchStatefulSpecTest.statePatchUsesRecommendedRatioThreshold` |
| 13.5.5 TEMPLATE_BATCH | Template create/reuse and changed mask | `BoundBatchStatefulSpecTest.microBatchReusesTemplateAndEmitsChangedMask` |
| 13.5.6 CONTROL_STREAM | Plain/RLE/Bitpack/Huffman/Fse paths and compaction behavior | `ControlStreamAndControlSpecTest.controlStreamRoundtripsForAllDeclaredCodecs`, `ControlStreamAndControlSpecTest.controlStreamBitpackHuffmanFseCompactRepetitivePayloads`, `ControlStreamAndControlSpecTest.controlStreamFseUsesFseFrameMode` |
| 13.5.7 trained dictionary | Dictionary id assignment and `dict_id + compressed block` path in column encoding | `BoundBatchStatefulSpecTest.columnBatchAssignsDictionaryIdForRepeatedStringField`, `BoundBatchStatefulSpecTest.trainedDictionaryProfileIsTransportedToFreshDecoder`, `BoundBatchStatefulSpecTest.trainedDictionaryReferenceWritesCompressedBlockAfterDictId` |
| 13.5.8 RESET_STATE | Reset clears tables/state references | `ControlStreamAndControlSpecTest.resetStateClearsShapeResolution` |

## 18. Encoder Auto-Selection Rules

| Rule cluster | Requirement (short) | Tests |
| --- | --- | --- |
| Dynamic map/shape rules | Repeated-shape promotion, map fallback, key refs | `DynamicProfileSpecTest.shapePromotesAfterSecondThreeFieldMap`, `DynamicProfileSpecTest.twoFieldMapKeepsMapAndUsesKeyIds` |
| Typed vector rules | Array cardinality/type based vectorization | `DynamicProfileSpecTest.typedVectorThresholdIsApplied` |
| String mode rules | Empty/literal/ref/prefix-delta transitions | `DynamicProfileSpecTest.stringModesEmptyRefAndPrefixDeltaAreUsed` |
| Batch selection rules | Row vs column threshold, micro-batch shape requirement | `BoundBatchStatefulSpecTest.batchThresholdSelectsRowVsColumn`, `BoundBatchStatefulSpecTest.microBatchReusesTemplateAndEmitsChangedMask` |
| Stateful patch threshold | Prefer patch only at low change ratio | `BoundBatchStatefulSpecTest.statePatchUsesRecommendedRatioThreshold` |
| Numeric codec choice | i64/u64/float codec heuristics | `CodecSpecVectorsTest.xorFloatRoundtripSmoothSeries` |

## 15. Trained Dictionary Transport

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 15.4 trained dictionary transport | Dictionary transport carries id/version/hash/invalidation/fallback metadata and validates payload hash | `BoundBatchStatefulSpecTest.trainedDictionaryProfileIsTransportedToFreshDecoder`, `BoundBatchStatefulSpecTest.invalidDictionaryProfileHashIsRejected`, `BoundBatchStatefulSpecTest.trainedDictionaryReferenceWritesCompressedBlockAfterDictId` |

## Cross-Language Interop

| Requirement (short) | Tests |
| --- | --- |
| Fixture encode/decode roundtrip (codec + session streams) | `InteropFixturesTest.codecEncodeDecodeRoundtrip`, `InteropFixturesTest.sessionEncodeDecodeRoundtrip` |
| Decode Rust server fixtures | `InteropFixturesTest.decodeRustServerFrames` |
| Rust client validates Kotlin fixture values | `InteropFixturesTest.rustDecodesJavaFramesWithSameValues`, `scripts/check-rust-client-interop.sh` |
| Rust server → Kotlin client (smoke) | `InteropFixturesTest.decodeRustServerFrames`, `scripts/check-kotlin-client-interop.sh` |

## Current Gaps (explicit)

- Coverage-boost tests from `twilic-go` (e.g. `TestCoverageBoost_*`) are not yet ported.
- Optional-only extension note: Section 6.4 (zero-copy layout) is not implemented as a conformance target.
- Optional-only extension note: Section 10.7 (static dictionary) is not implemented as a conformance target.
