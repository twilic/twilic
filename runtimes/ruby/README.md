# Twilic (Ruby)

Ruby implementation of the Twilic wire format and session-aware encoder/decoder.

This gem's default `Twilic.encode` / `Twilic.decode` API targets Twilic v2 (v3 support pending).

## What this gem provides

- Dynamic encoding/decoding (`Twilic.encode`, `Twilic.decode`)
- Schema-aware encoding (`Twilic.encode_with_schema`)
- Batch and micro-batch encoding (`Twilic.encode_batch`, `SessionEncoder#encode_micro_batch`)
- Stateful features (base snapshots, state patch, template batch, control stream, trained dictionary)

## Project layout

```text
twilic-ruby/
  lib/twilic.rb                   # public API
  lib/twilic/core/                # wire, model, codec, session, protocol, v2
  scripts/                        # Rust interop fixtures and smoke checks
  docs/
```

The repository root stays thin: `require "twilic"` only. Implementation details live under `lib/twilic/core/`, similar to `internal/core/` in the Go module.

## Requirements

- Ruby 3.3 or later

## Install

```bash
gem install twilic
```

Or add to your Gemfile:

```ruby
gem "twilic"
```

## Quick start

```ruby
require "twilic"

value = Twilic.map(
  "id" => Twilic.u64(1001),
  "name" => Twilic.string("alice")
)

bytes = Twilic.encode(value)
decoded = Twilic.decode(bytes)
puts Twilic.equal(decoded, value) # => true
```

## Session encoder example

```ruby
require "twilic"

enc = Twilic.new_session_encoder

value = Twilic.map(
  "id" => Twilic.u64(1),
  "role" => Twilic.string("admin")
)

bytes = enc.encode(value)
```

## Development

Run checks locally:

```bash
bundle install
bundle exec rake test
```

Rust client interop smoke check (Ruby server -> Rust client):

```bash
bash scripts/check-rust-client-interop.sh
```

Ruby client interop smoke check (Rust server -> Ruby client):

```bash
bash scripts/check-ruby-client-interop.sh
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
- Release workflow: `.github/workflows/publish-gem.yml` (tag `v*` must match `lib/twilic/version.rb`)

## Spec parity

This gem mirrors the Twilic wire format spec at [twilic/twilic](https://github.com/twilic/twilic) and stays in lockstep with the [Rust](https://github.com/twilic/twilic-rust), [Go](https://github.com/twilic/twilic-go), and [Zig](https://github.com/twilic/twilic-zig) reference implementations.

See [`docs/SPEC-TEST-TRACEABILITY.md`](docs/SPEC-TEST-TRACEABILITY.md) for the spec-section to test mapping.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
