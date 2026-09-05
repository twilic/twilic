import { createDecodedMap, setDecodedMapEntry } from "./safe-map-key.js";
import type { TwilicValue, Schema, SessionOptions } from "./types.js";

export type TransportValue =
  | { t: "null" }
  | { t: "bool"; v: boolean }
  | { t: "i64"; v: string }
  | { t: "u64"; v: string }
  | { t: "f64"; v: number }
  | { t: "string"; v: string }
  | { t: "binary"; v: string }
  | { t: "array"; v: TransportValue[] }
  | { t: "map"; v: Array<[string, TransportValue]> };

type TransportInt = number | string;

interface TransportSchemaField {
  number: TransportInt;
  name: string;
  logicalType: string;
  required: boolean;
  defaultValue?: TransportValue;
  min?: TransportInt;
  max?: TransportInt;
  enumValues?: string[];
}

interface TransportSchema {
  schemaId: TransportInt;
  name: string;
  fields: TransportSchemaField[];
}

interface TransportSessionOptions {
  maxBaseSnapshots?: number;
  enableStatePatch?: boolean;
  enableTemplateBatch?: boolean;
  enableTrainedDictionary?: boolean;
  unknownReferencePolicy?: "failFast" | "statelessRetry";
}

const MAX_U64 = (1n << 64n) - 1n;
const MIN_I64 = -(1n << 63n);
const MAX_I64 = (1n << 63n) - 1n;

export function serializeValue(value: TwilicValue): string {
  return JSON.stringify(toTransportValue(value));
}

export function deserializeValue(json: string): TwilicValue {
  const parsed = JSON.parse(json) as TransportValue;
  return fromTransportValue(parsed);
}

export function serializeValues(values: TwilicValue[]): string {
  // oxlint-disable-next-line unicorn/no-new-array
  const out = new Array<TransportValue>(values.length);
  for (let index = 0; index < values.length; index += 1) {
    out[index] = toTransportValue(values[index]);
  }
  return JSON.stringify(out);
}

export function serializeSchema(schema: Schema): string {
  // oxlint-disable-next-line unicorn/no-new-array
  const fields = new Array<TransportSchemaField>(schema.fields.length);
  for (let index = 0; index < schema.fields.length; index += 1) {
    const field = schema.fields[index];
    const out: TransportSchemaField = {
      number: toTransportInteger(field.number, "field.number", true),
      name: field.name,
      logicalType: field.logicalType,
      required: field.required,
    };
    if (field.defaultValue !== undefined) {
      out.defaultValue = toTransportValue(field.defaultValue);
    }
    if (field.min !== undefined) {
      out.min = toTransportInteger(field.min, "field.min", false);
    }
    if (field.max !== undefined) {
      out.max = toTransportInteger(field.max, "field.max", false);
    }
    if (field.enumValues !== undefined) {
      out.enumValues = field.enumValues;
    }
    fields[index] = out;
  }

  const payload: TransportSchema = {
    schemaId: toTransportInteger(schema.schemaId, "schemaId", true),
    name: schema.name,
    fields,
  };
  return JSON.stringify(payload);
}

export function serializeSessionOptions(options: SessionOptions = {}): string {
  const payload: TransportSessionOptions = {};
  if (options.maxBaseSnapshots !== undefined) {
    if (
      !Number.isInteger(options.maxBaseSnapshots) ||
      options.maxBaseSnapshots < 0
    ) {
      throw new Error("maxBaseSnapshots must be a non-negative integer");
    }
    payload.maxBaseSnapshots = options.maxBaseSnapshots;
  }
  if (options.enableStatePatch !== undefined) {
    payload.enableStatePatch = options.enableStatePatch;
  }
  if (options.enableTemplateBatch !== undefined) {
    payload.enableTemplateBatch = options.enableTemplateBatch;
  }
  if (options.enableTrainedDictionary !== undefined) {
    payload.enableTrainedDictionary = options.enableTrainedDictionary;
  }
  if (options.unknownReferencePolicy !== undefined) {
    payload.unknownReferencePolicy = options.unknownReferencePolicy;
  }
  return JSON.stringify(payload);
}

export function toTransportValue(value: TwilicValue): TransportValue {
  if (value === null) {
    return { t: "null" };
  }
  if (typeof value === "boolean") {
    return { t: "bool", v: value };
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error("number values must be finite");
    }
    if (Number.isInteger(value)) {
      if (!Number.isSafeInteger(value)) {
        throw new Error(
          "unsafe integer number detected; use bigint for 64-bit integers"
        );
      }
      return value >= 0
        ? { t: "u64", v: String(value) }
        : { t: "i64", v: String(value) };
    }
    return { t: "f64", v: value };
  }
  if (typeof value === "bigint") {
    if (value >= 0n) {
      if (value > MAX_U64) {
        throw new Error("u64 overflow");
      }
      return { t: "u64", v: value.toString() };
    }
    if (value < MIN_I64 || value > MAX_I64) {
      throw new Error("i64 overflow");
    }
    return { t: "i64", v: value.toString() };
  }
  if (typeof value === "string") {
    return { t: "string", v: value };
  }
  if (value instanceof Uint8Array) {
    return { t: "binary", v: toBase64(value) };
  }
  if (Array.isArray(value)) {
    const length = value.length;
    // oxlint-disable-next-line unicorn/no-new-array
    const out = new Array<TransportValue>(length);
    for (let index = 0; index < length; index += 1) {
      out[index] = toTransportValue(value[index]);
    }
    return { t: "array", v: out };
  }

  if (typeof value !== "object" || value === null) {
    throw new Error("unsupported value type");
  }

  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error("unsupported value type");
  }

  const entries: Array<[string, TransportValue]> = [];
  const objectValue = value as Record<string, TwilicValue>;
  for (const key in objectValue) {
    entries.push([key, toTransportValue(objectValue[key])]);
  }
  return { t: "map", v: entries };
}

export function toTransportValues(values: TwilicValue[]): TransportValue[] {
  // oxlint-disable-next-line unicorn/no-new-array
  const out = new Array<TransportValue>(values.length);
  for (let index = 0; index < values.length; index += 1) {
    out[index] = toTransportValue(values[index]);
  }
  return out;
}

export function fromTransportValue(value: TransportValue): TwilicValue {
  switch (value.t) {
    case "null":
      return null;
    case "bool":
      return value.v;
    case "i64":
      return BigInt(value.v);
    case "u64":
      return BigInt(value.v);
    case "f64":
      return value.v;
    case "string":
      return value.v;
    case "binary":
      return fromBase64(value.v);
    case "array": {
      const length = value.v.length;
      // oxlint-disable-next-line unicorn/no-new-array
      const out = new Array<TwilicValue>(length);
      for (let index = 0; index < length; index += 1) {
        out[index] = fromTransportValue(value.v[index]);
      }
      return out;
    }
    case "map": {
      const out = createDecodedMap();
      const length = value.v.length;
      for (let index = 0; index < length; index += 1) {
        const entry = value.v[index];
        setDecodedMapEntry(out, entry[0], fromTransportValue(entry[1]));
      }
      return out;
    }
    default:
      throw new Error("unknown transport value kind");
  }
}

function toTransportInteger(
  value: number | bigint,
  fieldName: string,
  unsigned: boolean
): TransportInt {
  if (typeof value === "number") {
    if (!Number.isInteger(value) || !Number.isSafeInteger(value)) {
      throw new Error(`${fieldName} must be a safe integer number or bigint`);
    }
    if (unsigned && value < 0) {
      throw new Error(`${fieldName} must be unsigned`);
    }
    return value;
  }
  if (unsigned) {
    if (value < 0n || value > MAX_U64) {
      throw new Error(`${fieldName} must fit u64`);
    }
    return value.toString();
  }
  if (value < MIN_I64 || value > MAX_I64) {
    throw new Error(`${fieldName} must fit i64`);
  }
  return value.toString();
}

function toBase64(bytes: Uint8Array): string {
  if (typeof Buffer !== "undefined") {
    return Buffer.from(
      bytes.buffer,
      bytes.byteOffset,
      bytes.byteLength
    ).toString("base64");
  }
  if (typeof btoa === "function") {
    let binary = "";
    for (let index = 0; index < bytes.length; index += 1) {
      binary += String.fromCharCode(bytes[index]);
    }
    return btoa(binary);
  }
  throw new Error("base64 encoding is not available in this runtime");
}

function fromBase64(encoded: string): Uint8Array {
  if (typeof Buffer !== "undefined") {
    return Buffer.from(encoded, "base64");
  }
  if (typeof atob === "function") {
    const binary = atob(encoded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  }
  throw new Error("base64 decoding is not available in this runtime");
}

// ── Compact transport format ────────────────────────────────────────────────
//
// Tags: 0=null, 1=bool, 2=i64, 3=u64, 4=f64, 5=string, 6=binary, 7=array, 8=map
// Format: [tag] for null, [tag, value] for everything else.
// Map value is a flat array: [key1, val1, key2, val2, ...]
// This produces ~50% shorter JSON than the object-based transport format.

type CompactValue = readonly [number] | readonly [number, unknown];

export function serializeCompact(value: TwilicValue): string {
  const out: string[] = [];
  appendCompactValue(value, out);
  return out.join("");
}

export function deserializeCompact(json: string): TwilicValue {
  const parsed = JSON.parse(json) as CompactValue;
  return fromCompactValue(parsed);
}

export function serializeCompactBatch(values: TwilicValue[]): string {
  const out: string[] = ["["];
  for (let index = 0; index < values.length; index += 1) {
    if (index > 0) {
      out.push(",");
    }
    appendCompactValue(values[index], out);
  }
  out.push("]");
  return out.join("");
}

function appendCompactValue(value: TwilicValue, out: string[]): void {
  if (value === null) {
    out.push("[0]");
    return;
  }
  if (typeof value === "boolean") {
    out.push(value ? "[1,true]" : "[1,false]");
    return;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error("number values must be finite");
    }
    if (Number.isInteger(value)) {
      if (!Number.isSafeInteger(value)) {
        throw new Error(
          "unsafe integer number detected; use bigint for 64-bit integers"
        );
      }
      out.push(value >= 0 ? '[3,"' : '[2,"', String(value), '"]');
      return;
    }
    out.push("[4,", String(value), "]");
    return;
  }
  if (typeof value === "bigint") {
    if (value >= 0n) {
      if (value > MAX_U64) {
        throw new Error("u64 overflow");
      }
      out.push('[3,"', value.toString(), '"]');
      return;
    }
    if (value < MIN_I64 || value > MAX_I64) {
      throw new Error("i64 overflow");
    }
    out.push('[2,"', value.toString(), '"]');
    return;
  }
  if (typeof value === "string") {
    out.push("[5,");
    appendJsonString(value, out);
    out.push("]");
    return;
  }
  if (value instanceof Uint8Array) {
    out.push('[6,"', toBase64(value), '"]');
    return;
  }
  if (Array.isArray(value)) {
    out.push("[7,[");
    for (let index = 0; index < value.length; index += 1) {
      if (index > 0) {
        out.push(",");
      }
      appendCompactValue(value[index], out);
    }
    out.push("]]");
    return;
  }

  if (typeof value !== "object" || value === null) {
    throw new Error("unsupported value type");
  }

  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error("unsupported value type");
  }

  // Map: flat array [key1, val1, key2, val2, ...]
  const objectValue = value as Record<string, TwilicValue>;
  const keys = Object.keys(objectValue);
  out.push("[8,[");
  for (let index = 0; index < keys.length; index += 1) {
    if (index > 0) {
      out.push(",");
    }
    appendJsonString(keys[index], out);
    out.push(",");
    appendCompactValue(objectValue[keys[index]], out);
  }
  out.push("]]");
}

function appendJsonString(value: string, out: string[]): void {
  out.push('"');
  let start = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    let escape: string | null = null;
    switch (code) {
      case 0x22:
        escape = '\\"';
        break;
      case 0x5c:
        escape = "\\\\";
        break;
      case 0x0a:
        escape = "\\n";
        break;
      case 0x0d:
        escape = "\\r";
        break;
      case 0x09:
        escape = "\\t";
        break;
      default:
        if (code < 0x20) {
          escape = `\\u00${code.toString(16).padStart(2, "0")}`;
        }
        break;
    }
    if (escape === null) {
      continue;
    }
    if (start < index) {
      out.push(value.slice(start, index));
    }
    out.push(escape);
    start = index + 1;
  }
  if (start < value.length) {
    out.push(value.slice(start));
  }
  out.push('"');
}

function fromCompactValue(cv: CompactValue): TwilicValue {
  const tag = cv[0] as number;
  switch (tag) {
    case 0: // null
      return null;
    case 1: // bool
      return (cv as readonly [number, boolean])[1];
    case 2: // i64
      return BigInt((cv as readonly [number, string])[1]);
    case 3: // u64
      return BigInt((cv as readonly [number, string])[1]);
    case 4: // f64
      return (cv as readonly [number, number])[1];
    case 5: // string
      return (cv as readonly [number, string])[1];
    case 6: // binary
      return fromBase64((cv as readonly [number, string])[1]);
    case 7: {
      // array
      const items = (cv as readonly [number, CompactValue[]])[1];
      const length = items.length;
      // oxlint-disable-next-line unicorn/no-new-array
      const out = new Array<TwilicValue>(length);
      for (let index = 0; index < length; index += 1) {
        out[index] = fromCompactValue(items[index]);
      }
      return out;
    }
    case 8: {
      // map: flat array [key1, val1, key2, val2, ...]
      const flat = (cv as readonly [number, unknown[]])[1];
      const out = createDecodedMap();
      const length = flat.length;
      for (let index = 0; index < length; index += 2) {
        setDecodedMapEntry(
          out,
          flat[index] as string,
          fromCompactValue(flat[index + 1] as CompactValue)
        );
      }
      return out;
    }
    default:
      throw new Error(`unknown compact tag: ${tag}`);
  }
}
