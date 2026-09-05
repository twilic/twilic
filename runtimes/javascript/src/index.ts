import { initBackend, requireBackend } from "./backend.js";
import { rethrowDecodeError } from "./errors.js";
import { encodeFast, tryDecodeFast } from "./fast-codec.js";
import type { RuntimeKind, RuntimeSessionEncoder } from "./runtime/types.js";
import {
  serializeCompact,
  serializeCompactBatch,
  serializeSchema,
  serializeSessionOptions,
  serializeValues,
  serializeValue,
} from "./transport.js";
import type {
  InitOptions,
  TwilicValue,
  Schema,
  SessionOptions,
} from "./types.js";

export type {
  InitOptions,
  WasmInput,
  TwilicValue,
  Schema,
  SchemaField,
  SessionOptions,
  UnknownReferencePolicy,
} from "./types.js";
export {
  DEFAULT_MAX_DECODE_DEPTH,
  TwilicDecodeError,
  decodeDepthLimitMessage,
} from "./errors.js";

type EncodeImpl = (value: TwilicValue) => Uint8Array;
type DecodeImpl = (bytes: Uint8Array) => TwilicValue;

let encodeImpl: EncodeImpl | null = null;
let decodeImpl: DecodeImpl | null = null;

export async function init(options: InitOptions = {}): Promise<RuntimeKind> {
  const kind = await initBackend(options);
  encodeImpl = null;
  decodeImpl = null;
  return kind;
}

export function encode(value: TwilicValue): Uint8Array {
  if (!encodeImpl) {
    requireBackend();
    encodeImpl = (input) => encodeFast(input);
  }
  return encodeImpl(value);
}

export function decode(bytes: Uint8Array): TwilicValue {
  if (!decodeImpl) {
    const backend = requireBackend();
    if (backend.decodeNative) {
      decodeImpl = (input) => {
        try {
          return backend.decodeNative!(input) as TwilicValue;
        } catch (error) {
          return rethrowDecodeError(error);
        }
      };
    } else {
      decodeImpl = (input) => {
        const decoded = tryDecodeFast(input);
        if (decoded === undefined) {
          throw new Error("twilic: failed to decode payload");
        }
        return decoded;
      };
    }
  }
  return decodeImpl(bytes);
}

export function createSessionEncoder(
  options: SessionOptions = {}
): SessionEncoder {
  const raw = requireBackend().createSessionEncoder(
    serializeSessionOptions(options)
  );
  return new SessionEncoder(raw);
}

export class SessionEncoder {
  readonly #inner: RuntimeSessionEncoder;

  constructor(inner: RuntimeSessionEncoder) {
    this.#inner = inner;
  }

  encode(value: TwilicValue): Uint8Array {
    return this.#inner.encodeCompactJson(serializeCompact(value));
  }

  encodeBatch(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBatchCompactJson(serializeCompactBatch(values));
  }

  encodeBoundStream(schema: Schema, values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBoundStreamTransportJson(
      serializeSchema(schema),
      serializeValues(values)
    );
  }

  encodeBatchWithSchema(schema: Schema, values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBatchWithSchemaTransportJson(
      serializeSchema(schema),
      serializeValues(values)
    );
  }

  encodePatch(value: TwilicValue): Uint8Array {
    return this.#inner.encodePatchTransportJson(serializeValue(value));
  }

  encodeMicroBatch(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeMicroBatchCompactJson(
      serializeCompactBatch(values)
    );
  }

  reset(): void {
    this.#inner.reset();
  }
}
