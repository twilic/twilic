# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.

## [3.0.0] - 2026-05-22

Initial public release of the R implementation of Twilic. The default `encode` / `decode` API targets Twilic v2 (v3 support pending), with session protocol coverage and Rust interop fixtures aligned to [runtimes/ruby](https://github.com/twilic/twilic/tree/main/runtimes/ruby).

### Added

- Native R package API (`encode`, `decode`, session helpers) with sources under `R/`.
- V2 wire format, session protocol (patches, batches, control streams, dictionaries), and interop fixtures.
- Spec tests via testthat and package metadata in `DESCRIPTION`.
- Contributor documentation and Markdown formatting with Prettier and markdownlint.
