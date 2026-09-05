# Twilic (R)

R implementation of the Twilic wire format and session-aware encoder/decoder.

This package's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## Install

```r
# From source (requires R >= 4.4)
install.packages("testthat") # for tests
R CMD INSTALL .
```

## Usage

```r
library(twilic)

value <- new_map(
  entry("id", new_u64(1)),
  entry("name", new_string("alice"))
)

bytes <- encode(value)
decoded <- decode(bytes)
stopifnot(equal(decoded, value))

codec <- new_twilic_codec()
roundtrip <- codec$decode_value(codec$encode_value(new_string("alpha")))
stopifnot(equal(roundtrip, new_string("alpha")))
```

## Development

```bash
Rscript -e 'testthat::test_dir("tests/testthat")'
./scripts/check-interop.sh   # requires Rust fixtures + optional devtools::load_all
```

## Layout

| Path | Role |
| --- | --- |
| `R/` | Core modules (`wire`, `codec`, `v2`, `protocol`, `session`, …) |
| `tests/testthat/` | testthat v3 spec tests |
| `inst/interop/` | Rust interop fixture emit/decode scripts |

## Status

Full **3.0.0** port: v2 wire format, session protocol (patches, batches, control streams, dictionaries), Rust interop fixtures, and spec tests aligned with `twilic-ruby`.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
