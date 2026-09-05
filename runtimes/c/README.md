# Twilic (C)

C implementation of the Twilic wire format and session-aware encoder/decoder.

This library's default `twilic_encode` / `twilic_decode` API targets Twilic v2 (v3 support pending).

The public API in `include/twilic/twilic.h` is C11. Implementation sources in `src/*.c` are algorithmically aligned with [twilic-cpp](https://github.com/twilic/twilic-cpp) and spec tests with [twilic-go](https://github.com/twilic/twilic-go) `internal/core`. Sources currently compile as C++17 for parity with the reference implementation while the mechanical C11 port (structs, manual memory, no STL) proceeds module by module.

## What this library provides

- Dynamic encoding/decoding (`twilic_encode`, `twilic_decode`)
- Schema-aware encoding (`twilic_encode_with_schema`)
- Batch encoding (`twilic_encode_batch`)
- Value constructors and `twilic_value_free` / `twilic_buffer_free`
- Spec tests ported from twilic-go (`dynamic_profile`, `bound_batch_stateful`, `codec_spec_vectors`, `control_stream`, `coverage_boost`, `interop_fixtures`)
- Cross-language interop fixtures and Rust smoke checks

## Project layout

```text
twilic-c/
  include/twilic/         # headers (public twilic.h + internal modules)
  src/                    # wire, errors, model, codec, session, protocol, v2, dictionary, interop_fixtures, twilic.c
  test/                   # spec tests (assert macro harness)
  tools/                  # emit_rust_client_fixtures, decode_rust_server_fixtures
  scripts/                # check-interop.sh, check-c-client-interop.sh
  docs/
```

## Requirements

- CMake 3.16+
- C11-capable compiler
- C++17 compiler (for building internal implementation sources today)

## Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-Wall -Wextra -Werror" \
  -DCMAKE_CXX_FLAGS="-Wall -Wextra -Werror"
cmake --build build
ctest --test-dir build --output-on-failure
```

## Quick start

```c
#include "twilic/twilic.h"

twilic_map_entry_t entries[] = {
    twilic_entry("id", twilic_u64(1001)),
    twilic_entry("name", twilic_string("alice")),
};
twilic_value_t value = twilic_map(entries, 2);

twilic_buffer_t encoded = {0};
twilic_error_t err = {0};
if (twilic_encode(&value, &encoded, &err) != 0) { /* handle err */ }

twilic_value_t decoded = twilic_null();
twilic_decode(encoded.data, encoded.len, &decoded, &err);

twilic_value_free(&decoded);
twilic_value_free(&value);
twilic_buffer_free(&encoded);
```

## Interop

```bash
./scripts/check-interop.sh
```

## CI (GitHub Actions)

- `.github/workflows/ci.yml` — CMake build, `ctest`, and markdown checks (`-Wall -Wextra -Werror`)

## Spec parity

Mirrors [twilic/twilic](https://github.com/twilic/twilic). Algorithms reference [twilic-cpp](https://github.com/twilic/twilic-cpp); spec tests reference [twilic-go](https://github.com/twilic/twilic-go) `internal/core`.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
