# Conformance

This directory is the shared interoperability layer for the Twilic runtime implementations.

## Layout

```text
conformance/
├ fixtures/              # checked-in frame corpora and fixture descriptions
├ vectors/               # fixed wire-byte vectors
├ malformed/             # invalid input corpora
├ runner/                # adapter and runner documentation
├ rust-client-check/     # reference fixture decoder
├ rust-server-fixtures/  # reference fixture emitter
└ run.sh                 # repository-wide entry point
```

The frame format used by the initial interop corpus is line-oriented:

```text
<stream>|<label>|<lowercase-hex-wire-bytes>
```

`stream` is currently `codec` or `session`. Labels are stable test-case identifiers, not language-specific names. New shared cases should be added here and then consumed by every runtime adapter that supports the relevant profile.

The runtime test suites remain under `runtimes/<language>/` so native test commands and package release workflows continue to work. The repository-wide runner invokes those suites from one stable entry point. Shared specification, fixture, or testdata changes select the complete runtime matrix in CI; isolated runtime changes select only that runtime.

Regenerate and check the initial corpus with:

```bash
bash conformance/generate-fixtures.sh
bash conformance/run.sh fixtures
```

Run runtime checks with:

```bash
bash conformance/run.sh rust
bash conformance/run.sh fixtures
bash conformance/run.sh all
```

The old language-specific repositories are preserved during this migration. They are not required as sibling checkouts when using this monorepo.
