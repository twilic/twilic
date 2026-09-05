# Contributing

Thank you for improving Twilic.

## Scope

This repository contains the specification, shared conformance material, and independent language runtimes. Changes should preserve consistency across:

- `SPEC.md`
- `docs/`
- `versions/`
- `examples/`
- `diagrams/`
- `README.md`
- `conformance/`
- `testdata/`
- `runtimes/<language>/`

## Editorial Rules

- Write all new content in English.
- Prefer ASCII unless an existing file requires another character set.
- Use `MUST`, `MUST NOT`, `SHOULD`, `SHOULD NOT`, and `MAY` only for normative requirements.
- Keep core terms stable across files.
- Do not introduce examples or diagrams that imply undocumented wire behavior.

## Change Discipline

When changing one area, update the related materials in the same contribution.

- Wire layout changes Update `SPEC.md`, `docs/format.md`, `docs/encoding.md`, the active version file, and affected examples or diagrams.
- Codec or scalar-rule changes Update `SPEC.md`, `docs/encoding.md`, the active version file, and affected examples.
- Stateful transport changes Update `SPEC.md`, `docs/transport.md`, the active version file, and affected diagrams.
- Repository navigation changes Update `README.md`, `CONTRIBUTING.md`, and any affected references in `SPEC.md`.
- Runtime behavior changes Update the affected implementation and tests under `runtimes/<language>/`. If wire behavior changes, update every affected runtime in the same contribution.
- Shared fixture changes Update `conformance/`, `testdata/`, and the runtime tests or adapters that consume them.

## Normative Writing Guidelines

- State one requirement once, then cross-reference it where useful.
- Distinguish wire layout from transport behavior.
- Distinguish informative guidance from normative requirements.
- Keep deterministic rules exact.

## Examples And Diagrams

- Keep `examples/basic.json` aligned with the simple object examples in the spec.
- Keep `examples/schema-example.json` aligned with the Bound Profile examples.
- Keep `diagrams/` synchronized with the current rules in `SPEC.md` and `docs/`.

## Conformance And Runtime Checks

The repository-wide runner keeps language-specific build systems independent while giving CI one stable entry point:

```bash
bash conformance/run.sh rust
bash conformance/run.sh all
```

Set `TWILIC_RUST_ROOT` or `TWILIC_RUST_DIR` only when testing against a different Rust checkout. The default points at `runtimes/rust` in this repository.

The full interop suite is intentionally opt-in locally because it requires many language toolchains:

```bash
bash conformance/run.sh --interop all
```

## Formatting

If you use the Node tooling in this repository:

- run `pnpm format` before submitting Markdown changes
- run `pnpm lint` before submitting Markdown changes

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

- `docs: clarify v1 bound profile rules`
- `fix(spec): correct scalar width table`

After `pnpm install`, Husky runs Commitlint on each local commit. Pull requests are also checked in CI so every commit in the branch follows the same rules.

## Contribution Checklist

- The affected requirements were updated in the right file.
- Cross-references still point to the right document.
- `README.md` still reflects the public repository layout.
- Examples and diagrams still match the text.
- The active reference profile in `versions/` is still accurate.
- The affected runtime's local tests pass through `bash conformance/run.sh <language>`.
- Spec, conformance, and testdata changes are reviewed as one interoperability change.

By contributing to this repository, you agree that your contribution may be distributed under the `CC-BY-4.0` license used by the project.
