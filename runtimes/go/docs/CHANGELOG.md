# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.1.0] - 2026-07-19

### Added

- **v3 Wire Model: `SCHEMA_BATCH` (0x0E) and `BOUND_STREAM` (0x0F) message kinds.**
  - New model types: `SchemaBatchMessage`, `BoundStreamMessage`, `BoundRecord`, `PresenceStrategy`.
  - Wire encode/decode for schema-order columnar batch and schema-bound compact stream envelopes.
  - Envelope structure: in-band schema id, record/row count, column count / presence strategy.
- **Public API: `EncodeBoundStream` and `EncodeBatchWithSchema` functions.**
  - Expose `BoundRecord`, `PresenceStrategy`, `SchemaBatchMessage`, `BoundStreamMessage` types and constants.
- **v3 Schema-aware field encoding for Bound Profile.**
  - Type-specific code paths for `bool`, `u8`/`u16`/`u32`/`u64`, `i8`/`i16`/`i32`/`i64`, `f64`, `string` (with enum dispatch), and `binary` logical types.
  - Range-aware bit packing for bounded integer fields (fixed-width offset).
  - Required field support with default values on encode.
  - Optional presence bitmap with `PresenceStrategyNormal`, `PresenceStrategyInverted`, `PresenceStrategyAllPresent`.
  - Fixed bitmap read/write with padding validation.
- **v3 canonical integer width validation (Dynamic Profile).**
  - Reject non-canonical (overly wide) integer encodings: `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64` tags all enforce shortest form.
  - Reject overlong varuint (Twilic-PV shortest form enforcement) and varuint > max u64.
- **Spec test traceability for v3 spec sections 4, 6, 8, 13.**
  - New `TestV3Migration_*` test suite covering schema batch, bound stream, canonical widths, overlong varuint, schema context validation.
- **Semgrep workflow** for Go static analysis.

### Changed

- `Encode`/`Decode` public doc: "v2 wire profile" → "v3 Dynamic Profile".
- `writeSchemaFieldValue`/`readSchemaFieldValue`: from generic `writeValue` path to type-specific schema field codec.
- Schema presence bitmap: only optional fields tracked (required fields always present, never in bitmap).
- `SessionEncoder.EncodeWithSchema`: uses `registerSchema` helper; emits only optional-field presence.
- `EncodeBatchWithSchema` / `EncodeBoundStream`: register schema, record previous message for stateful patch.
- Publish workflow: remove automated GitHub Release creation (tag-only publish).
- Markdownlint config: allow duplicate CHANGELOG headings.

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.

## [3.0.0] - 2026-05-22

Initial public release of the Go implementation of Twilic, tracking the v3 release line shared with [twilic-rust](https://github.com/twilic/twilic-rust) and [twilic-js](https://github.com/twilic/twilic-js).

### Added

- Core wire format with dynamic `Value` model and `Encode` / `Decode` APIs.
- Schema-aware encoding (`EncodeWithSchema`), batch encoding (`EncodeBatch`), and session-based micro-batch and patch support.
- Stateful transport features: base snapshots, state patch encoding, template batch handling, control stream support, and trained dictionary support.
- Public module API at `github.com/twilic/twilic-go` with implementation under `internal/core/`.
- Spec conformance tests and traceability mapping in [`docs/SPEC-TEST-TRACEABILITY.md`](SPEC-TEST-TRACEABILITY.md).
- Rust interop fixture stream, value parity tests, and bidirectional smoke scripts under `scripts/`.
- GitHub Actions workflows for CI, Interop, commitlint, invisible character check, PR message validation, and tagged module publish.
- GitHub issue templates, pull request template, and contributor documentation.
- Markdown formatting with Prettier and markdownlint.

### Fixed

- Align literal key encoding with twilic-rust so first map fields are not written as unresolved key refs.
- Register shapes on decode after repeated map observations, matching twilic-rust session behavior.
- Skip Rust-dependent interop Go tests when `twilic-rust` is not checked out (fixes CI on the default workflow).

[unreleased]: https://github.com/twilic/twilic-go/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/twilic/twilic-go/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/twilic/twilic-go/releases/tag/v3.0.0
