# Twilic (C#)

C# implementation of the Twilic wire format and session-aware encoder/decoder.

This library's default `Encode` / `Decode` API targets Twilic v2 (v3 support pending).

## What this library provides

- Dynamic encoding/decoding (`Encode`, `Decode`)
- Schema-aware encoding (`EncodeWithSchema`)
- Batch encoding (`EncodeBatch`, `SessionEncoder`)
- **V2 wire profile**: native `Core/V2.cs` plus session encoder (`SessionEncoder.cs`)
- Smoke-level coverage today; full protocol parity with `twilic-java` is tracked in issues

## Project layout

```text
twilic-csharp/
  src/Twilic/             # public API + Core/*
  tests/
  docs/
```

## Requirements

- .NET 8 SDK

## Install

```bash
dotnet add package Twilic
```

(When published to NuGet.)

## Quick start

```csharp
using Twilic;

var value = Twilic.NewMap(
    Twilic.Entry("id", Twilic.NewU64(1001)),
    Twilic.Entry("name", Twilic.NewString("alice")));

byte[] bytes = Twilic.Encode(value);
var decoded = Twilic.Decode(bytes);
```

## Development

```bash
dotnet test
```

## Markdown formatting

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

## CI (GitHub Actions)

- `.github/workflows/ci.yml` — `dotnet test` and markdown checks

## Spec parity

Mirrors [twilic/twilic](https://github.com/twilic/twilic) and [twilic-java](https://github.com/twilic/twilic-java).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
