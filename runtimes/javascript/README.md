# Twilic (JS)

JavaScript/TypeScript bindings for `twilic-rust` with two backends:

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

GitHub Actions publish uses [npm trusted publishing (OIDC)](https://docs.npmjs.com/trusted-publishers/)—no long-lived `NPM_TOKEN` secret.

One-time setup on [npmjs.com](https://www.npmjs.com/package/@twilic/core): open the package → **Settings** → **Trusted Publisher** → **GitHub Actions**, then set **Organization or user** `twilic`, **Repository** `twilic-js`, and **Workflow filename** `publish-npm.yml` (exact name, including `.yml`). See also [GitHub Actions OIDC](https://docs.github.com/en/actions/concepts/security/openid-connect).

Release steps:

1. Bump `version` in `package.json`.
2. Create and push matching tag `v<version>`.

Example:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow `.github/workflows/publish-npm.yml` verifies tag/version match and then runs `npm publish` (OIDC authentication via `id-token: write`).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
