# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[unreleased]: https://github.com/twilic/twilic-go/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/twilic/twilic-go/releases/tag/v3.0.0
