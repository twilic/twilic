import type { WasmInput } from "../types.js";
import type {
  RuntimeBackend,
  RuntimeSessionEncoder,
  TransportValueObj,
} from "./types.js";

interface WasmSessionEncoder {
  encodeTransportJson(valueJson: string): Uint8Array;
  encodeDirectTransportJson(valueJson: string): Uint8Array;
  encodeWithSchemaTransportJson(
    schemaJson: string,
    valueJson: string
  ): Uint8Array;
  encodeBatchTransportJson(valuesJson: string): Uint8Array;
  encodeBoundStreamTransportJson(
    schemaJson: string,
    valuesJson: string
  ): Uint8Array;
  encodeBatchWithSchemaTransportJson(
    schemaJson: string,
    valuesJson: string
  ): Uint8Array;
  encodeBatchDirectTransportJson(valuesJson: string): Uint8Array;
  encodePatchTransportJson(valueJson: string): Uint8Array;
  encodePatchDirectTransportJson(valueJson: string): Uint8Array;
  encodeMicroBatchTransportJson(valuesJson: string): Uint8Array;
  encodeMicroBatchDirectTransportJson(valuesJson: string): Uint8Array;
  encodeCompactJson(json: string): Uint8Array;
  encodeBatchCompactJson(json: string): Uint8Array;
  encodePatchCompactJson(json: string): Uint8Array;
  encodeMicroBatchCompactJson(json: string): Uint8Array;
  reset(): void;
}

interface WasmModule {
  default: (input?: WasmInput) => Promise<unknown>;
  encodeTransportJson(valueJson: string): Uint8Array;
  encodeDirectTransportJson(valueJson: string): Uint8Array;
  decodeToTransportJson(bytes: Uint8Array): string;
  decodeToCompactJson(bytes: Uint8Array): string;
  encodeWithSchemaTransportJson(
    schemaJson: string,
    valueJson: string
  ): Uint8Array;
  encodeBatchTransportJson(valuesJson: string): Uint8Array;
  encodeBoundStreamTransportJson(
    schemaJson: string,
    valuesJson: string
  ): Uint8Array;
  encodeBatchWithSchemaTransportJson(
    schemaJson: string,
    valuesJson: string
  ): Uint8Array;
  encodeBatchDirectTransportJson(valuesJson: string): Uint8Array;
  encodeCompactJson(json: string): Uint8Array;
  encodeBatchCompactJson(json: string): Uint8Array;
  createSessionEncoder(optionsJson?: string): WasmSessionEncoder;
}

export async function loadWasmBackend(
  wasmInput?: WasmInput
): Promise<RuntimeBackend> {
  const moduleUrl = new URL("../../wasm/pkg/twilic_wasm.js", import.meta.url);
  const wasm = (await import(moduleUrl.href)) as WasmModule;
  // bundler target auto-initializes via static WASM import; web/deno targets
  // expose an explicit async default init function that must be called.
  if (typeof wasm.default === "function") {
    await wasm.default(wasmInput);
  }
  return {
    kind: "wasm",
    encodeTransportJson: (valueJson) => wasm.encodeTransportJson(valueJson),
    decodeToTransportJson: (bytes) => wasm.decodeToTransportJson(bytes),
    decodeToCompactJson: (bytes) => wasm.decodeToCompactJson(bytes),
    encodeWithSchemaTransportJson: (schemaJson, valueJson) =>
      wasm.encodeWithSchemaTransportJson(schemaJson, valueJson),
    encodeBatchTransportJson: (valuesJson) =>
      wasm.encodeBatchTransportJson(valuesJson),
    encodeBoundStreamTransportJson: (schemaJson, valuesJson) =>
      wasm.encodeBoundStreamTransportJson(schemaJson, valuesJson),
    encodeBatchWithSchemaTransportJson: (schemaJson, valuesJson) =>
      wasm.encodeBatchWithSchemaTransportJson(schemaJson, valuesJson),
    encodeDirect: (value) =>
      wasm.encodeDirectTransportJson(JSON.stringify(value)),
    decodeDirect: (bytes) =>
      JSON.parse(wasm.decodeToTransportJson(bytes)) as TransportValueObj,
    encodeBatchDirect: (values) =>
      wasm.encodeBatchDirectTransportJson(JSON.stringify(values)),
    encodeCompactJson: (json) => wasm.encodeCompactJson(json),
    encodeBatchCompactJson: (json) => wasm.encodeBatchCompactJson(json),
    createSessionEncoder: (optionsJson) => {
      const inner = wasm.createSessionEncoder(optionsJson);
      return wrapSessionEncoder(inner);
    },
  };
}

function wrapSessionEncoder(inner: WasmSessionEncoder): RuntimeSessionEncoder {
  return {
    encodeTransportJson: (valueJson) => inner.encodeTransportJson(valueJson),
    encodeWithSchemaTransportJson: (schemaJson, valueJson) =>
      inner.encodeWithSchemaTransportJson(schemaJson, valueJson),
    encodeBatchTransportJson: (valuesJson) =>
      inner.encodeBatchTransportJson(valuesJson),
    encodeBoundStreamTransportJson: (schemaJson, valuesJson) =>
      inner.encodeBoundStreamTransportJson(schemaJson, valuesJson),
    encodeBatchWithSchemaTransportJson: (schemaJson, valuesJson) =>
      inner.encodeBatchWithSchemaTransportJson(schemaJson, valuesJson),
    encodePatchTransportJson: (valueJson) =>
      inner.encodePatchTransportJson(valueJson),
    encodeMicroBatchTransportJson: (valuesJson) =>
      inner.encodeMicroBatchTransportJson(valuesJson),
    encodeDirect: (value) =>
      inner.encodeDirectTransportJson(JSON.stringify(value)),
    encodeBatchDirect: (values) =>
      inner.encodeBatchDirectTransportJson(JSON.stringify(values)),
    encodePatchDirect: (value) =>
      inner.encodePatchDirectTransportJson(JSON.stringify(value)),
    encodeMicroBatchDirect: (values) =>
      inner.encodeMicroBatchDirectTransportJson(JSON.stringify(values)),
    encodeCompactJson: (json) => inner.encodeCompactJson(json),
    encodeBatchCompactJson: (json) => inner.encodeBatchCompactJson(json),
    encodePatchCompactJson: (json) => inner.encodePatchCompactJson(json),
    encodeMicroBatchCompactJson: (json) =>
      inner.encodeMicroBatchCompactJson(json),
    reset: () => inner.reset(),
  };
}
