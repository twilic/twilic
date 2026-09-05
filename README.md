# Twilic

This repository is the canonical Twilic protocol monorepo. It contains the documentation-first specification, shared conformance material, and independent runtime implementations for supported languages.

The format is intended to remain easy to use in schema-less workflows while targeting materially smaller output than plain MessagePack when repeated structure, repeated strings, homogeneous arrays, batching, or session reuse is present.

## Name

Twilic (pronounced **TWIL-ik**) is named after Old English _twilic_, the root of the modern word _twill_.

[Listen to the pronunciation](https://raw.githubusercontent.com/twilic/twilic/main/media/twilic-pronunciation.mp3)

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
├ README.md, LICENSE, CONTRIBUTING.md
├ SPEC.md
├ docs/                    # format, encoding, and transport documentation
├ versions/                # versioned wire profiles
├ examples/                # small specification examples
├ diagrams/                # protocol and encoding diagrams
├ media/                   # pronunciation and brand media
├ conformance/             # shared fixtures, vectors, and test runner
├ testdata/                # profile-oriented logical test inputs
├ runtimes/                # independent language implementations and tests
│  ├ rust/ … elixir/
├ tools/                   # repository-wide developer and CI tools
└ .github/workflows/       # selective runtime and full conformance CI
```

## Read In This Order

1. `SPEC.md` for the core model and format overview.
2. `docs/format.md` for top-level kinds, object forms, batches, patches, and resets.
3. `docs/encoding.md` for scalar rules, vector codecs, string modes, and compression.
4. `docs/transport.md` for session-scoped state and transport assumptions.
5. `versions/v3.md` for the compact schema-aware interoperability profile.
6. `examples/` and `diagrams/` for small concrete artifacts.
7. `conformance/README.md` for shared fixture and CI conventions.
8. `runtimes/<language>/README.md` for a language-specific API and development guide.

## Reference Profiles

This repository includes profiles in `versions/`.

- `versions/v2.md` records the previous interoperability profile.
- `versions/v3.md` records the schema-aware compact profile for Bound compact record-body bit groups, `BOUND_STREAM`, `SCHEMA_BATCH`, and fast-path requirements.

## Runtime Versioning

The repository is versioned as one protocol source tree, but package releases remain independent. Each runtime keeps its own package manifest and release version under `runtimes/<language>/`. A runtime README must state the Twilic specification profile it implements.

The old language-specific repositories remain valid mirrors during the migration. They are intentionally not deleted or made private by this repository change; new cross-runtime work should land here first.

## Outside This Repository

Product and integration repositories are intentionally kept separate from the protocol implementation monorepo. This includes the website, playground, explorer, benchmark, AI tooling, examples applications, `express`, `fastify`, `hono`, `fetch`, and `axios` integrations, plus infrastructure repositories. A change in one of those products does not need to run every runtime conformance job.

## License

The Twilic specification and documentation are licensed under `CC-BY-4.0`. See [`LICENSE`](LICENSE) for the full license text.

The language runtime implementations and their tests under `runtimes/` are licensed separately under the MIT License. Each runtime directory includes its own [`LICENSE`](runtimes/rust/LICENSE) file.
