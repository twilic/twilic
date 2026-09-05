# Contributing

Thank you for improving the Twilic Rust implementation.

## Scope

This crate implements the Twilic wire format and session-aware encoder/decoder. Keep changes aligned with the normative spec in [twilic/twilic](https://github.com/twilic/twilic).

## Development

Requirements:

- Rust stable (edition 2024)

```bash
cargo test
cargo fmt --all
cargo clippy --all-targets --all-features
```

For integer-vector encoding changes, run `cargo bench --bench integer_vectors` before and after the change on the same machine. It reports the median of five 100 ms samples after warmup for 4, 256, and 4096 values, with a reused output buffer. These are codec microbenchmarks, not end-to-end API throughput results. `tests/integer_bitpack_compat.rs` checks byte-for-byte output against an independent bit-at-a-time encoder, including all bit widths, empty blocks, and integer limits.

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

- `feat: add trained dictionary batch encoding`
- `fix(codec): reject invalid control stream frames`

Pull requests are checked in CI so every commit in the branch follows the same rules.

## Pull Requests

Use the pull request template and fill in every required section. PR bodies are validated in CI.

## Contribution Checklist

- Tests added or updated for behavior changes
- `cargo test`, `cargo fmt --all`, and `cargo clippy` pass locally
- Spec-relevant behavior is reflected in tests or docs when needed
- Commit messages follow Conventional Commits

By contributing to this repository, you agree that your contribution may be distributed under the MIT license used by the project.
