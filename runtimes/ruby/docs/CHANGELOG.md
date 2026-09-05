# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.0] - 2026-05-24

Initial public release of the Ruby implementation of Twilic, tracking the v3 release line shared with [twilic-rust](https://github.com/twilic/twilic-rust) and [twilic-js](https://github.com/twilic/twilic-js).

### Added

- Core wire format with dynamic `Value` model and `Encode` / `Decode` APIs.
- Schema-aware encoding (`encode_with_schema`), batch encoding (`encode_batch`), and session-based micro-batch and patch support.
- Stateful transport features: base snapshots, state patch encoding, template batch handling, control stream support, and trained dictionary support.
- Public gem API at `Twilic` with implementation under `lib/twilic/core/`.
- Spec conformance tests and traceability mapping in [`docs/SPEC-TEST-TRACEABILITY.md`](SPEC-TEST-TRACEABILITY.md).
- Rust interop fixture stream, value parity tests, and bidirectional smoke scripts under `scripts/`.
- Interop helpers in `lib/twilic/core/interop_fixtures.rb` for cross-language fixture emission and decoding.
- GitHub Actions workflows for CI, Interop, commitlint, invisible character check, PR message validation, and tagged gem publish via RubyGems Trusted Publishing (OIDC).
- GitHub issue templates, pull request template, and contributor documentation.
- Markdown formatting with Prettier and markdownlint.

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.

[unreleased]: https://github.com/twilic/twilic-ruby/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/twilic/twilic-ruby/releases/tag/v3.0.0
