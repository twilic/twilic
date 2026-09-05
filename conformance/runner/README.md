# Runner adapters

The repository-wide entry point is [`../run.sh`](../run.sh). Language-native tests stay in their runtime directory; this folder documents the shared adapter contract rather than replacing native build systems.

Adapters must:

1. run without depending on a sibling language repository;
2. honor `TWILIC_RUST_ROOT` and `TWILIC_RUST_DIR` when Rust interop is needed; and
3. return a non-zero exit status for a failed test or malformed fixture expectation.
