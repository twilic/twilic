# Monorepo migration

This checkout adds the protocol implementation monorepo described in the Twilic repository decision. The specification repository remains the canonical Git repository; the language implementations are now grouped under `runtimes/` while keeping their native build layouts.

## Imported runtimes

| Source repository | Destination           | Imported source commit |
| ----------------- | --------------------- | ---------------------- |
| `twilic-rust`     | `runtimes/rust`       | `e944473`              |
| `twilic-js`       | `runtimes/javascript` | `748c261`              |
| `twilic-go`       | `runtimes/go`         | `cfcf1d1`              |
| `twilic-python`   | `runtimes/python`     | `bbbba35`              |
| `twilic-java`     | `runtimes/java`       | `51d2687`              |
| `twilic-c`        | `runtimes/c`          | `9991a12`              |
| `twilic-cpp`      | `runtimes/cpp`        | `217e0c8`              |
| `twilic-csharp`   | `runtimes/csharp`     | `9d607c6`              |
| `twilic-dart`     | `runtimes/dart`       | `dcebf57`              |
| `twilic-kotlin`   | `runtimes/kotlin`     | `a51d740`              |
| `twilic-lua`      | `runtimes/lua`        | `9a09964`              |
| `twilic-php`      | `runtimes/php`        | `c1beda4`              |
| `twilic-r`        | `runtimes/r`          | `f6ee921`              |
| `twilic-ruby`     | `runtimes/ruby`       | `12c1d37`              |
| `twilic-scala`    | `runtimes/scala`      | `07b7bb7`              |
| `twilic-swift`    | `runtimes/swift`      | `37340e3`              |
| `twilic-zig`      | `runtimes/zig`        | `0a9baa3`              |
| `twilic-elixir`   | `runtimes/elixir`     | `5acf077`              |

The import includes tracked implementation files, tests, package manifests, native build definitions, and runtime documentation. Repository control files and workflows were left out so the root repository can own CI and contribution policy. Generated build output and dependency caches are ignored at the monorepo level.

## Existing repositories

The source repositories were not modified, deleted, archived, or made private. They remain available as historical and package-release mirrors during the migration. Their current contents are the source snapshot recorded above; future synchronization should be an explicit, reviewable change.

## Migration conventions

- `SPEC.md`, `versions/`, `conformance/`, and `testdata/` are shared protocol inputs.
- `runtimes/<language>/` remains an independent implementation and package boundary.
- Runtime package versions are not forced to move in lockstep.
- `TWILIC_RUST_ROOT` and `TWILIC_RUST_DIR` point interop checks at `runtimes/rust` by default.
- `bash conformance/run.sh <runtime>` is the local and CI entry point for native runtime tests.
- `bash conformance/run.sh fixtures` validates the checked-in initial interop corpus with the central Rust adapter.
