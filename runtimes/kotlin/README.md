# Twilic (Kotlin / JVM)

Kotlin/JVM implementation of the Twilic wire format and session-aware encoder/decoder.

This library's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this library provides

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encodeWithSchema`)
- Batch encoding (`encodeBatch`, `SessionEncoder`)
- Session protocol stack (Java sources under `src/main/java` during Kotlin migration)

## Project layout

```text
twilic-kotlin/
  src/main/kotlin/io/twilic/           # public API + v2 wire (Kotlin)
  src/main/java/io/twilic/internal/core/  # protocol codec (Java, migration)
  src/test/
  scripts/
  docs/
```

## Requirements

- JDK 21 or later
- Gradle 9.4+ (wrapper included)

## Install

Gradle (when published):

```kotlin
dependencies {
    implementation("io.twilic:twilic:3.0.0")
}
```

## Quick start

```kotlin
import io.twilic.Twilic
import io.twilic.internal.core.MapEntry

val value = Twilic.newMap(
    MapEntry("id", Twilic.newU64(1001)),
    MapEntry("name", Twilic.newString("alice")),
)
val encoded = Twilic.encode(value)
val decoded = Twilic.decode(encoded)
```

Public `encode` / `decode` use the v2 wire profile (`V2.encodeV2` / `V2.decodeV2`), ported from [twilic-python](https://github.com/twilic/twilic-python).

Regenerate `V2.kt` after editing the Python reference:

```bash
python3 scripts/write_v2_kt.py
```

## Development

```bash
./gradlew test
```

Rust client interop smoke check (Kotlin server → Rust client):

```bash
bash scripts/check-rust-client-interop.sh
```

Kotlin client interop smoke check (Rust server → Kotlin client):

```bash
bash scripts/check-kotlin-client-interop.sh
```

Full bidirectional interop (uses `../rust` or `TWILIC_RUST_ROOT`):

```bash
bash scripts/check-interop.sh
```

## Markdown formatting

Documentation is formatted and linted with Prettier and markdownlint (see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md)).

## CI (GitHub Actions)

- CI workflow: `.github/workflows/ci.yml`
- Commitlint, invisible character check, and PR body validation under `.github/workflows/`
- Interop workflow: `.github/workflows/interop.yml`

## Module map

| Kotlin (`src/main/kotlin`) | Role |
| --- | --- |
| `io.twilic.Twilic`, `Version` | Public API |
| `internal.core.V2` | v2 wire encode/decode |
| `internal.core.Api` | Bridges public API to V2 + session encoder |
| `internal.core.Value`, `Wire`, `Errors`, … | Core model |

| Java (`src/main/java`) | Role |
| --- | --- |
| `ProtocolCodec`, `Codec`, `ProtocolHelpers`, `Dictionary`, … | Session protocol codec |

## Spec parity

Tracks [twilic/twilic](https://github.com/twilic/twilic), [twilic-java](https://github.com/twilic/twilic-java), and [twilic-python](https://github.com/twilic/twilic-python).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
