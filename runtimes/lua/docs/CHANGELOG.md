# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- PR Message Check: skip template validation for Dependabot pull requests.

## [3.0.0] - 2026-05-22

Initial public release of the Lua implementation of Twilic. The default `Twilic.encode` / `Twilic.decode` API targets Twilic v2 (v3 support pending).

### Added

- Public Lua 5.4 module API via `src/twilic/init.lua`.
- Core modules under `src/twilic/core/` (wire, model, codec, session, protocol, v2).
- Busted specs under `spec/` ported from the Ruby reference tests.
- Rust interop CLI helpers under `bin/` and smoke scripts under `scripts/`.
- LuaRocks rockspec packaging metadata.
- Contributor documentation and Markdown formatting with Prettier and markdownlint.
