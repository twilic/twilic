# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.0] - 2026-05-24

Initial public release of the Java implementation of Twilic. The default `encode` / `decode` API targets Twilic v2 (v3 support pending), tracking lockstep with [runtimes/rust](https://github.com/twilic/twilic/tree/main/runtimes/rust), [runtimes/go](https://github.com/twilic/twilic/tree/main/runtimes/go), and [runtimes/python](https://github.com/twilic/twilic/tree/main/runtimes/python).

### Added

- Public package API at `io.twilic` with implementation under `io.twilic.internal.core`.
- Core wire format with dynamic `Value` model and `encode` / `decode` APIs.
- Schema-aware encoding (`encodeWithSchema`), batch encoding (`encodeBatch`), and session-based micro-batch and patch support.
- Stateful transport features: base snapshots, state patch encoding, template batch handling, control stream support, and trained dictionary support.
- Spec conformance tests and traceability mapping in [`docs/SPEC-TEST-TRACEABILITY.md`](SPEC-TEST-TRACEABILITY.md).
- Rust interop fixture stream, value parity tests, and bidirectional smoke scripts under `scripts/`.
- Gradle publishing metadata and contributor documentation.
- Markdown formatting with Prettier and markdownlint.

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.
