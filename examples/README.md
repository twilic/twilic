# Examples

This directory contains small JSON artifacts that map directly to Twilic specification concepts.

## Files

- `basic.json`
  - Dynamic-profile style object example.
  - Useful for `MAP`, `shape_def`/`shape_ref`, and key/shape interning behavior.
- `schema-example.json`
  - Bound-profile style schema plus records example.
  - Demonstrates required/optional fields, enum-like strings, and bounded integers.

## How To Read

1. Read `SPEC.md` sections for Dynamic and Bound profiles.
2. Read `docs/format.md` for object and batch forms.
3. Read `docs/encoding.md` for scalar and string/vector codec behavior.
4. Compare these JSON examples with `diagrams/` flow diagrams.

## Notes

- These files are informative examples, not normative wire dumps.
- Field names and values are intentionally small and stable for documentation clarity.
