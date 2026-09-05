# Twilic runtimes

Each directory in this folder is an independent implementation of the Twilic wire format. Runtime source code, package metadata, language-native tests, and language-specific release documentation stay together so a maintainer can work in the native toolchain.

The shared contract lives outside these directories:

- [`../SPEC.md`](../SPEC.md) defines the wire format.
- [`../conformance/`](../conformance/) owns shared fixture conventions and the repository-wide runner.
- [`../testdata/`](../testdata/) owns logical profile-oriented inputs.

Runtime package versions are intentionally independent from the Twilic specification version. See each runtime README for its current profile and release status.
