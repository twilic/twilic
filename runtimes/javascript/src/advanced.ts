import { initBackend, requireBackend } from "./backend.js";
import { rethrowDecodeError } from "./errors.js";
import { encodeFast, tryDecodeFast } from "./fast-codec.js";
import type { RuntimeKind, RuntimeSessionEncoder } from "./runtime/types.js";
import {
  deserializeValue,
  fromTransportValue,
  serializeCompact,
  serializeCompactBatch,
  serializeSchema,
  serializeSessionOptions,
  serializeValue,
  serializeValues,
  toTransportValue,
  toTransportValues,
} from "./transport.js";
import type { TransportValue } from "./transport.js";
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

type EncodeImpl = (value: TwilicValue) => Uint8Array;
type DecodeImpl = (bytes: Uint8Array) => TwilicValue;
type EncodeBatchImpl = (values: TwilicValue[]) => Uint8Array;

let encodeImpl: EncodeImpl | null = null;
let decodeImpl: DecodeImpl | null = null;
let encodeBatchImpl: EncodeBatchImpl | null = null;

export async function init(options: InitOptions = {}): Promise<RuntimeKind> {
  const kind = await initBackend(options);
  encodeImpl = null;
  decodeImpl = null;
  encodeBatchImpl = null;
  return kind;
}

export function encode(value: TwilicValue): Uint8Array {
  if (!encodeImpl) {
    requireBackend();
    encodeImpl = (input) => encodeFast(input);
  }
  return encodeImpl(value);
}

export function encodeBatch(values: TwilicValue[]): Uint8Array {
  if (!encodeBatchImpl) {
    requireBackend();
    encodeBatchImpl = (input) => encodeFast(input);
  }
  return encodeBatchImpl(values);
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

export function toTransportJson(value: TwilicValue): string {
  return serializeValue(value);
}

export function fromTransportJson(valueJson: string): TwilicValue {
  return deserializeValue(valueJson);
}

export function toTransportJsonBatch(values: TwilicValue[]): string {
  return serializeValues(values);
}

export function encodeTransportJson(valueJson: string): Uint8Array {
  return requireBackend().encodeTransportJson(valueJson);
}

export function decodeToTransportJson(bytes: Uint8Array): string {
  return requireBackend().decodeToTransportJson(bytes);
}

export function encodeBatchTransportJson(valuesJson: string): Uint8Array {
  return requireBackend().encodeBatchTransportJson(valuesJson);
}

export function encodeBoundStream(
  schema: Schema,
  values: TwilicValue[]
): Uint8Array {
  return requireBackend().encodeBoundStreamTransportJson(
    serializeSchema(schema),
    serializeValues(values)
  );
}

export function encodeBoundStreamTransportJson(
  schemaJson: string,
  valuesJson: string
): Uint8Array {
  return requireBackend().encodeBoundStreamTransportJson(
    schemaJson,
    valuesJson
  );
}

export function encodeBatchWithSchema(
  schema: Schema,
  values: TwilicValue[]
): Uint8Array {
  return requireBackend().encodeBatchWithSchemaTransportJson(
    serializeSchema(schema),
    serializeValues(values)
  );
}

export function encodeBatchWithSchemaTransportJson(
  schemaJson: string,
  valuesJson: string
): Uint8Array {
  return requireBackend().encodeBatchWithSchemaTransportJson(
    schemaJson,
    valuesJson
  );
}

export function encodeWithSchema(
  schema: Schema,
  value: TwilicValue
): Uint8Array {
  return requireBackend().encodeWithSchemaTransportJson(
    serializeSchema(schema),
    serializeValue(value)
  );
}

export function encodeDirect(value: TwilicValue): Uint8Array {
  return requireBackend().encodeDirect(
    toTransportValue(
      value
    ) as unknown as import("./runtime/types.js").TransportValueObj
  );
}

export function decodeDirect(bytes: Uint8Array): TwilicValue {
  const transport = requireBackend().decodeDirect(bytes);
  return fromTransportValue(transport as unknown as TransportValue);
}

export function encodeBatchDirect(values: TwilicValue[]): Uint8Array {
  return requireBackend().encodeBatchDirect(
    toTransportValues(
      values
    ) as unknown as import("./runtime/types.js").TransportValueObj[]
  );
}

export function toCompactJson(value: TwilicValue): string {
  return serializeCompact(value);
}

export function toCompactJsonBatch(values: TwilicValue[]): string {
  return serializeCompactBatch(values);
}

export function encodeCompactJson(json: string): Uint8Array {
  return requireBackend().encodeCompactJson(json);
}

export function decodeToCompactJson(bytes: Uint8Array): string {
  return requireBackend().decodeToCompactJson(bytes);
}

export function encodeBatchCompactJson(json: string): Uint8Array {
  return requireBackend().encodeBatchCompactJson(json);
}

export function encodeCompact(value: TwilicValue): Uint8Array {
  return requireBackend().encodeCompactJson(serializeCompact(value));
}

export function encodeBatchCompact(values: TwilicValue[]): Uint8Array {
  return requireBackend().encodeBatchCompactJson(serializeCompactBatch(values));
}

export function createSessionEncoder(
  options: SessionOptions = {}
): AdvancedSessionEncoder {
  const raw = requireBackend().createSessionEncoder(
    serializeSessionOptions(options)
  );
  return new AdvancedSessionEncoder(raw);
}

export class AdvancedSessionEncoder {
  readonly #inner: RuntimeSessionEncoder;

  constructor(inner: RuntimeSessionEncoder) {
    this.#inner = inner;
  }

  encode(value: TwilicValue): Uint8Array {
    return this.#inner.encodeCompactJson(serializeCompact(value));
  }

  encodeTransportJson(valueJson: string): Uint8Array {
    return this.#inner.encodeTransportJson(valueJson);
  }

  encodeWithSchema(schema: Schema, value: TwilicValue): Uint8Array {
    return this.#inner.encodeWithSchemaTransportJson(
      serializeSchema(schema),
      serializeValue(value)
    );
  }

  encodeBatch(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBatchCompactJson(serializeCompactBatch(values));
  }

  encodeBatchTransportJson(valuesJson: string): Uint8Array {
    return this.#inner.encodeBatchTransportJson(valuesJson);
  }

  encodeBoundStream(schema: Schema, values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBoundStreamTransportJson(
      serializeSchema(schema),
      serializeValues(values)
    );
  }

  encodeBoundStreamTransportJson(
    schemaJson: string,
    valuesJson: string
  ): Uint8Array {
    return this.#inner.encodeBoundStreamTransportJson(schemaJson, valuesJson);
  }

  encodeBatchWithSchema(schema: Schema, values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBatchWithSchemaTransportJson(
      serializeSchema(schema),
      serializeValues(values)
    );
  }

  encodeBatchWithSchemaTransportJson(
    schemaJson: string,
    valuesJson: string
  ): Uint8Array {
    return this.#inner.encodeBatchWithSchemaTransportJson(
      schemaJson,
      valuesJson
    );
  }

  encodePatch(value: TwilicValue): Uint8Array {
    return this.#inner.encodePatchTransportJson(serializeValue(value));
  }

  encodePatchTransportJson(valueJson: string): Uint8Array {
    return this.#inner.encodePatchTransportJson(valueJson);
  }

  encodeMicroBatch(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeMicroBatchCompactJson(
      serializeCompactBatch(values)
    );
  }

  encodeMicroBatchTransportJson(valuesJson: string): Uint8Array {
    return this.#inner.encodeMicroBatchTransportJson(valuesJson);
  }

  encodeDirect(value: TwilicValue): Uint8Array {
    return this.#inner.encodeDirect(
      toTransportValue(
        value
      ) as unknown as import("./runtime/types.js").TransportValueObj
    );
  }

  encodeBatchDirect(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBatchDirect(
      toTransportValues(
        values
      ) as unknown as import("./runtime/types.js").TransportValueObj[]
    );
  }

  encodePatchDirect(value: TwilicValue): Uint8Array {
    return this.#inner.encodePatchDirect(
      toTransportValue(
        value
      ) as unknown as import("./runtime/types.js").TransportValueObj
    );
  }

  encodeMicroBatchDirect(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeMicroBatchDirect(
      toTransportValues(
        values
      ) as unknown as import("./runtime/types.js").TransportValueObj[]
    );
  }

  encodeCompact(value: TwilicValue): Uint8Array {
    return this.#inner.encodeCompactJson(serializeCompact(value));
  }

  encodeCompactJson(json: string): Uint8Array {
    return this.#inner.encodeCompactJson(json);
  }

  encodeBatchCompact(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeBatchCompactJson(serializeCompactBatch(values));
  }

  encodeBatchCompactJson(json: string): Uint8Array {
    return this.#inner.encodeBatchCompactJson(json);
  }

  encodePatchCompact(value: TwilicValue): Uint8Array {
    return this.#inner.encodePatchCompactJson(serializeCompact(value));
  }

  encodePatchCompactJson(json: string): Uint8Array {
    return this.#inner.encodePatchCompactJson(json);
  }

  encodeMicroBatchCompact(values: TwilicValue[]): Uint8Array {
    return this.#inner.encodeMicroBatchCompactJson(
      serializeCompactBatch(values)
    );
  }

  encodeMicroBatchCompactJson(json: string): Uint8Array {
    return this.#inner.encodeMicroBatchCompactJson(json);
  }

  reset(): void {
    this.#inner.reset();
  }
}
