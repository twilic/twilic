# SPEC Test Traceability (5/6/8/10/13/15/18)

This file maps [`twilic/SPEC.md`](https://github.com/twilic/twilic/blob/main/SPEC.md) requirements to tests in this repository.

Smoke-level coverage is provided by the tests under `test/` (or `tests/`). For the full conformance matrix, see [`twilic-java/docs/SPEC-TEST-TRACEABILITY.md`](https://github.com/twilic/twilic-java/blob/main/docs/SPEC-TEST-TRACEABILITY.md).

## Current status

| Area                  | Status            |
| --------------------- | ----------------- |
| 5 Dynamic profile     | Partial (smoke)   |
| 6 Bound profile       | _not yet covered_ |
| 8 Numeric codecs      | _not yet covered_ |
| 10 Strings            | _not yet covered_ |
| 13 Batch / stateful   | Partial (smoke)   |
| 15 Trained dictionary | _not yet covered_ |
| 18 Auto-selection     | Partial (smoke)   |
| Rust interop          | _not yet covered_ |

## Interop

Bidirectional Rust interop (`scripts/check-interop.sh`) is planned; unit tests run in CI with the monorepo's Rust runtime available.
