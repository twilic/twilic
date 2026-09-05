# Twilic (Go)

Go implementation of the Twilic wire format and session-aware encoder/decoder.

This module's default `Encode` / `Decode` API targets Twilic v3 (Dynamic Profile).

## What this module provides

### v3 APIs

- Schema-bound compact streams (`EncodeBoundStream`)
- Schema-aware columnar batches (`EncodeBatchWithSchema`)

### Also available

- Dynamic encoding/decoding (`Encode`, `Decode`)
- Schema-aware encoding (`EncodeWithSchema`)
- Batch and micro-batch encoding (`EncodeBatch`, `SessionEncoder.EncodeMicroBatch`)
- Stateful features (base snapshots, state patch, template batch, control stream, trained dictionary)

## Project layout

```text
twilic-go/
  export.go, version.go            # public import path (github.com/twilic/twilic-go)
  internal/core/                  # wire, model, codec, session, protocol, v2, v3 tests
  scripts/                        # Rust interop fixtures and smoke checks
  docs/
```

The repository root stays thin: import `github.com/twilic/twilic-go` only. Implementation details live under `internal/core/`, similar to `src/` in the Zig crate.

## Requirements

- Go 1.22 or later

## Install

```bash
go get github.com/twilic/twilic-go
```

## Quick start

```go
package main

import (
    "fmt"

    twilic "github.com/twilic/twilic-go"
)

func main() {
    value := twilic.NewMap(
        twilic.Entry("id", twilic.NewU64(1001)),
        twilic.Entry("name", twilic.NewString("alice")),
    )

    bytes, err := twilic.Encode(value)
    if err != nil {
        panic(err)
    }

    decoded, err := twilic.Decode(bytes)
    if err != nil {
        panic(err)
    }

    fmt.Println(twilic.Equal(decoded, value))
}
```

## Session encoder example

```go
package main

import (
    twilic "github.com/twilic/twilic-go"
)

func main() {
    enc := twilic.NewSessionEncoder(twilic.DefaultSessionOptions())

    value := twilic.NewMap(
        twilic.Entry("id", twilic.NewU64(1)),
        twilic.Entry("role", twilic.NewString("admin")),
    )

    if _, err := enc.Encode(&value); err != nil {
        panic(err)
    }
}
```

## Development

Run checks locally:

```bash
gofmt -l .
go vet ./...
go test ./...
```

Rust client interop smoke check (Go server -> Rust client):

```bash
bash scripts/check-rust-client-interop.sh
```

Go client interop smoke check (Rust server -> Go client):

```bash
bash scripts/check-go-client-interop.sh
```

Run both directions:

```bash
bash scripts/check-interop.sh
```

Note: these scripts use the sibling `../rust` runtime in this monorepo.

## Markdown formatting

Documentation is formatted and linted with Prettier and markdownlint (see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md)).

## CI and release (GitHub Actions)

- CI workflow: `.github/workflows/ci.yml`
- Interop workflow: `.github/workflows/interop.yml`
- Release workflow: `.github/workflows/publish-module.yml` (tag `v*` must match `version.go`)

## Spec parity

This module mirrors the Twilic wire format spec at [twilic/twilic](https://github.com/twilic/twilic) and stays in lockstep with the [Rust](https://github.com/twilic/twilic-rust) and [Zig](https://github.com/twilic/twilic-zig) reference implementations.

See [`docs/SPEC-TEST-TRACEABILITY.md`](docs/SPEC-TEST-TRACEABILITY.md) for the spec-section to test mapping.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
