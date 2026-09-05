<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.1.0] - 2026-07-18

### Added

- Added v3 `encodeBoundStream` and `encodeBatchWithSchema` APIs for schema-bound streams and schema-aware batches.
- Exposed v3 schema batch and bound stream entry points through `twilic-bridge`, N-API, WASM, runtime adapters, `index`, and `advanced` exports.
- Added session encoder support for v3 bound streams and schema-aware batches.
- Added Node and WASM regression tests that assert v3 `BOUND_STREAM` (`0x0F`) and `SCHEMA_BATCH` (`0x0E`) message kinds.
- WASM backend: native compact and direct encode/decode paths via `twilic-bridge` (no transport-JSON fallback for compact APIs; direct paths use the fast transport parser) (#3).

### Changed

- Updated the pinned `twilic-rust` reference to v3.1.0 so CI and release builds use the Rust v3 implementation.
- Generalized fallback decode errors from v2-specific wording to payload-level wording.

### Fixed

- `publish-npm.yml`: split build and OIDC publish jobs so `id-token` is only available during `npm publish`, add `environment: npm-publish`, and verify release tags are ancestors of `main` (#12, #14).
- Commit `Cargo.lock` and pass `--locked` to Rust builds in CI and publish so release artifacts use reviewed dependency versions (#11).
- npm `files:` allowlist no longer ships `crates/` or `scripts/`; `build:wasm` removes `wasm/pkg/.gitignore` so WASM artifacts are included; `verify:pack` guards the publish tarball (#10).
- CI and publish workflows: pin `twilic/twilic-rust` via `.github/twilic-rust-ref` instead of an unpinned `git clone` of default branch (#16).
- N-API v2 decoder: bound shape/array/map allocation sizes and use `try_reserve` so hostile varuints return catchable errors instead of aborting the Node process (#7).
- `measure-bundle.mjs`: use `npm pack --ignore-scripts` so prepack build logs do not break `--json` parsing in PR bundle reports (#31).
- Decoders enforce a default maximum nesting depth of 64 for v2 arrays and maps in the TypeScript fast codec, N-API native v2 path, and `twilic-rust` v2 decode used by the bridge/WASM backends; exceeding the limit throws `TwilicDecodeError` in JS or returns a depth-limit error in native/WASM paths (#8).
- PR Message Check: skip template validation for Dependabot pull requests.
- CI and publish workflows: explicit `permissions: contents: read` and `persist-credentials: false` on checkout steps that do not push (#17).
- `publish-npm.yml`: route `workflow_dispatch` tag input through env vars instead of shell interpolation (#13).
- CI and publish workflows: SHA-pin third-party GitHub Actions (#15).
- `init({ wasmInput })`: narrow `wasmInput` from `unknown` to explicit `WasmInput` union (#9).

## [3.0.0] - 2026-05-17

### Changed

- Renamed the npm package from `twilic` to `@twilic/core`.
- Renamed the project from Recurram to Twilic. Historical changelog entries still refer to Recurram and gowe where applicable.

### Added

- GitHub issue templates (feature request and bug report) and pull request template.
- CI `test-wasm` job that builds the WASM package and runs browser runtime tests.
- PR workflow that posts benchmark and npm bundle-size diffs against the base branch.
- Direct v2-to-JS NAPI decoder (`try_decode_v2_native`) that builds JS objects straight from v2 wire bytes without an intermediate Rust `Value` tree, improving `decode` throughput by ~72%.
- `js_to_recurram_value` NAPI helper using raw NAPI API for JS→Rust value conversion with full `BigInt` support via `get_bigint_u64_raw` / `get_bigint_i64_raw`.
- `encodeBatchNativeRaw` NAPI function that converts a JS array directly to `Vec<Value>` using the raw NAPI traversal API, avoiding `serde_json::Value` and the associated BigInt panic.
- `getrandom` dependency with `wasm_js` feature in `recurram-wasm` to satisfy the `wasm32-unknown-unknown` target requirement introduced by `recurram v2.0.0`.

### Changed

- `decode()` in the JS layer now uses the `decodeNative` fast path on the N-API backend (restored from the v2 migration).
- Integer encoding for JS `number` values in `encodeFast` is now fully inlined: `BigInt()` conversion is avoided for integers up to 2³² so encoding stays in the `number` type space for all common data.
- `ByteWriter.writeVaruint` now takes a direct fast path for values < 128 and replaces `% 0x80` with `& 0x7f` in the loop body.
- `getCachedUtf8` no longer skips the cache for strings longer than 64 bytes; the existing 4096-entry eviction bound already limits memory use.
- `ByteWriter` is now pooled at module level with a `reset()` + `finish()` (copy) API, eliminating per-call allocation and repeated buffer growth.
- `EncodeState` Maps (`keyIds`, `stringIds`, `shapeIds`) are now pooled at module level and cleared per call instead of being recreated on every `encodeFast` invocation.
- N-API backend `decode_native_napi` now skips the compact-protocol attempt for v2 bytes (first byte > `0x02`), avoiding wasted parsing work.
- `recurram-bridge` and `recurram-napi` Cargo dependencies now reference the local `twilic-rust` crate via a workspace-relative path instead of the published `recurram = "0.1.0"`, ensuring the v2 codec is used throughout.
- npm publish workflow updated to the current publishing method.

### Fixed

- Map decoders reject attacker-controlled keys (`__proto__`, `constructor`, `prototype`) to prevent prototype pollution; the N-API decoder skips unsafe keys before `napi_set_property` / `napi_set_named_property`.
- Published npm package now ships platform-specific native addons for Linux, macOS, and Windows instead of a single Linux binary loaded on all platforms.
- CI workflow (`ci.yml`): added a `git clone` step to check out `twilic-rust` alongside `twilic-js` before the Rust build, fixing the `failed to read twilic-rust/Cargo.toml` error that caused all CI jobs to fail.
- CI: pinned `wasm-pack` to v0.13.0 so the `--no-opt` flag used by `pnpm build:wasm` remains accepted.
- CI: benchmark checkout uses the `benchmark` repository instead of `twilic-bench`.
- `encodeBatchNativeRaw` no longer panics when the JS array contains `BigInt` values; the function now uses `JsUnknown` with raw NAPI traversal instead of `serde_json::Value`.
- `publish-npm.yml`: clone `twilic-rust` before N-API and WASM builds so release workflows resolve the path dependency on the Rust crate.

## [2.0.0] - 2026-05-01

### Added

- Recurram v2 wire tags with fixint/fixstr/fixarray/fixmap families in the fast TypeScript codec.
- Per-message key and string interning (`key_ref`, `str_ref`) for smaller one-shot JSON payloads.
- In-array same-shape object encoding via shape definition reuse.

### Changed

- `encode()` in the JS fast path now emits v2 wire bytes by default.
- Project release version bumped to `2.0.0` for the v2 clean break.

## [0.1.0] - 2026-03-25

Initial public release of the JavaScript and TypeScript bindings for Recurram.

### Added

- Node.js N-API and browser WASM backends behind a shared `init()` runtime selection API.
- High-level encode and decode APIs for `RecurramValue`, schema-aware encoding, batch encoding, and session-based patch and micro-batch workflows.
- Transport JSON, compact JSON, and direct object fast paths for lower JS-side overhead in hot paths.
- TypeScript type exports for runtime options, schemas, session options, and transport-compatible values including `bigint` and `Uint8Array`.
- Rust bridge crates, N-API packaging, WASM packaging, Node test coverage, CI, npm publish automation, and release tag verification.

### Changed

- Renamed npm package from `gowe` to `recurram`
- Raised the Node.js runtime baseline to `24+` across local tooling, documentation, and publish workflows.
- Expanded the public API with fast-mode helpers for compact encoding, raw transport JSON encoding, direct encoding, and additional session encoder variants.
- Optimized bridge, N-API, WASM, and TypeScript runtime paths to reduce overhead for encode, decode, batch, session, and compact transport operations.

### Fixed

- Corrected the Rust crate path used by the workspace so native builds resolve the bridge crate correctly.

[unreleased]: https://github.com/twilic/twilic-js/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/twilic/twilic-js/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/twilic/twilic-js/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/twilic/twilic-js/compare/v0.1.0...v2.0.0
[0.1.0]: https://github.com/twilic/twilic-js/releases/tag/v0.1.0
