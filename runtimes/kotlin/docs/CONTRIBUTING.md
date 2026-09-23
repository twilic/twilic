# Contributing

Thank you for improving the Twilic Kotlin/JVM implementation.

## Scope

This repository implements the Twilic wire format and session-aware encoder/decoder. Keep changes aligned with the normative spec in [twilic/twilic](https://github.com/twilic/twilic).

## Development

Implementation code belongs in `src/main/kotlin and src/main/java/io/twilic/internal/core`. Match API naming and behavior of [runtimes/python](https://github.com/twilic/twilic/tree/main/runtimes/python) and [runtimes/java](https://github.com/twilic/twilic/tree/main/runtimes/java) where applicable.

```bash
./gradlew test
```

Markdown in this repository is formatted with Prettier and linted with markdownlint (same tooling as the repository root):

```bash
bun install
bun run format        # write
bun run format:check  # CI check
bun run lint          # markdownlint
```

Interop scripts under `scripts/` use the sibling `../rust` runtime (or `TWILIC_RUST_ROOT`). Run `bash scripts/check-interop.sh` for JUnit interop tests plus bidirectional Rust smoke checks.

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Examples:

- `feat: add FOR bitpack vector codec`
- `fix(session): reset intern table on control frame`

## Contribution Checklist

- Tests added or updated for behavior changes
- Language tests pass locally (see command above)
- `bun run format:check` and `bun run lint` pass when Markdown changes
- Commit messages follow Conventional Commits

By contributing to this repository, you agree that your contribution may be distributed under the MIT license used by the project.
