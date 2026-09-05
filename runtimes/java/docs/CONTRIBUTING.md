# Contributing

Thank you for improving the Twilic Python implementation.

## Scope

This package implements the Twilic wire format and session-aware encoder/decoder. Keep changes aligned with the normative spec in [twilic/twilic](https://github.com/twilic/twilic).

## Development

Requirements:

- Python 3.12 or later
- [uv](https://docs.astral.sh/uv/)

Implementation code belongs in `src/twilic/`. The public API is exported from `src/twilic/__init__.py`.

```bash
uv sync
uv run ruff format --check .
uv run ruff check .
uv run pytest
```

Markdown in this repository is formatted with Prettier and linted with markdownlint (same tooling as [twilic/twilic-go](https://github.com/twilic/twilic-go)):

```bash
pnpm install
pnpm format        # write
pnpm format:check  # CI check
pnpm lint          # markdownlint
```

Interop scripts under `scripts/` use the sibling `../rust` runtime in this monorepo. They verify Rust and Python decode the same logical values and that pytest interop tests pass.

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Examples:

- `feat: add FOR bitpack vector codec`
- `fix(session): reset intern table on control frame`

## Contribution Checklist

- Tests added or updated for behavior changes
- `uv run ruff format --check`, `uv run ruff check`, and `uv run pytest` pass locally
- `pnpm format:check` and `pnpm lint` pass when Markdown changes
- Interop fixtures updated when wire behavior changes
- `docs/SPEC-TEST-TRACEABILITY.md` updated when spec coverage changes
- Commit messages follow Conventional Commits

By contributing to this repository, you agree that your contribution may be distributed under the MIT license used by the project.
