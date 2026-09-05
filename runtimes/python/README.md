# Twilic (Python)

Python implementation of the Twilic wire format and session-aware encoder/decoder.

This package's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this package provides

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encode_with_schema`)
- Batch and micro-batch encoding (`encode_batch`, `SessionEncoder.encode_micro_batch`)
- Stateful features (base snapshots, state patch, template batch, control stream, trained dictionary)

## Project layout

```text
twilic-python/
  src/twilic/                     # wire, model, codec, session, protocol, v2
  tests/                          # spec conformance and interop tests
  scripts/                        # Rust interop fixtures and smoke checks
  docs/
```

## Requirements

- Python 3.12 or later
- [uv](https://docs.astral.sh/uv/) for development

## Install

```bash
pip install twilic
```

Or with uv:

```bash
uv add twilic
```

## Quick start

```python
import twilic

value = twilic.new_map(
    twilic.entry("id", twilic.new_u64(1001)),
    twilic.entry("name", twilic.new_string("alice")),
)

data = twilic.encode(value)
decoded = twilic.decode(data)

print(twilic.equal(decoded, value))
```

## Session encoder example

```python
import twilic

enc = twilic.new_session_encoder(twilic.default_session_options())

value = twilic.new_map(
    twilic.entry("id", twilic.new_u64(1)),
    twilic.entry("role", twilic.new_string("admin")),
)

enc.encode(value)
```

## Development

Run checks locally:

```bash
uv sync
uv run ruff format --check .
uv run ruff check .
uv run pytest
```

Rust client interop smoke check (Python server -> Rust client):

```bash
bash scripts/check-rust-client-interop.sh
```

Python client interop smoke check (Rust server -> Python client):

```bash
bash scripts/check-python-client-interop.sh
```

Run both directions:

```bash
bash scripts/check-interop.sh
```

Note: interop scripts use the sibling `../rust` runtime in this monorepo.

## Markdown formatting

Documentation is formatted and linted with Prettier and markdownlint (see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md)).

## CI and release (GitHub Actions)

- CI workflow: `.github/workflows/ci.yml`
- Interop workflow: `.github/workflows/interop.yml`
- Release workflow: `.github/workflows/publish-pypi.yml` (tag `v*` must match `pyproject.toml` version)

## Spec parity

This package mirrors the Twilic wire format spec at [twilic/twilic](https://github.com/twilic/twilic) and stays in lockstep with the [Rust](https://github.com/twilic/twilic-rust), [Go](https://github.com/twilic/twilic-go), and [Zig](https://github.com/twilic/twilic-zig) reference implementations.

See [`docs/SPEC-TEST-TRACEABILITY.md`](docs/SPEC-TEST-TRACEABILITY.md) for the spec-section to test mapping.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
