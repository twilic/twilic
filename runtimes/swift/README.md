# Twilic (Swift)

Swift implementation of the Twilic wire format and session-aware encoder/decoder.

This package's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this package provides

- Dynamic encoding/decoding (`encode`, `decode`)
- V2 wire profile and codec spec vector tests
- Session/protocol APIs under `Sources/Twilic/Core/`

## Project layout

```text
twilic-swift/
  Sources/Twilic/         # library sources
  Tests/TwilicTests/      # unit tests
  Package.swift
  docs/
```

## Requirements

- Swift 5.9+
- macOS 13+ / iOS 15+ (per `Package.swift`)

## Install

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/twilic/twilic-swift.git", from: "0.1.0"),
]
```

## Quick start

```swift
import Twilic

let value = newMap([
    entry("id", newU64(1001)),
    entry("name", newString("alice")),
])

let data = try encode(value)
let decoded = try decode(data)
```

## Development

```bash
swift test
```

CI runs on `macos-latest` because of Apple platform targets.

## Markdown formatting

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

## CI (GitHub Actions)

- `.github/workflows/ci.yml` — `swift test` (macOS) and markdown checks (Ubuntu)

## Spec parity

Mirrors [twilic/twilic](https://github.com/twilic/twilic) and [twilic-java](https://github.com/twilic/twilic-java).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
