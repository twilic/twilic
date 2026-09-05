# Test data

This directory contains logical inputs shared across runtime implementations. It is deliberately separate from `conformance/fixtures/`: testdata describes values and profile scenarios, while fixtures and vectors describe wire-level expectations.

The four initial groups mirror the Twilic profile families:

- `dynamic/` — schema-less values and learned structure;
- `bound/` — schema-bound records;
- `batch/` — row and column batches; and
- `stateful/` — snapshots, patches, templates, and control streams.

Inputs are JSON where the value model is language-neutral. Binary payloads and expected wire bytes belong in `conformance/fixtures/` or `conformance/vectors/`.
