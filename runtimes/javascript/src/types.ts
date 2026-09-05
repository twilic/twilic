export type TwilicValue =
  | null
  | boolean
  | number
  | bigint
  | string
  | Uint8Array
  | TwilicValue[]
  | { [key: string]: TwilicValue };

export interface SchemaField {
  number: number | bigint;
  name: string;
  logicalType: string;
  required: boolean;
  defaultValue?: TwilicValue;
  min?: number | bigint;
  max?: number | bigint;
  enumValues?: string[];
}

export interface Schema {
  schemaId: number | bigint;
  name: string;
  fields: SchemaField[];
}

export type UnknownReferencePolicy = "failFast" | "statelessRetry";

export interface SessionOptions {
  maxBaseSnapshots?: number;
  enableStatePatch?: boolean;
  enableTemplateBatch?: boolean;
  enableTrainedDictionary?: boolean;
  unknownReferencePolicy?: UnknownReferencePolicy;
}

/** WASM module source accepted by wasm-bindgen init. Must come from a trusted source (your asset pipeline), not user input. */
export type WasmInput =
  | string
  | URL
  | Request
  | Response
  | BufferSource
  | Promise<Response | BufferSource>;

export interface InitOptions {
  prefer?: "napi" | "wasm";
  /** Custom WASM source for browser init. Do not forward values from untrusted input (URL params, postMessage, etc.). */
  wasmInput?: WasmInput;
}
