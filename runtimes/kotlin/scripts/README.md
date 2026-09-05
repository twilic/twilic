# Scripts

## Maintainer tools

| Script | Purpose |
| --- | --- |
| `write_v2_kt.py` | Regenerate `src/main/kotlin/.../V2.kt` from `twilic-python/src/twilic/v2.py`. |

## Rust interop

| Script | Purpose |
| --- | --- |
| `check-interop.sh` | JUnit interop tests + bidirectional Rust smoke |
| `check-kotlin-client-interop.sh` | Rust server → Kotlin decoder (`decodeRustServerFixtures`) |
| `check-rust-client-interop.sh` | Kotlin emitter → Rust validator |
| `rust-server-fixtures/` | Rust reference encoder |
| `rust-client-check/` | Rust decoder for Kotlin-emitted frames |

Uses the sibling `../rust` runtime (or `TWILIC_RUST_ROOT`).

Historical bootstrap/port utilities are under `port-archive/`.
