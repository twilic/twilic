# Contributing

Thank you for improving the Twilic Swift implementation.

## Scope

This repository implements the Twilic wire format and session-aware encoder/decoder. Keep changes aligned with the normative spec in [twilic/twilic](https://github.com/twilic/twilic).

## Development

Implementation code belongs in `Sources/Twilic`. Match API naming and behavior of [twilic-python](https://github.com/twilic/twilic-python) and [twilic-java](https://github.com/twilic/twilic-java) where applicable.

```bash
swift test
```

Markdown in this repository is formatted with Prettier and linted with markdownlint (same tooling as [twilic/twilic-go](https://github.com/twilic/twilic-go)):

```bash
pnpm install
pnpm format        # write
pnpm format:check  # CI check
pnpm lint          # markdownlint
```

Interop scripts (when present) use the sibling `../rust` runtime in this monorepo.

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Examples:

- `feat: add FOR bitpack vector codec`
- `fix(session): reset intern table on control frame`

## Contribution Checklist

- Tests added or updated for behavior changes
- Language tests pass locally (see command above)
- `pnpm format:check` and `pnpm lint` pass when Markdown changes
- Commit messages follow Conventional Commits

By contributing to this repository, you agree that your contribution may be distributed under the MIT license used by the project.
