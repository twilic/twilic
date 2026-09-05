# Contributing

Thank you for improving the Twilic Go implementation.

## Scope

This module implements the Twilic wire format and session-aware encoder/decoder. Keep changes aligned with the normative spec in [twilic/twilic](https://github.com/twilic/twilic).

## Development

Requirements:

- Go 1.22 or later

Implementation code belongs in `internal/core/`. The repository root (`export.go`) re-exports the stable public API.

```bash
gofmt -l .
go vet ./...
go test ./...
```

Markdown in this repository is formatted with Prettier and linted with markdownlint (same tooling as [twilic/twilic](https://github.com/twilic/twilic)):

```bash
pnpm install
pnpm format        # write
pnpm format:check  # CI check
pnpm lint          # markdownlint
```

Interop scripts under `scripts/` use the sibling `../rust` runtime in this monorepo. They verify Rust and Go decode the same logical values and that `go test ./internal/core -run '^TestInteropFixtures_'` passes (encode/decode roundtrip, wire parity, and cross-language value checks).

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Examples:

- `feat: add FOR bitpack vector codec`
- `fix(session): reset intern table on control frame`

## Contribution Checklist

- Tests added or updated for behavior changes
- `gofmt`, `go vet ./...`, and `go test ./...` pass locally
- `pnpm format:check` and `pnpm lint` pass when Markdown changes
- Interop fixtures updated when wire behavior changes
- Commit messages follow Conventional Commits

By contributing to this repository, you agree that your contribution may be distributed under the MIT license used by the project.
