import type {
  RuntimeBackend,
  RuntimeSessionEncoder,
  TransportValueObj,
} from "./types.js";

export interface NativeSessionEncoder {
  encodeTransportJson(valueJson: string): Uint8Array;
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
  encodePatchTransportJson(valueJson: string): Uint8Array;
  encodeMicroBatchTransportJson(valuesJson: string): Uint8Array;
  encodeDirect(value: TransportValueObj): Uint8Array;
  encodeBatchDirect(values: TransportValueObj[]): Uint8Array;
  encodePatchDirect(value: TransportValueObj): Uint8Array;
  encodeMicroBatchDirect(values: TransportValueObj[]): Uint8Array;
  encodeCompactJson(json: string): Uint8Array;
  encodeBatchCompactJson(json: string): Uint8Array;
  encodePatchCompactJson(json: string): Uint8Array;
  encodeMicroBatchCompactJson(json: string): Uint8Array;
  reset(): void;
}

export interface NativeModule {
  encodeNative(value: unknown): Uint8Array;
  decodeNative(bytes: Uint8Array): unknown;
  encodeTransportJson(valueJson: string): Uint8Array;
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
  encodeDirect(value: TransportValueObj): Uint8Array;
  decodeDirect(bytes: Uint8Array): TransportValueObj;
  encodeBatchDirect(values: TransportValueObj[]): Uint8Array;
  encodeCompactJson(json: string): Uint8Array;
  encodeBatchCompactJson(json: string): Uint8Array;
  encodeBatchNativeRaw(values: unknown): Uint8Array;
  createSessionEncoder(optionsJson?: string): NativeSessionEncoder;
}

export function createNodeRuntimeBackend(native: NativeModule): RuntimeBackend {
  return {
    kind: "napi",
    encodeNative: (value) => asUint8Array(native.encodeNative(value)),
    decodeNative: (bytes) => native.decodeNative(bytes),
    encodeTransportJson: (valueJson) =>
      asUint8Array(native.encodeTransportJson(valueJson)),
    decodeToTransportJson: (bytes) => native.decodeToTransportJson(bytes),
    decodeToCompactJson: (bytes) => native.decodeToCompactJson(bytes),
    encodeWithSchemaTransportJson: (schemaJson, valueJson) =>
      asUint8Array(native.encodeWithSchemaTransportJson(schemaJson, valueJson)),
    encodeBatchTransportJson: (valuesJson) =>
      asUint8Array(native.encodeBatchTransportJson(valuesJson)),
    encodeBoundStreamTransportJson: (schemaJson, valuesJson) =>
      asUint8Array(
        native.encodeBoundStreamTransportJson(schemaJson, valuesJson)
      ),
    encodeBatchWithSchemaTransportJson: (schemaJson, valuesJson) =>
      asUint8Array(
        native.encodeBatchWithSchemaTransportJson(schemaJson, valuesJson)
      ),
    encodeDirect: (value) => asUint8Array(native.encodeDirect(value)),
    decodeDirect: (bytes) => native.decodeDirect(bytes),
    encodeBatchDirect: (values) =>
      asUint8Array(native.encodeBatchDirect(values)),
    encodeCompactJson: (json) => asUint8Array(native.encodeCompactJson(json)),
    encodeBatchCompactJson: (json) =>
      asUint8Array(native.encodeBatchCompactJson(json)),
    encodeBatchNativeRaw: (values) =>
      asUint8Array(native.encodeBatchNativeRaw(values)),
    createSessionEncoder: (optionsJson) => {
      const inner = native.createSessionEncoder(optionsJson);
      return wrapSessionEncoder(inner);
    },
  };
}

function wrapSessionEncoder(
  inner: NativeSessionEncoder
): RuntimeSessionEncoder {
  return {
    encodeTransportJson: (valueJson) =>
      asUint8Array(inner.encodeTransportJson(valueJson)),
    encodeWithSchemaTransportJson: (schemaJson, valueJson) =>
      asUint8Array(inner.encodeWithSchemaTransportJson(schemaJson, valueJson)),
    encodeBatchTransportJson: (valuesJson) =>
      asUint8Array(inner.encodeBatchTransportJson(valuesJson)),
    encodeBoundStreamTransportJson: (schemaJson, valuesJson) =>
      asUint8Array(
        inner.encodeBoundStreamTransportJson(schemaJson, valuesJson)
      ),
    encodeBatchWithSchemaTransportJson: (schemaJson, valuesJson) =>
      asUint8Array(
        inner.encodeBatchWithSchemaTransportJson(schemaJson, valuesJson)
      ),
    encodePatchTransportJson: (valueJson) =>
      asUint8Array(inner.encodePatchTransportJson(valueJson)),
    encodeMicroBatchTransportJson: (valuesJson) =>
      asUint8Array(inner.encodeMicroBatchTransportJson(valuesJson)),
    encodeDirect: (value) => asUint8Array(inner.encodeDirect(value)),
    encodeBatchDirect: (values) =>
      asUint8Array(inner.encodeBatchDirect(values)),
    encodePatchDirect: (value) => asUint8Array(inner.encodePatchDirect(value)),
    encodeMicroBatchDirect: (values) =>
      asUint8Array(inner.encodeMicroBatchDirect(values)),
    encodeCompactJson: (json) => asUint8Array(inner.encodeCompactJson(json)),
    encodeBatchCompactJson: (json) =>
      asUint8Array(inner.encodeBatchCompactJson(json)),
    encodePatchCompactJson: (json) =>
      asUint8Array(inner.encodePatchCompactJson(json)),
    encodeMicroBatchCompactJson: (json) =>
      asUint8Array(inner.encodeMicroBatchCompactJson(json)),
    reset: () => inner.reset(),
  };
}

function asUint8Array(value: Uint8Array): Uint8Array {
  return value;
}
