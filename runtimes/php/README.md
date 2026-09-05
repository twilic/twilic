# Twilic (PHP)

PHP implementation of the Twilic wire format and session-aware encoder/decoder.

This library's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this library provides

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encode_with_schema`)
- Batch encoding (`encode_batch`, `SessionEncoder`)
- Codec primitives (`Twilic\Codec`) and v2 wire profile (`Twilic\V2`)

## Project layout

```text
twilic-php/
  src/bootstrap.php              # global encode/decode helpers
  src/Twilic/                    # wire, model, codec, session, v2
  tests/
  scripts/                         # Rust interop fixtures and smoke checks
  bin/                             # interop CLI helpers
  docs/
```

## Requirements

- PHP 8.3 or later
- [Composer](https://getcomposer.org/)

## Install

From source (until published on Packagist):

```bash
composer require twilic/twilic:@dev
```

## Quick start

```php
<?php

require 'vendor/autoload.php';

use function Twilic\decode;
use function Twilic\encode;
use function Twilic\new_map;
use function Twilic\new_string;
use function Twilic\new_u64;
use function Twilic\entry;

$value = new_map(
    entry('id', new_u64(1001)),
    entry('name', new_string('alice')),
);

$data = encode($value);
$decoded = decode($data);
```

## Development

Run checks locally:

```bash
composer install
composer test
```

Rust client interop smoke check (PHP server → Rust client):

```bash
bash scripts/check-rust-client-interop.sh
```

PHP client interop smoke check (Rust server → PHP client):

```bash
bash scripts/check-php-client-interop.sh
```

Full bidirectional interop (unit tests + both directions; uses `../rust` or `TWILIC_RUST_ROOT`):

```bash
bash scripts/check-interop.sh
```

## Markdown formatting

Documentation is formatted and linted with Prettier and markdownlint (see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md)).

## CI (GitHub Actions)

- CI workflow: `.github/workflows/ci.yml`
- Commitlint, invisible character check, and PR body validation workflows under `.github/workflows/`
- Interop workflow: `.github/workflows/interop.yml`

## Spec parity

This library mirrors the Twilic wire format spec at [twilic/twilic](https://github.com/twilic/twilic) and tracks [twilic-python](https://github.com/twilic/twilic-python) and [twilic-java](https://github.com/twilic/twilic-java).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
