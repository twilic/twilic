# Twilic (C++)

C++ implementation of the Twilic wire format and session-aware encoder/decoder.

This library's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this library provides

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encode_with_schema`)
- Batch encoding (`encode_batch`, `SessionEncoder`, `TwilicCodec`)
- Headers under `include/twilic/`, sources under `src/`

## Project layout

```text
twilic-cpp/
  include/twilic/         # public headers
  src/                    # implementation
  test/
  docs/
```

## Requirements

- CMake 3.16+
- C++17 compiler

## Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

## Quick start

```cpp
#include "twilic/twilic.hpp"

auto value = twilic::new_map({
    twilic::entry("id", twilic::new_u64(1001)),
    twilic::entry("name", twilic::new_string("alice")),
});
auto bytes = twilic::encode(value);
auto decoded = twilic::decode(bytes);
```

## Development

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

## CI (GitHub Actions)

- `.github/workflows/ci.yml` — CMake build/test and markdown checks

## Spec parity

Mirrors [twilic/twilic](https://github.com/twilic/twilic); references [twilic-dart](https://github.com/twilic/twilic-dart).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
