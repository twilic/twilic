import {
  createNodeRuntimeBackend,
  type NativeModule,
} from "./runtime/node-adapter.js";
import type { RuntimeBackend, RuntimeKind } from "./runtime/types.js";
import type { InitOptions } from "./types.js";

let backend: RuntimeBackend | null = null;
let initPromise: Promise<RuntimeBackend> | null = null;

export async function initBackend(
  options: InitOptions = {}
): Promise<RuntimeKind> {
  if (backend) {
    return backend.kind;
  }
  if (!initPromise) {
    initPromise = loadBackend(options).catch((error: unknown) => {
      initPromise = null;
      throw error;
    });
  }
  backend = await initPromise;
  return backend.kind;
}

export function requireBackend(): RuntimeBackend {
  if (backend) {
    return backend;
  }

  const autoLoaded = tryLoadDefaultBackendSync();
  if (autoLoaded) {
    backend = autoLoaded;
    return autoLoaded;
  }

  throw new Error(
    "twilic is not initialized. Call await init() before encode/decode in browser runtimes."
  );
}

async function loadBackend(options: InitOptions): Promise<RuntimeBackend> {
  const prefer = options.prefer;
  if (prefer === "napi") {
    if (!isNodeRuntime()) {
      throw new Error("N-API backend is only available in Node.js");
    }
    const { loadNodeBackend } = await import("./runtime/node-backend.js");
    return loadNodeBackend();
  }
  if (prefer === "wasm") {
    if (isNodeRuntime()) {
      throw new Error(
        "WASM backend is intended for browser JS. Use prefer: 'napi' on Node.js"
      );
    }
    const { loadWasmBackend } = await import("./runtime/wasm-backend.js");
    return loadWasmBackend(options.wasmInput);
  }

  if (isNodeRuntime()) {
    const { loadNodeBackend } = await import("./runtime/node-backend.js");
    return loadNodeBackend();
  }
  const { loadWasmBackend } = await import("./runtime/wasm-backend.js");
  return loadWasmBackend(options.wasmInput);
}

function isNodeRuntime(): boolean {
  return typeof process !== "undefined" && Boolean(process.versions?.node);
}

function tryLoadDefaultBackendSync(): RuntimeBackend | null {
  if (!isNodeRuntime()) {
    return null;
  }

  const nodeProcess = process as typeof process & {
    getBuiltinModule?: (id: string) => unknown;
  };
  const moduleApi = (nodeProcess.getBuiltinModule?.("node:module") ??
    nodeProcess.getBuiltinModule?.("module")) as
    | { createRequire(url: string): (id: string) => unknown }
    | undefined;
  const urlApi = (nodeProcess.getBuiltinModule?.("node:url") ??
    nodeProcess.getBuiltinModule?.("url")) as
    | { fileURLToPath(url: URL): string }
    | undefined;

  if (!moduleApi || !urlApi) {
    throw new Error(
      "Node auto-init requires process.getBuiltinModule; call await init() explicitly if unavailable."
    );
  }

  const require = moduleApi.createRequire(import.meta.url);
  const platformKey = `${process.platform}-${process.arch}`;
  const modulePath = urlApi.fileURLToPath(
    new URL(`../native/twilic_napi-${platformKey}.node`, import.meta.url)
  );
  const native = require(modulePath) as NativeModule;
  return createNodeRuntimeBackend(native);
}
