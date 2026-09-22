# Twilic (JS)

JavaScript/TypeScript bindings for the Rust runtime with two backends:

- Node.js: N-API (`twilic-napi`)
- Browser/JS runtime: WebAssembly (`twilic-wasm`)

Integers decode as `bigint` by default (i64/u64 safe handling).

This release line targets the Twilic v3 wire format (Dynamic Profile by default).

## Requirements

- Node.js 24+
- Rust stable
- `wasm-pack` for WASM builds

## Build

```bash
pnpm install
pnpm build
```

Build steps:

1. Build N-API addon (`native/twilic_napi.node`)
2. Build WASM package (`wasm/pkg/*`)
3. Build TypeScript output (`dist/*`)

## Formatting and lint

```bash
pnpm fmt
pnpm fmt:check
pnpm lint
pnpm lint:fix
```

## Test

```bash
pnpm test
```

What it validates:

- Rust bridge tests (`test:rust`)
- Node API tests (`test:node`) covering `init`, `encode`, `decode`, schema, batch, and session APIs
- TypeScript API usage against built output

## Usage (Node)

```ts
import {
  encode,
  decode,
  createSessionEncoder,
  createSessionDecoder,
  type TwilicValue,
} from "@twilic/core";

const value: TwilicValue = {
  id: 1001n,
  name: "alice",
  active: true,
};

const bytes = encode(value);
const roundtrip = decode(bytes);

const session = createSessionEncoder();
const first = session.encode(value);
const patch = session.encodePatch({ ...value, name: "alicia" });

const decoder = createSessionDecoder();
decoder.decode(first);
decoder.decode(patch);
```

Node.js picks the N-API backend automatically on first use. The default APIs already use the fastest benchmarked path for each operation, so you should not need to choose between transport JSON, compact JSON, or direct object modes.

## Advanced APIs

If you need raw transport helpers, explicit schema encoding, or internal-format control, import the advanced entrypoint:

```ts
import {
  createSessionEncoder,
  encodeTransportJson,
  encodeWithSchema,
  toTransportJson,
} from "@twilic/core/advanced";
```

This entrypoint contains:

- transport JSON helpers
- compact JSON helpers
- direct object helpers
- schema encoding helpers
- v3 `encodeBoundStream` / `encodeBatchWithSchema`
- full raw session encoder methods

## Usage (Browser)

```ts
import { init, encode, decode } from "@twilic/core";

await init({ prefer: "wasm" });

const bytes = encode({ id: 1n, role: "admin" });
const value = decode(bytes);
```

Browser/WASM still requires explicit async initialization. If you want to pass a custom WASM source, use `wasmInput` with a value from your own asset pipeline (not from user-controlled input such as URL parameters):

```ts
await init({ prefer: "wasm", wasmInput: "/assets/twilic_wasm_bg.wasm" });
```

## TypeScript types

Main exported types:

- `TwilicValue`
- `WasmInput`, `InitOptions`
- `Schema`, `SchemaField`
- `SessionOptions`

`TwilicValue` includes `bigint` and `Uint8Array` support:

```ts
type TwilicValue =
  | null
  | boolean
  | number
  | bigint
  | string
  | Uint8Array
  | TwilicValue[]
  | { [key: string]: TwilicValue };
```

## Publish to npm

The package is configured for npm publish and ships build artifacts from `dist/`, `native/`, and `wasm/pkg/`.

Local dry run:

```bash
pnpm build
pnpm pack
```

Release tags use `runtimes/javascript/vX.Y.Z` (see [`docs/releases.md`](../../docs/releases.md)):

```bash
git tag runtimes/javascript/v3.2.0
git push origin runtimes/javascript/v3.2.0
```

Automated npm publish runs via `.github/workflows/publish-npm.yml` on `runtimes/javascript/v*` tags (OIDC trusted publishing with provenance). Configure the npm Trusted Publisher for `@twilic/core` against Organization `twilic`, Repository `twilic`, Workflow filename `publish-npm.yml`, and Environment `npm-publish`. See [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/) and [GitHub Actions OIDC](https://docs.github.com/en/actions/concepts/security/openid-connect).

The workflow builds N-API addons on Linux, macOS, and Windows, builds WASM + TypeScript once, then publishes with `npm publish --access public --provenance --ignore-scripts`.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
