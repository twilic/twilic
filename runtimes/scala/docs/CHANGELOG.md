# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.

## [3.0.0] - 2026-05-22

Initial public release of the Scala implementation of Twilic. The default `encode` / `decode` API targets Twilic v2 (v3 support pending).

### Added

- Public Scala 3 API under `io.twilic` with dynamic encode/decode, schema-aware encoding, and batch helpers.
- Protocol core under `io.twilic.internal` (Java sources shared with the reference JVM layout).
- Spec conformance and interop tests with ScalaTest.
- Rust interop fixture scripts under `scripts/`.
- Contributor documentation and Markdown formatting with Prettier and markdownlint.
