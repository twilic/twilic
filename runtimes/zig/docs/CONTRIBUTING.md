# Contributing

Thank you for improving the Twilic Zig implementation.

## Scope

This package implements the Twilic wire format and session-aware encoder/decoder. Keep changes aligned with the normative spec in [twilic/twilic](https://github.com/twilic/twilic).

## Development

Requirements:

- Zig 0.15.2 (minimum 0.15.0)

```bash
zig fmt build.zig build.zig.zon src tests
zig build test
```

Interop scripts under `scripts/` can be run when changing cross-language fixtures.

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Use this format:

```text
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Common types include `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`, and `chore`.

Examples:

- `feat: add FOR bitpack vector codec`
- `fix(session): reset intern table on control frame`

Pull requests are checked in CI so every commit in the branch follows the same rules.

## Contribution Checklist

- Tests added or updated for behavior changes
- `zig fmt` and `zig build test` pass locally
- Interop fixtures updated when wire behavior changes
- Commit messages follow Conventional Commits

By contributing to this repository, you agree that your contribution may be distributed under the MIT license used by the project.
