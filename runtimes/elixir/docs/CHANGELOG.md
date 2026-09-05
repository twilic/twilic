# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- i64 direct/delta bitpack uses zigzag + u64 bitpacking to match [twilic-rust](https://github.com/twilic/twilic-rust) and PHP reference behavior.
- Map all vector codec wire bytes (0–12) in `vector_codec_atom/1`; decode i64 RLE, delta-for, delta-delta, patched-for, and Simple8B instead of falling through to plain.
- Rust client interop script uses `scripts/rust-server-fixtures` (local crate) instead of a non-existent path under `twilic-rust`.
- Protocol decode carries key/string tables across map entries for interop fixtures (e.g. `map_two_fields_second`).

### Added

- Initial Elixir SDK scaffold aligned with other Twilic language repositories (CI, issue templates, markdown tooling).
