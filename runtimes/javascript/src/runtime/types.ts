export type RuntimeKind = "napi" | "wasm";

export interface TransportValueObj {
  t: string;
  v?: unknown;
}

export interface RuntimeSessionEncoder {
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

export interface RuntimeBackend {
  kind: RuntimeKind;
  encodeNative?: (value: unknown) => Uint8Array;
  decodeNative?: (bytes: Uint8Array) => unknown;
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
  encodeBatchNativeRaw?: (values: unknown) => Uint8Array;
  createSessionEncoder(optionsJson?: string): RuntimeSessionEncoder;
}
