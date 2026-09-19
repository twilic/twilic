# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.

## [3.0.0] - 2026-05-22

Initial public release of the C implementation of Twilic. The default `twilic_encode` / `twilic_decode` API targets Twilic v2 (v3 support pending), with algorithms aligned to [runtimes/cpp](https://github.com/twilic/twilic/tree/main/runtimes/cpp) and spec coverage aligned to [runtimes/go](https://github.com/twilic/twilic/tree/main/runtimes/go).

### Added

- Public C11 API in `include/twilic/twilic.h` with dynamic encode/decode, schema-aware encoding, and batch helpers.
- Implementation sources under `src/` (wire, model, codec, session, protocol, v2, dictionary, interop fixtures).
- Spec tests under `test/` ported from the Go reference suite (`dynamic_profile`, `bound_batch_stateful`, `codec_spec_vectors`, `control_stream`, `coverage_boost`, `interop_fixtures`).
- Rust interop fixture tools under `tools/` and smoke scripts under `scripts/`.
- Contributor documentation and Markdown formatting with Prettier and markdownlint.
