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

## AI Assistance

AI tools may help write code, tests, and documentation.

Issues and pull requests must still be created by a human after review. Do not open them from AI output alone. Confirm the claim with a reproduction, failing test, linked discussion, or other concrete evidence before filing.

Keep issue and PR text short and concrete. Avoid long, generic phrasing that reads like unedited AI output.

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

- run `bun run format` before submitting Markdown changes
- run `bun run lint` before submitting Markdown changes

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Use this format:

```text
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Common types include `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`, and `chore`.

### Runtime scopes

When a commit targets a single language runtime, use a lowercase scope that readers will recognize at a glance. Use a widely known short form when one is already common (`js`, `cpp`); otherwise use the everyday language name (`rust`, `python`, `kotlin`). Avoid directory-only spellings when a clearer short form exists (`javascript`), and avoid cryptic file-extension style abbreviations (`rs`, `py`, `rb`, `kt`).

| Scope    | Runtime directory     |
| -------- | --------------------- |
| `c`      | `runtimes/c`          |
| `cpp`    | `runtimes/cpp`        |
| `csharp` | `runtimes/csharp`     |
| `dart`   | `runtimes/dart`       |
| `elixir` | `runtimes/elixir`     |
| `go`     | `runtimes/go`         |
| `java`   | `runtimes/java`       |
| `js`     | `runtimes/javascript` |
| `kotlin` | `runtimes/kotlin`     |
| `lua`    | `runtimes/lua`        |
| `php`    | `runtimes/php`        |
| `python` | `runtimes/python`     |
| `r`      | `runtimes/r`          |
| `ruby`   | `runtimes/ruby`       |
| `rust`   | `runtimes/rust`       |
| `scala`  | `runtimes/scala`      |
| `swift`  | `runtimes/swift`      |
| `zig`    | `runtimes/zig`        |

Use a non-runtime scope such as `spec` or `deps` when the change is not limited to one runtime. Omit the scope when it does not add clarity.

Issue templates, pull request checklists, and GitHub Release titles keep the full display names (`JavaScript`, `C++`, `C#`).

Examples:

- `docs: clarify v1 bound profile rules`
- `fix(spec): correct scalar width table`
- `fix(js): enable getrandom wasm_js for wasm builds`
- `fix(rust): reject for and xor-float overflows`
- `fix(go): reject oversized table reference ids`
- `fix(cpp): reject for bitpack overflows`

After `bun install`, Husky runs Commitlint on each local commit. Pull requests are also checked in CI so every commit in the branch follows the same rules.

## Contribution Checklist

- Issues and pull requests were human-reviewed and backed by concrete evidence.
- Issue and PR text stays short and concrete.
- The affected requirements were updated in the right file.
- Cross-references still point to the right document.
- `README.md` still reflects the public repository layout.
- Examples and diagrams still match the text.
- The active reference profile in `versions/` is still accurate.
- The affected runtime's local tests pass through `bash conformance/run.sh <language>`.
- Spec, conformance, and testdata changes are reviewed as one interoperability change.

## Licensing Of Contributions

Contributions to specification and documentation files outside `runtimes/` are licensed under `CC-BY-4.0`.

Contributions under `runtimes/` are licensed under the MIT License applicable to that runtime.
