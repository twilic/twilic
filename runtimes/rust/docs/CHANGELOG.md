# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Avoid temporary integer vectors in direct, delta, FOR, delta-FOR, and delta-of-delta bitpack encoding. Compute block width with a bitwise OR reduction while preserving encoded bytes and decoder behavior.

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.

## [3.1.0] - 2026-07-18

### Added

- Added the v3 Dynamic Profile entry point and route the public `encode` / `decode` APIs through it.
- Added v3 `SCHEMA_BATCH` (`0x0E`) support for schema-order column batches.
- Added v3 `BOUND_STREAM` (`0x0F`) support for compact schema-bound record streams.
- Added public and session encoder APIs for v3 bound streams and schema-aware batches.
- Added v3 migration regression tests for canonical encoding, schema batches, and bound streams.
- GitHub issue templates (feature request and bug report) and pull request template.
- `CONTRIBUTING.md` and commitlint workflow for conventional commit messages on pull requests.

### Changed

- Dynamic integer decoding now rejects non-canonical integer widths.
- Twilic-PV decoding now rejects overlong varuint encodings.
- Renamed the project from Recurram to Twilic. Historical changelog entries still refer to Recurram and gowe where applicable.

### Fixed

- Fixed O(n²) key lookup in `v2::encode_array`: each row previously used `entries.iter().find()` to locate field values by name, but `detect_shape_keys` already guarantees key order matches the shape, so direct iteration is now used instead.

## [2.0.0] - 2026-05-01

### Added

- New default v2 encoder/decoder module for scalar/dynamic values.
- v2 tag families including fixint/fixstr/fixarray/fixmap and compact integer width tags.
- Per-message key and string interning, plus same-shape map-array shape definition reuse.

### Changed

- Public `encode` / `decode` now use the v2 wire path by default.
- Crate version bumped to `2.0.0` for the clean-break format revision.

## [0.1.0] - 2026-03-23

Initial public release of the Rust implementation of Recurram.

### Added

- Core wire format implementation with dynamic `Value` model and `encode` / `decode` APIs.
- Schema-aware encoding, batch encoding, and session-based micro-batch support.
- Stateful transport features including base snapshots, state patch encoding, template batch handling, control stream support, and trained dictionary support.
- Comprehensive test coverage for spec vectors, dynamic profile behavior, control streams, bound batch stateful flows, and broader codec/protocol scenarios.
- Project documentation, MIT licensing, CI automation, and automated crates.io publishing on version tags.

### Changed

- Updated the release documentation in `README.md` for automated publishing.
- Clarified the README license notice.
- Tuned protocol performance in the initial release line.
- Renamed the spec traceability document to `docs/SPEC-TEST-TRACEABILITY.md`.

### Fixed

- Add missing crates.io package metadata (`description`, `license`) so `cargo publish` succeeds.

[unreleased]: https://github.com/twilic/twilic-rust/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/twilic/twilic-rust/compare/v2.0.0...v3.1.0
[2.0.0]: https://github.com/twilic/twilic-rust/compare/v0.1.0...v2.0.0
[0.1.0]: https://github.com/twilic/twilic-rust/releases/tag/v0.1.0
