import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

import { createNodeRuntimeBackend, type NativeModule } from "./node-adapter.js";
import type { RuntimeBackend } from "./types.js";

export function loadNodeBackend(): RuntimeBackend {
  const require = createRequire(import.meta.url);
  const platformKey = `${process.platform}-${process.arch}`;
  const modulePath = fileURLToPath(
    new URL(`../../native/twilic_napi-${platformKey}.node`, import.meta.url)
  );
  const native = require(modulePath) as NativeModule;
  return createNodeRuntimeBackend(native);
}
