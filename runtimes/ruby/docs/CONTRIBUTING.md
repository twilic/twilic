# Contributing

Thank you for improving the Twilic Ruby implementation.

## Scope

This gem implements the Twilic wire format and session-aware encoder/decoder. Keep changes aligned with the normative spec in [twilic/twilic](https://github.com/twilic/twilic).

## Development

Requirements:

- Ruby 3.3 or later
- Bundler

Implementation code belongs in `lib/twilic/core/`. The repository root (`lib/twilic.rb`) re-exports the stable public API.

```bash
bundle install
bundle exec rake test
```

Markdown in this repository is formatted with Prettier and linted with markdownlint (same tooling as [twilic/twilic](https://github.com/twilic/twilic)):

```bash
pnpm install
pnpm format        # write
pnpm format:check  # CI check
pnpm lint          # markdownlint
```

Interop scripts under `scripts/` use the sibling `../rust` runtime in this monorepo. They verify Rust and Ruby decode the same logical values and that `bundle exec rake test TEST=test/twilic/core/interop_fixtures_test.rb` passes (encode/decode roundtrip, wire parity, and cross-language value checks).

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Examples:

- `feat: add FOR bitpack vector codec`
- `fix(session): reset intern table on control frame`

## Contribution Checklist

- Tests added or updated for behavior changes
- `bundle exec rake test` passes locally
- `pnpm format:check` and `pnpm lint` pass when Markdown changes
- Interop fixtures updated when wire behavior changes
- Commit messages follow Conventional Commits

By contributing to this repository, you agree that your contribution may be distributed under the MIT license used by the project.
