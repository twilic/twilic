# Twilic (Elixir)

Elixir implementation of the Twilic wire format and session-aware encoder/decoder.

This library's default `encode` / `decode` API targets Twilic v2 (v3 support pending).

## What this library provides

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encode_with_schema`)
- Batch encoding (`encode_batch`, `SessionEncoder`)
- Native modules under `lib/twilic/`

## Project layout

```text
twilic-elixir/
  lib/twilic/             # wire, model, codec, session, protocol, v2
  test/
  docs/
```

## Requirements

- Elixir 1.19+ and OTP 27+

## Install

```elixir
def deps do
  [
    {:twilic, git: "https://github.com/twilic/twilic-elixir.git"}
  ]
end
```

## Quick start

```elixir
value =
  Twilic.new_map([
    Twilic.entry("id", Twilic.new_u64(1001)),
    Twilic.entry("name", Twilic.new_string("alice")),
  ])

encoded = Twilic.encode(value)
decoded = Twilic.decode(encoded)
```

## Development

```bash
mix deps.get
mix test
```

## Markdown formatting

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

## CI (GitHub Actions)

- `.github/workflows/ci.yml` — `mix test` and markdown checks

## Spec parity

Mirrors [twilic/twilic](https://github.com/twilic/twilic); ported from [twilic-dart](https://github.com/twilic/twilic-dart).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
