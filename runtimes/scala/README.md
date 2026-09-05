# Twilic (Scala)

Scala 3 implementation of the Twilic wire format and session-aware encoder/decoder.

This library's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this library provides

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encodeWithSchema`)
- Batch and micro-batch encoding (`encodeBatch`, `SessionEncoder.encodeMicroBatch`)
- Stateful features (base snapshots, state patch, template batch, control stream, trained dictionary)

## Project layout

```text
twilic-scala/
  src/main/scala/io/twilic/           # public Scala API
  src/main/java/io/twilic/internal/  # protocol core (Java, shared with reference SDK)
  src/test/scala/                      # spec conformance and interop tests (ScalaTest)
  scripts/                             # Rust interop fixtures and smoke checks
  docs/
```

The public package is `io.twilic`. Implementation details live under `io.twilic.internal.core`.

## Requirements

- Java 21 or later
- sbt 1.10+

## Install

sbt:

```scala
libraryDependencies += "io.twilic" %% "twilic" % "3.0.0"
```

Maven:

```xml
<dependency>
  <groupId>io.twilic</groupId>
  <artifactId>twilic_3</artifactId>
  <version>3.0.0</version>
</dependency>
```

## Quick start

```scala
import io.twilic.Twilic
import io.twilic.internal.core.*

val value = Twilic.newMap(
  Twilic.entry("id", Twilic.newU64(1001)),
  Twilic.entry("name", Twilic.newString("alice")),
)

val bytes = Twilic.encode(value)
val decoded = Twilic.decode(bytes)

println(Twilic.equal(decoded, value))
```

## Session encoder example

```scala
import io.twilic.Twilic
import io.twilic.internal.core.*

val enc = Twilic.newSessionEncoder()
val value = Twilic.newMap(
  Twilic.entry("id", Twilic.newU64(1)),
  Twilic.entry("role", Twilic.newString("admin")),
)
enc.encode(value)
```

## Development

Run checks locally:

```bash
sbt scalafmtCheck test
```

Rust client interop smoke check (Scala server -> Rust client):

```bash
bash scripts/check-rust-client-interop.sh
```

Scala client interop smoke check (Rust server -> Scala client):

```bash
bash scripts/check-scala-client-interop.sh
```

Run both directions:

```bash
bash scripts/check-interop.sh
```

Note: these scripts use the sibling `../rust` runtime in this monorepo.

## Markdown formatting

Documentation is formatted and linted with Prettier and markdownlint (see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md)).

## CI and release (GitHub Actions)

- CI workflow: `.github/workflows/ci.yml`
- Interop workflow: `.github/workflows/interop.yml`
- Release workflow: `.github/workflows/publish-maven.yml` (tag `v*` must match `Version.VERSION`)

## Spec parity

This library mirrors the Twilic wire format spec at [twilic/twilic](https://github.com/twilic/twilic) and stays in lockstep with the [Rust](https://github.com/twilic/twilic-rust), [Java](https://github.com/twilic/twilic-java), and [Python](https://github.com/twilic/twilic-python) reference implementations.

See [`docs/SPEC-TEST-TRACEABILITY.md`](docs/SPEC-TEST-TRACEABILITY.md) for the spec-section to test mapping.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
