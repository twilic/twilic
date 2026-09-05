# SPEC Test Traceability (4/5/6/8/10/13/15/18)

This file maps `twilic/SPEC.md` requirements to Go tests in `twilic-go`.

## 4. v3 Wire Model

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 4.2 Bound and Batch tags | `SCHEMA_BATCH = 0x0E`, `BOUND_STREAM = 0x0F` | `TestV3Migration_SchemaBatchUsesSchemaOrderEnvelope`, `TestV3Migration_BoundStreamUsesNewEnvelopeKind` |
| 4.4 v3 reference defaults | In-band schema id/count and schema-order batch columns | `TestV3Migration_SchemaBatchUsesSchemaOrderEnvelope`, `TestV3Migration_BoundStreamUsesNewEnvelopeKind` |

## 5. Dynamic Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 5.2 key table | First key literal, later key ref by id | `TestDynamicProfile_TwoFieldMapKeepsMapAndUsesKeyIDs` |
| 5.3 shape table | Repeated shape registration/promotion behavior | `TestDynamicProfile_ShapePromotesAfterSecondThreeFieldMap`, `TestCoverageBoost_SessionShapeTableExistingRegistrationPath` |
| 5.4 MAP | Map roundtrip and key-ref decode behavior | `TestCoverageBoost_ProtocolErrorAndControlBranches`, `TestDynamicProfile_TwoFieldMapKeepsMapAndUsesKeyIDs` |
| 5.5 ARRAY | ARRAY vs typed vector threshold behavior | `TestDynamicProfile_TypedVectorThresholdIsApplied`, `TestCoverageBoost_ProtocolDecodeValueForScalarArrayTypedVectorAndShapedObject` |

## 6. Bound Profile

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 6.1 schema | Required field handling, schema decode | `TestCoverageBoost_EncodeWithSchemaRejectsMissingRequiredField`, `TestCoverageBoost_SchemaModeUsesRegisteredSchemaAndRangePacking` |
| 6.2 schema_id | Emit on first use, omit in same context | `TestBoundBatchStateful_SchemaIDIsSentFirstThenOmitted`, `TestCoverageBoost_SchemaIDIsEmittedThenOmittedInSchemaContext` |
| 6.3 SCHEMA_OBJECT | Schema object message roundtrip | `TestCoverageBoost_SchemaModeUsesRegisteredSchemaAndRangePacking` |
| 6.4 BOUND_STREAM | Schema-bound stream envelope, records, schema context requirement | `TestV3Migration_BoundStreamUsesNewEnvelopeKind`, `TestV3Migration_BoundStreamRequiresSchemaContextOnDecode` |

## 8. Numeric Encoding

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 8.1 scalar integer | Canonical Dynamic integer widths | `TestV3Migration_DynamicRejectsNonCanonicalIntegerWidths`, `TestCoverageBoost_WireReaderPositionAndZigzagReaderPaths` |
| 8.2 range-aware bit packing | Bounded integer handling in schema context with fixed-width range offsets | `TestCoverageBoost_SchemaModeUsesRegisteredSchemaAndRangePacking`, `TestCoverageBoost_SchemaRangeModeWritesFixedWidthOffsetBits` |
| 8.4 metadata varuint | Twilic-PV shortest form and max `u64` handling | `TestV3Migration_TwilicPVRejectsOverlongAndAcceptsMaxU64`, `TestV3Migration_DynamicRejectsOverlongVaruintRefs` |
| 8.4 vector integer codecs | Plain/direct/delta/FOR/delta-FOR/delta-delta/RLE/patched/Simple8b | `TestCoverageBoost_CodecVariantsRoundtripAndErrorPath`, `TestCoverageBoost_CodecEmptyPathsAreCovered`, `TestCodecSpecVectors_Simple8bI64RoundtripSmallValues`, `TestCodecSpecVectors_Simple8bU64RoundtripWithLongZeroRuns`, `TestCodecSpecVectors_Simple8bU64FallsBackForLargeValues`, `TestCodecSpecVectors_ForU64OverflowIsRejected`, `TestCodecSpecVectors_DirectBitpackInvalidWidthIsRejected` |
| 8.5 float vector codecs | XOR float vs plain behavior | `TestCoverageBoost_CodecVariantsRoundtripAndErrorPath`, `TestCodecSpecVectors_XorFloatRoundtripSmoothSeries` |

## 10. Strings

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 10.2 LITERAL | Literal mode encode/decode | `TestDynamicProfile_StringModesEmptyRefAndPrefixDeltaAreUsed` |
| 10.3 REF | String ref reuse behavior | `TestDynamicProfile_StringModesEmptyRefAndPrefixDeltaAreUsed`, `TestDynamicProfile_ResetTablesClearsStringInterning` |
| 10.4 PREFIX_DELTA | Prefix-delta mode encode/decode | `TestDynamicProfile_StringModesEmptyRefAndPrefixDeltaAreUsed`, `TestCoverageBoost_ProtocolErrorAndControlBranches` |
| 10.5 string table | Reset clears string table state | `TestDynamicProfile_ResetTablesClearsStringInterning`, `TestCoverageBoost_ProtocolErrorAndControlBranches` |
| 10.6 field-local dictionary | String dictionary/ref behavior in column codec path | `TestCoverageBoost_BatchCodecSelectionAndNullStrategyPaths` |
| 10.8 INLINE_ENUM | Control-driven enum promotion path | `TestCoverageBoost_InlineEnumControlIsAppliedToMapStringField`, `TestCoverageBoost_EncodeDecodeAllControlMessageVariants` |

## 13. Batch / Stateful Extensions

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 13.1 ROW_BATCH | Small batch uses row batch | `TestBoundBatchStateful_BatchThresholdSelectsRowVsColumn`, `TestCoverageBoost_MicroBatchFallsBackWhenShapeIsNotUniform` |
| 13.2 COLUMN_BATCH | Large batch uses column batch and null strategy paths | `TestBoundBatchStateful_BatchThresholdSelectsRowVsColumn`, `TestCoverageBoost_BatchCodecSelectionAndNullStrategyPaths` |
| 13.2A SCHEMA_BATCH | Schema-aware columnar batch in schema order | `TestV3Migration_SchemaBatchUsesSchemaOrderEnvelope` |
| 13.5.1 session state | Unknown reference policy behavior (base/template/dict families) | `TestCoverageBoost_UnknownReferenceStatelessRetryPaths`, `TestCoverageBoost_UnknownDictReferenceFailFastPath`, `TestBoundBatchStateful_UnknownBaseIDHonorsStatelessRetryPolicy` |
| 13.5.2 BASE_SNAPSHOT | Snapshot registration/reference | `TestCoverageBoost_RegisterAndUseBaseSnapshotReference` |
| 13.5.3 STATE_PATCH | Patch roundtrip and bounds checks | `TestCoverageBoost_RegisterAndUseBaseSnapshotReference`, `TestCoverageBoost_MapKeyChangeDoesNotUseStatePatch` |
| 13.5.4 previous-message patch | Previous-message patch selection | `TestBoundBatchStateful_StatePatchUsesRecommendedRatioThreshold`, `TestTwilic_PatchSelectionUsesPreviousBaseForSafeInterop` |
| 13.5.5 TEMPLATE_BATCH | Template create/reuse and changed mask | `TestBoundBatchStateful_MicroBatchReusesTemplateAndEmitsChangedMask` |
| 13.5.6 CONTROL_STREAM | Plain/RLE/Bitpack/Huffman/Fse paths and compaction behavior | `TestControlStreamAndControlSpec_ControlStreamRoundtripsForAllDeclaredCodecs`, `TestControlStreamAndControlSpec_ControlStreamBitpackHuffmanFseCompactRepetitivePayloads`, `TestControlStreamAndControlSpec_ControlStreamFseUsesFseFrameMode`, `TestCoverageBoost_ControlStreamRleRoundtrip` |
| 13.5.7 trained dictionary | Dictionary id assignment and `dict_id + compressed block` path in column encoding | `TestCoverageBoost_BatchCodecSelectionAndNullStrategyPaths`, `TestBoundBatchStateful_ColumnBatchAssignsDictionaryIDForRepeatedStringField`, `TestBoundBatchStateful_TrainedDictionaryProfileIsTransportedToFreshDecoder`, `TestBoundBatchStateful_TrainedDictionaryReferenceWritesCompressedBlockAfterDictID` |
| 13.5.8 RESET_STATE | Reset clears tables/state references | `TestControlStreamAndControlSpec_ResetStateClearsShapeResolution`, `TestCoverageBoost_ProtocolErrorAndControlBranches` |

## 18. Encoder Auto-Selection Rules

| Rule cluster | Requirement (short) | Tests |
| --- | --- | --- |
| Dynamic map/shape rules | Repeated-shape promotion, map fallback, key refs | `TestDynamicProfile_ShapePromotesAfterSecondThreeFieldMap`, `TestDynamicProfile_TwoFieldMapKeepsMapAndUsesKeyIDs` |
| Typed vector rules | Array cardinality/type based vectorization | `TestDynamicProfile_TypedVectorThresholdIsApplied`, `TestCoverageBoost_TryMakeTypedVectorPathsForAllPrimitiveFamilies` |
| String mode rules | Empty/literal/ref/prefix-delta transitions | `TestDynamicProfile_StringModesEmptyRefAndPrefixDeltaAreUsed` |
| Batch selection rules | Row vs column threshold, micro-batch shape requirement | `TestBoundBatchStateful_BatchThresholdSelectsRowVsColumn`, `TestCoverageBoost_MicroBatchFallsBackWhenShapeIsNotUniform` |
| Stateful patch threshold | Prefer patch only at low change ratio | `TestBoundBatchStateful_StatePatchUsesRecommendedRatioThreshold`, `TestCoverageBoost_PatchThresholdPrefersFullMessageWhenChangeRatioIsHigh` |
| Numeric codec choice | i64/u64/float codec heuristics | `TestCoverageBoost_CodecVariantsRoundtripAndErrorPath`, `TestTwilic_CodecSelectionUsesDeltaDeltaForRegularSeries`, `TestCodecSpecVectors_XorFloatRoundtripSmoothSeries` |

## 15. Trained Dictionary Transport

| SPEC section | Requirement (short) | Tests |
| --- | --- | --- |
| 15.4 trained dictionary transport | Dictionary transport carries id/version/hash/invalidation/fallback metadata and validates payload hash | `TestBoundBatchStateful_TrainedDictionaryProfileIsTransportedToFreshDecoder`, `TestBoundBatchStateful_InvalidDictionaryProfileHashIsRejected`, `TestBoundBatchStateful_TrainedDictionaryReferenceWritesCompressedBlockAfterDictID` |

## Current Gaps (explicit)

- No mandatory-gap items are currently tracked.
- Optional-only extension note: Section 6.4 (zero-copy layout) is not implemented as a conformance target.
- Optional-only extension note: Section 10.7 (static dictionary) is not implemented as a conformance target.
