# Twilic (Rust)

Rust implementation of the Twilic wire format and session-aware encoder/decoder.

This crate's default `encode` / `decode` API targets Twilic v3 (Dynamic Profile).

## What this crate provides

### v3 APIs

- Schema-bound compact streams (`encode_bound_stream`)
- Schema-aware columnar batches (`encode_batch_with_schema`)

### Also available

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encode_with_schema`)
- Batch and micro-batch encoding (`encode_batch`, `SessionEncoder::encode_micro_batch`)
- Stateful features (base snapshots, state patch, template batch, control stream, trained dictionary)

## Requirements

- Rust stable (edition 2024)

## Install

Add one of the following to `Cargo.toml`.

From GitHub:

```toml
[dependencies]
twilic = { git = "https://github.com/twilic/twilic-rust.git" }
```

From crates.io (if/when published):

```toml
[dependencies]
twilic = "3.1"
```

From this monorepo:

```toml
[dependencies]
twilic = { path = "./runtimes/rust" }
```

## Quick start

```rust
use twilic::{decode, encode, Value};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1001)),
        ("name".to_string(), Value::String("alice".to_string())),
    ]);

    let bytes = encode(&value)?;
    let decoded = decode(&bytes)?;
    assert_eq!(decoded, value);
    Ok(())
}
```

## Session encoder example

```rust
use twilic::{create_session_encoder, SessionOptions, Value};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut enc = create_session_encoder(SessionOptions::default());

    let value = Value::Map(vec![
        ("id".to_string(), Value::U64(1)),
        ("role".to_string(), Value::String("admin".to_string())),
    ]);

    let _bytes = enc.encode(&value)?;
    Ok(())
}
```

## Development

Run checks locally:

```bash
cargo fmt --all
cargo test
```

## Release (GitHub Actions)

Publishing to crates.io is automated by `.github/workflows/publish-crates.yml`.

Setup:

1. Add repository secret `CARGO_REGISTRY_TOKEN` (crates.io API token).
2. Bump `version` in `Cargo.toml`.
3. Create and push a matching tag: `v<version>`.

Example:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
