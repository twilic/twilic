# Twilic (Dart)

Dart implementation of the Twilic wire format and session-aware encoder/decoder.

This package's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this package provides

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encodeWithSchema`)
- Batch encoding (`encodeBatch`, `SessionEncoder`)
- Native v2 wire, codec, session, and protocol modules under `lib/src/`

## Project layout

```text
twilic-dart/
  lib/                    # public API (twilic.dart) + lib/src/*
  test/
  tool/
  docs/
```

## Requirements

- Dart SDK 3.5 or later

## Install

```yaml
dependencies:
  twilic:
    git:
      url: https://github.com/twilic/twilic-dart.git
```

## Quick start

```dart
import 'package:twilic/twilic.dart';

final value = newMap([
  entry('id', newU64(1001)),
  entry('name', newString('alice')),
]);

final data = encode(value);
final decoded = decode(data);
```

## Development

```bash
dart pub get
dart test
```

## Markdown formatting

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) for Prettier and markdownlint.

## CI (GitHub Actions)

- `.github/workflows/ci.yml` — `dart test` and markdown checks

## Spec parity

Mirrors [twilic/twilic](https://github.com/twilic/twilic) and references [twilic-python](https://github.com/twilic/twilic-python).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
