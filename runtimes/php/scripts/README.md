# Scripts

## Maintainer tools

| Script | Purpose |
| --- | --- |
| `gen_codec_from_python.py` | Regenerate `src/Twilic/Codec.php` from `twilic-python` (run after editing Python codec). |

## Rust interop

| Script | Purpose |
| --- | --- |
| `check-interop.sh` | PHPUnit interop tests + bidirectional Rust smoke |
| `check-php-client-interop.sh` | Rust server → PHP decoder |
| `check-rust-client-interop.sh` | PHP emitter → Rust validator |
| `rust-server-fixtures/` | Rust reference encoder (stdout fixture stream) |
| `rust-client-check/` | Rust decoder for PHP-emitted frames |

Uses the sibling `../rust` runtime in this monorepo (or set `TWILIC_RUST_ROOT`).

Historical one-off port generators live under `port-archive/` and are not required to build or test the SDK.
