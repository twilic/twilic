# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] - 2026-07-20

### Added

- v3 wire types: `SchemaBatch` (0x0E), `BoundStream` (0x0F), `BoundRecord`, `PresenceStrategy`, `PhysicalEncoding`.
- `physical_encoding` field on `SchemaField` for explicit per-field integer encoding.
- `encodeBoundStream` / `encodeBatchWithSchema` public API for v3 schema-bound streams and columnar batches.
- Dedicated `writeSchemaBatchColumn`/`readSchemaBatchColumn` methods matching Rust/Go wire format (no field_id, no dict_info/separator byte).
- `encodeFixedBitmap`/`readFixedBitmap` helpers for fixed-size bitmaps (no varuint length prefix).
- GitHub issue templates (feature request and bug report), pull request template, and PR message validation workflow.
- `src/v2.zig` module; public `encode` and `decode` now route through the v2 codec path by default.

### Changed

- Renamed the project from Recurram to Twilic. Historical changelog entries still refer to Recurram where applicable.
- Minimum Zig version bumped to `0.16.0` (replaced all `std.meta.intToEnum` with switch statements).
- Bound Profile field encoding now matches v3 spec: no per-field fallback mode bytes on the wire.
- `ArrayListUnmanaged` default init updated for Zig 0.16.
- `writeBoundRecord`/`readBoundRecord` use fixed-size bitmaps matching Rust/Go reference implementations.
- Wire format for `SCHEMA_BATCH` columns matches Rust/Go: `[null_strategy][presence?][codec][typed_vector]`.

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.
- Updated `build.zig.zon` package fingerprint after dependency changes.

## [2.0.0] - 2026-05-01

### Changed

- Project version bumped to `2.0.0` for alignment with the Recurram v2 release line.
- Documentation updated to point to the v2 active specification profile.

[3.0.0]: https://github.com/twilic/twilic-zig/releases/tag/v3.0.0
[2.0.0]: https://github.com/twilic/twilic-zig/releases/tag/v2.0.0
