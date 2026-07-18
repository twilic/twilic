# Twilic

This repository contains a documentation-first specification for a compact binary format for structured data.

The format is intended to remain easy to use in schema-less workflows while becoming materially smaller than plain MessagePack when repeated structure, repeated strings, homogeneous arrays, batching, or session reuse is present.

## Name

Twilic is named after Old English _twilic_, the root of the modern word _twill_.

_Twill_ is a weave built from repeated threads, often forming a diagonal pattern. The name reflects Twilic's core idea: repeated data shapes, keys, and values should not be sent again and again as independent structures, but woven together into a compact binary representation.

In other words, Twilic treats structured data less like isolated messages and more like a fabric of recurring patterns.

The etymology follows [Merriam-Webster](https://www.merriam-webster.com/dictionary/twill), which traces _twill_ to Old English _twilic_ (“having a double thread”).

## Goals

- reduce repeated object-key overhead
- support schema-aware compact encoding when schemas are available
- support learned structure in dynamic mode
- support row-wise, schema-aware columnar, and stateful compression strategies
- keep deterministic wire behavior within a fixed profile

## Non-Goals

- replacing every existing JSON or binary protocol
- defining application semantics
- mandating a single transport handshake for every deployment

## Repository Layout

```text
twilic/
├ README.md
├ LICENSE
├ CONTRIBUTING.md
├ SPEC.md
├ docs/
│  ├ format.md
│  ├ encoding.md
│  └ transport.md
├ versions/
│  ├ v1.md
│  ├ v2.md
│  └ v3.md
├ examples/
│  ├ README.md
│  ├ basic.json
│  └ schema-example.json
├ diagrams/
│  ├ protocol-flow.md
│  └ encoding-structure.md
├ .editorconfig
├ .gitignore
├ .markdownlint.jsonc
├ .prettierrc.json
└ package.json
```

## Read In This Order

1. `SPEC.md` for the core model and format overview.
2. `docs/format.md` for top-level kinds, object forms, batches, patches, and resets.
3. `docs/encoding.md` for scalar rules, vector codecs, string modes, and compression.
4. `docs/transport.md` for session-scoped state and transport assumptions.
5. `versions/v3.md` for the compact schema-aware interoperability profile.
6. `examples/` and `diagrams/` for small concrete artifacts.

## Reference Profiles

This repository includes profiles in `versions/`.

- `versions/v2.md` records the previous interoperability profile.
- `versions/v3.md` records the schema-aware compact profile for Bound bitstream fields, `BOUND_STREAM`, `SCHEMA_BATCH`, and fast-path requirements.

## License

This repository is distributed under `CC-BY-4.0`. See `LICENSE` for the full license text.
