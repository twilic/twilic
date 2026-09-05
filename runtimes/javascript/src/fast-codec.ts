import {
  decodeDepthLimitMessage,
  DEFAULT_MAX_DECODE_DEPTH,
  TwilicDecodeError,
} from "./errors.js";
import { createDecodedMap, setDecodedMapEntry } from "./safe-map-key.js";
import type { TwilicValue } from "./types.js";

const TAG_NULL = 0xc0;
const TAG_BOOL_FALSE = 0xc1;
const TAG_BOOL_TRUE = 0xc2;
const TAG_F64 = 0xc3;
const TAG_U8 = 0xc4;
const TAG_U16 = 0xc5;
const TAG_U32 = 0xc6;
const TAG_U64 = 0xc7;
const TAG_I8 = 0xc8;
const TAG_I16 = 0xc9;
const TAG_I32 = 0xca;
const TAG_I64 = 0xcb;
const TAG_BIN8 = 0xcc;
const TAG_BIN16 = 0xcd;
const TAG_BIN32 = 0xce;
const TAG_STR8 = 0xcf;
const TAG_STR16 = 0xd0;
const TAG_STR32 = 0xd1;
const TAG_ARRAY16 = 0xd2;
const TAG_ARRAY32 = 0xd3;
const TAG_MAP16 = 0xd4;
const TAG_MAP32 = 0xd5;
const TAG_SHAPE_DEF = 0xd6;
const TAG_KEY_REF = 0xd8;
const TAG_STR_REF = 0xd9;

const MAX_U64 = (1n << 64n) - 1n;
const MIN_I64 = -(1n << 63n);
const MAX_I64 = (1n << 63n) - 1n;

const ENCODE_CACHE_LIMIT = 4096;
const DECODE_FAIL = Symbol("decode_fail");
const DECODE_DEPTH_EXCEEDED = Symbol("decode_depth_exceeded");

type DecodeValue =
  | TwilicValue
  | typeof DECODE_FAIL
  | typeof DECODE_DEPTH_EXCEEDED;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

const mapKeyUtf8Cache = new Map<string, Uint8Array>();
const stringUtf8Cache = new Map<string, Uint8Array>();

const BIGINT_TINY_OFFSET = 128;
const BIGINT_TINY_MAX = 255;
const BIGINT_TINY: bigint[] = [];
for (let i = -BIGINT_TINY_OFFSET; i <= BIGINT_TINY_MAX; i += 1) {
  BIGINT_TINY.push(BigInt(i));
}

const sharedKeys: string[] = [];
const sharedStrings: string[] = [];
const sharedShapes: string[][] = [];
const EMPTY_BYTES = new Uint8Array(0);
let pooledReader: ByteReader | null = null;
const pooledState: DecodeState = {
  keys: sharedKeys,
  strings: sharedStrings,
  shapes: sharedShapes,
  depth: 0,
  maxDepth: DEFAULT_MAX_DECODE_DEPTH,
  outputRemaining: 0,
};

// Reuse Maps across encodeFast calls to avoid per-call GC pressure
const _encodeKeyIds = new Map<string, number>();
const _encodeStringIds = new Map<string, number>();
const _encodeShapeIds = new Map<string, number>();
const _encodeState: EncodeState = {
  keyIds: _encodeKeyIds,
  stringIds: _encodeStringIds,
  shapeIds: _encodeShapeIds,
  nextKeyId: 0,
  nextStringId: 0,
  nextShapeId: 0,
};

export function encodeFast(value: TwilicValue): Uint8Array {
  _encodeWriter.reset(256);
  _encodeKeyIds.clear();
  _encodeStringIds.clear();
  _encodeShapeIds.clear();
  _encodeState.nextKeyId = 0;
  _encodeState.nextStringId = 0;
  _encodeState.nextShapeId = 0;
  writeValue(value, _encodeWriter, _encodeState);
  return _encodeWriter.finish();
}

export function tryDecodeFast(bytes: Uint8Array): TwilicValue | undefined {
  sharedKeys.length = 0;
  sharedStrings.length = 0;
  sharedShapes.length = 0;
  pooledState.depth = 0;
  pooledState.outputRemaining = Math.min(1 << 20, bytes.byteLength * 1024);
  pooledState.maxDepth = DEFAULT_MAX_DECODE_DEPTH;
  if (pooledReader === null) {
    pooledReader = new ByteReader();
  }
  pooledReader.reset(bytes);

  const decoded = decodeRoot(bytes);
  if (decoded === DECODE_DEPTH_EXCEEDED) {
    throw new TwilicDecodeError(decodeDepthLimitMessage(pooledState.maxDepth));
  }
  if (decoded === DECODE_FAIL || pooledReader.offset < bytes.byteLength) {
    return undefined;
  }
  return decoded;
}

function decodeRoot(bytes: Uint8Array): DecodeValue {
  if (pooledReader === null) {
    return DECODE_FAIL;
  }
  const firstTag = bytes.byteLength > 0 ? bytes[0] : -1;
  if (firstTag < 0) {
    return DECODE_FAIL;
  }
  if (firstTag >= 0xb0 && firstTag <= 0xbf) {
    pooledReader.offset = 1;
    return decodeFixMapInline(
      bytes,
      pooledReader,
      pooledState,
      firstTag & 0x0f
    );
  }
  return readValueAuto(pooledReader, pooledState);
}

class ByteWriter {
  #buffer: Uint8Array;
  #view: DataView;
  #length = 0;

  constructor(initialSize: number) {
    this.#buffer = new Uint8Array(initialSize);
    this.#view = new DataView(this.#buffer.buffer);
  }

  reset(minSize: number): void {
    this.#length = 0;
    if (this.#buffer.byteLength < minSize) {
      this.#buffer = new Uint8Array(minSize);
      this.#view = new DataView(this.#buffer.buffer);
    }
  }

  finish(): Uint8Array {
    return this.#buffer.slice(0, this.#length);
  }

  pushByte(byte: number): void {
    this.#ensure(1);
    this.#buffer[this.#length] = byte;
    this.#length += 1;
  }

  pushBytes(bytes: Uint8Array): void {
    this.#ensure(bytes.byteLength);
    this.#buffer.set(bytes, this.#length);
    this.#length += bytes.byteLength;
  }

  pushU16(value: number): void {
    this.#ensure(2);
    this.#view.setUint16(this.#length, value, true);
    this.#length += 2;
  }

  pushU32(value: number): void {
    this.#ensure(4);
    this.#view.setUint32(this.#length, value, true);
    this.#length += 4;
  }

  pushU64(value: bigint): void {
    this.#ensure(8);
    this.#view.setBigUint64(this.#length, value, true);
    this.#length += 8;
  }

  writeVaruint(value: number | bigint): void {
    if (typeof value === "number") {
      if (value < 0x80) {
        this.pushByte(value);
        return;
      }
      let current = value;
      while (current >= 0x80) {
        this.pushByte((current & 0x7f) | 0x80);
        current = Math.floor(current / 128);
      }
      this.pushByte(current);
      return;
    }

    let current = value;
    while (current >= 0x80n) {
      const low = Number(current & 0x7fn);
      this.pushByte(low | 0x80);
      current >>= 7n;
    }
    this.pushByte(Number(current));
  }

  writeSmallestU64(value: bigint): void {
    if (value <= 0xffn) {
      this.pushByte(1);
      this.pushByte(Number(value));
      return;
    }
    if (value <= 0xffffn) {
      this.pushByte(2);
      this.#ensure(2);
      this.#view.setUint16(this.#length, Number(value), true);
      this.#length += 2;
      return;
    }
    if (value <= 0xffff_ffffn) {
      this.pushByte(4);
      this.#ensure(4);
      this.#view.setUint32(this.#length, Number(value), true);
      this.#length += 4;
      return;
    }

    this.pushByte(8);
    this.#ensure(8);
    this.#view.setBigUint64(this.#length, value, true);
    this.#length += 8;
  }

  writeF64(value: number): void {
    this.#ensure(8);
    this.#view.setFloat64(this.#length, value, true);
    this.#length += 8;
  }

  writeString(value: string, cacheKind: "mapKey" | "string"): void {
    if (value.length === 0) {
      this.writeVaruint(0);
      return;
    }

    const encoded =
      cacheKind === "mapKey"
        ? getCachedUtf8(mapKeyUtf8Cache, value)
        : getCachedUtf8(stringUtf8Cache, value);
    this.writeVaruint(encoded.byteLength);
    this.pushBytes(encoded);
  }

  #ensure(additionalBytes: number): void {
    const required = this.#length + additionalBytes;
    if (required <= this.#buffer.byteLength) {
      return;
    }

    let nextSize = this.#buffer.byteLength;
    while (nextSize < required) {
      nextSize *= 2;
    }

    const nextBuffer = new Uint8Array(nextSize);
    nextBuffer.set(this.#buffer);
    this.#buffer = nextBuffer;
    this.#view = new DataView(nextBuffer.buffer);
  }
}

const _encodeWriter = new ByteWriter(4096);

class ByteReader {
  bytes: Uint8Array = EMPTY_BYTES;
  offset = 0;
  #view: DataView | null = null;

  reset(bytes: Uint8Array): void {
    this.bytes = bytes;
    this.offset = 0;
    this.#view = null;
  }

  #getView(): DataView {
    if (this.#view === null) {
      this.#view = new DataView(
        this.bytes.buffer,
        this.bytes.byteOffset,
        this.bytes.byteLength
      );
    }
    return this.#view;
  }

  isEof(): boolean {
    return this.offset >= this.bytes.byteLength;
  }

  readByte(): number | null {
    if (this.offset >= this.bytes.byteLength) {
      return null;
    }
    const byte = this.bytes[this.offset];
    this.offset += 1;
    return byte;
  }

  readVaruint(): number | null {
    let result = 0;
    let multiplier = 1;

    while (true) {
      const byte = this.readByte();
      if (byte === null) {
        return null;
      }

      result += (byte & 0x7f) * multiplier;
      if (result > Number.MAX_SAFE_INTEGER) {
        return null;
      }

      if ((byte & 0x80) === 0) {
        return result;
      }

      multiplier *= 0x80;
      if (multiplier > Number.MAX_SAFE_INTEGER) {
        return null;
      }
    }
  }

  readSmallestU64(): bigint | null {
    const size = this.readByte();
    if (size === null) {
      return null;
    }

    if (size === 1) {
      const value = this.readByte();
      return value === null ? null : tinyBigInt(value);
    }

    if (size === 2) {
      const value = this.readU16();
      return value === null ? null : BigInt(value);
    }

    if (size === 4) {
      const value = this.readU32();
      return value === null ? null : BigInt(value);
    }

    if (size === 8) {
      const value = this.readU64();
      return value === null ? null : value;
    }

    return null;
  }

  readF64(): number | null {
    if (this.offset + 8 > this.bytes.byteLength) {
      return null;
    }
    const value = this.#getView().getFloat64(this.offset, true);
    this.offset += 8;
    return value;
  }

  readString(): string | null {
    const length = this.readVaruint();
    if (length === null) {
      return null;
    }

    if (this.offset + length > this.bytes.byteLength) {
      return null;
    }

    const start = this.offset;
    this.offset += length;
    return textDecoder.decode(this.bytes.subarray(start, start + length));
  }

  readStringOfLength(length: number): string | null {
    if (this.offset + length > this.bytes.byteLength) {
      return null;
    }
    const start = this.offset;
    this.offset += length;
    if (length <= 32) {
      const ascii = decodeShortAscii(this.bytes, start, length);
      if (ascii !== null) {
        return ascii;
      }
    }
    return textDecoder.decode(this.bytes.subarray(start, start + length));
  }

  readBinaryOfLength(length: number): Uint8Array | null {
    if (this.offset + length > this.bytes.byteLength) {
      return null;
    }
    const start = this.offset;
    this.offset += length;
    return this.bytes.slice(start, start + length);
  }

  readU16(): number | null {
    const o = this.offset;
    if (o + 2 > this.bytes.byteLength) {
      return null;
    }
    this.offset = o + 2;
    return this.bytes[o] | (this.bytes[o + 1] << 8);
  }

  readU32(): number | null {
    const o = this.offset;
    if (o + 4 > this.bytes.byteLength) {
      return null;
    }
    this.offset = o + 4;
    return (
      (this.bytes[o] |
        (this.bytes[o + 1] << 8) |
        (this.bytes[o + 2] << 16) |
        (this.bytes[o + 3] << 24)) >>>
      0
    );
  }

  readU64(): bigint | null {
    if (this.offset + 8 > this.bytes.byteLength) {
      return null;
    }
    const value = this.#getView().getBigUint64(this.offset, true);
    this.offset += 8;
    return value;
  }

  readI16(): number | null {
    const o = this.offset;
    if (o + 2 > this.bytes.byteLength) {
      return null;
    }
    this.offset = o + 2;
    const value = this.bytes[o] | (this.bytes[o + 1] << 8);
    return (value << 16) >> 16;
  }

  readI32(): number | null {
    const o = this.offset;
    if (o + 4 > this.bytes.byteLength) {
      return null;
    }
    this.offset = o + 4;
    return (
      this.bytes[o] |
      (this.bytes[o + 1] << 8) |
      (this.bytes[o + 2] << 16) |
      (this.bytes[o + 3] << 24)
    );
  }

  readI64(): bigint | null {
    if (this.offset + 8 > this.bytes.byteLength) {
      return null;
    }
    const value = this.#getView().getBigInt64(this.offset, true);
    this.offset += 8;
    return value;
  }

  readBinary(): Uint8Array | null {
    const length = this.readVaruint();
    if (length === null) {
      return null;
    }

    if (this.offset + length > this.bytes.byteLength) {
      return null;
    }

    const start = this.offset;
    this.offset += length;
    return this.bytes.slice(start, start + length);
  }
}

interface DecodeState {
  keys: string[];
  strings: string[];
  shapes: string[][];
  depth: number;
  maxDepth: number;
  outputRemaining: number;
}

// The same collection/shape limits are applied by the native decoder.
function checkDecodeCount(count: number, max = 1 << 20): void {
  if (!Number.isSafeInteger(count) || count < 0 || count > max) {
    throw new TwilicDecodeError(
      "twilic: decode count limit exceeded",
      "DECODE_LIMIT_EXCEEDED"
    );
  }
}

function claimDecodeOutput(state: DecodeState, count: number, width = 8): void {
  checkDecodeCount(count);
  const bytes = count * width;
  if (bytes > state.outputRemaining) {
    throw new TwilicDecodeError(
      "twilic: decode output ratio exceeded",
      "DECODE_LIMIT_EXCEEDED"
    );
  }
  state.outputRemaining -= bytes;
}

function enterDecodeContainer(
  state: DecodeState
): typeof DECODE_DEPTH_EXCEEDED | void {
  if (state.depth >= state.maxDepth) {
    return DECODE_DEPTH_EXCEEDED;
  }
  state.depth += 1;
}

function leaveDecodeContainer(state: DecodeState): void {
  state.depth -= 1;
}

function isDecodeFailure(
  value: DecodeValue
): value is typeof DECODE_FAIL | typeof DECODE_DEPTH_EXCEEDED {
  return value === DECODE_FAIL || value === DECODE_DEPTH_EXCEEDED;
}

interface EncodeState {
  keyIds: Map<string, number>;
  stringIds: Map<string, number>;
  shapeIds: Map<string, number>;
  nextKeyId: number;
  nextStringId: number;
  nextShapeId: number;
}

function writeValue(
  value: TwilicValue,
  writer: ByteWriter,
  state: EncodeState
): void {
  if (value === null) {
    writer.pushByte(TAG_NULL);
    return;
  }

  if (typeof value === "boolean") {
    writer.pushByte(value ? TAG_BOOL_TRUE : TAG_BOOL_FALSE);
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
      if (value >= 0) {
        if (value <= 0x7f) {
          writer.pushByte(value);
          return;
        }
        if (value <= 0xff) {
          writer.pushByte(TAG_U8);
          writer.pushByte(value);
          return;
        }
        if (value <= 0xffff) {
          writer.pushByte(TAG_U16);
          writer.pushU16(value);
          return;
        }
        if (value <= 0xffffffff) {
          writer.pushByte(TAG_U32);
          writer.pushU32(value);
          return;
        }
        writer.pushByte(TAG_U64);
        writer.pushU64(BigInt(value));
        return;
      }
      if (value >= -32) {
        writer.pushByte(value);
        return;
      }
      if (value >= -128) {
        writer.pushByte(TAG_I8);
        writer.pushByte(value);
        return;
      }
      if (value >= -32768) {
        writer.pushByte(TAG_I16);
        writer.pushU16(value);
        return;
      }
      if (value >= -2147483648) {
        writer.pushByte(TAG_I32);
        writer.pushU32(value);
        return;
      }
      writer.pushByte(TAG_I64);
      writer.pushU64(BigInt.asUintN(64, BigInt(value)));
      return;
    }

    writer.pushByte(TAG_F64);
    writer.writeF64(value);
    return;
  }

  if (typeof value === "bigint") {
    if (value >= 0n) {
      if (value > MAX_U64) {
        throw new Error("u64 overflow");
      }
      writeU64(value, writer);
      return;
    }

    if (value < MIN_I64 || value > MAX_I64) {
      throw new Error("i64 overflow");
    }
    writeI64(value, writer);
    return;
  }

  if (typeof value === "string") {
    const existingId = state.stringIds.get(value);
    if (existingId !== undefined) {
      writer.pushByte(TAG_STR_REF);
      writer.writeVaruint(existingId);
      return;
    }
    writeStringLiteral(value, writer);
    state.stringIds.set(value, state.nextStringId);
    state.nextStringId += 1;
    return;
  }

  if (value instanceof Uint8Array) {
    writeBinary(value, writer);
    return;
  }

  if (Array.isArray(value)) {
    const shape = detectShape(value);
    if (shape) {
      const signature = shape.join("\u0001");
      let shapeId = state.shapeIds.get(signature);
      if (shapeId === undefined) {
        shapeId = state.nextShapeId++;
        state.shapeIds.set(signature, shapeId);
      }
      writeArrayHeader(value.length, writer);
      writer.pushByte(TAG_SHAPE_DEF);
      writer.writeVaruint(shapeId);
      writer.writeVaruint(shape.length);
      for (let i = 0; i < shape.length; i += 1) {
        writeKey(shape[i], writer, state);
      }
      for (let i = 0; i < value.length; i += 1) {
        const row = value[i] as Record<string, TwilicValue>;
        for (let j = 0; j < shape.length; j += 1) {
          writeValue(row[shape[j]], writer, state);
        }
      }
      return;
    }
    writeArrayHeader(value.length, writer);
    for (let index = 0; index < value.length; index += 1) {
      writeValue(value[index], writer, state);
    }
    return;
  }

  if (!isPlainMap(value)) {
    throw new Error("unsupported value type");
  }

  const keys = Object.keys(value);
  writeMapHeader(keys.length, writer);
  for (let index = 0; index < keys.length; index += 1) {
    const key = keys[index];
    writeKey(key, writer, state);
    writeValue(value[key], writer, state);
  }
}

function decodeFixMapInline(
  bytes: Uint8Array,
  reader: ByteReader,
  state: DecodeState,
  count: number
):
  | { [key: string]: TwilicValue }
  | typeof DECODE_FAIL
  | typeof DECODE_DEPTH_EXCEEDED {
  const depthError = enterDecodeContainer(state);
  if (depthError === DECODE_DEPTH_EXCEEDED) {
    return DECODE_DEPTH_EXCEEDED;
  }
  try {
    return decodeFixMapInlineBody(bytes, reader, state, count);
  } finally {
    leaveDecodeContainer(state);
  }
}

function decodeFixMapInlineBody(
  bytes: Uint8Array,
  reader: ByteReader,
  state: DecodeState,
  count: number
):
  | { [key: string]: TwilicValue }
  | typeof DECODE_FAIL
  | typeof DECODE_DEPTH_EXCEEDED {
  claimDecodeOutput(state, count);
  const out = createDecodedMap();

  for (let i = 0; i < count; i += 1) {
    let offset = reader.offset;
    if (offset >= bytes.byteLength) {
      return DECODE_FAIL;
    }

    const keyTag = bytes[offset++];
    let key: string;

    if (keyTag >= 0x80 && keyTag <= 0x9f) {
      const keyLen = keyTag & 0x1f;
      if (offset + keyLen > bytes.byteLength) {
        return DECODE_FAIL;
      }
      const decoded = decodeShortAscii(bytes, offset, keyLen);
      if (decoded === null) {
        reader.offset = offset - 1;
        const fallbackKey = readKey(reader, state);
        if (isDecodeFailure(fallbackKey)) {
          return fallbackKey;
        }
        key = fallbackKey;
      } else {
        key = decoded;
        state.keys.push(key);
        offset += keyLen;
        reader.offset = offset;
      }
    } else {
      reader.offset = offset - 1;
      const fallbackKey = readKey(reader, state);
      if (isDecodeFailure(fallbackKey)) {
        return fallbackKey;
      }
      key = fallbackKey;
    }

    offset = reader.offset;
    if (offset >= bytes.byteLength) {
      return DECODE_FAIL;
    }

    const valueTag = bytes[offset++];
    let value: DecodeValue;

    if (valueTag <= 0x7f) {
      value = BIGINT_TINY[valueTag + BIGINT_TINY_OFFSET];
      reader.offset = offset;
    } else if (valueTag >= 0xe0) {
      value = BIGINT_TINY[((valueTag << 24) >> 24) + BIGINT_TINY_OFFSET];
      reader.offset = offset;
    } else if (valueTag === TAG_BOOL_FALSE) {
      value = false;
      reader.offset = offset;
    } else if (valueTag === TAG_BOOL_TRUE) {
      value = true;
      reader.offset = offset;
    } else if (valueTag === TAG_NULL) {
      value = null;
      reader.offset = offset;
    } else if (valueTag === TAG_U8) {
      if (offset + 1 > bytes.byteLength) {
        return DECODE_FAIL;
      }
      value = BIGINT_TINY[bytes[offset] + BIGINT_TINY_OFFSET];
      reader.offset = offset + 1;
    } else if (valueTag === TAG_U16) {
      if (offset + 2 > bytes.byteLength) {
        return DECODE_FAIL;
      }
      value = BigInt(bytes[offset] | (bytes[offset + 1] << 8));
      reader.offset = offset + 2;
    } else if (valueTag === TAG_U32) {
      if (offset + 4 > bytes.byteLength) {
        return DECODE_FAIL;
      }
      value = BigInt(
        (bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24)) >>>
          0
      );
      reader.offset = offset + 4;
    } else if (valueTag >= 0x80 && valueTag <= 0x9f) {
      const valueLen = valueTag & 0x1f;
      if (offset + valueLen > bytes.byteLength) {
        return DECODE_FAIL;
      }
      const decoded = decodeShortAscii(bytes, offset, valueLen);
      if (decoded === null) {
        reader.offset = offset - 1;
        const fallbackValue = readValueAuto(reader, state);
        if (isDecodeFailure(fallbackValue)) {
          return fallbackValue;
        }
        value = fallbackValue;
      } else {
        value = decoded;
        state.strings.push(decoded);
        reader.offset = offset + valueLen;
      }
    } else if (valueTag >= 0xb0 && valueTag <= 0xbf) {
      reader.offset = offset;
      const nested = decodeFixMapInline(bytes, reader, state, valueTag & 0x0f);
      if (isDecodeFailure(nested)) {
        return nested;
      }
      value = nested;
    } else {
      reader.offset = offset - 1;
      const fallbackValue = readValueAuto(reader, state);
      if (isDecodeFailure(fallbackValue)) {
        return fallbackValue;
      }
      value = fallbackValue;
    }

    setDecodedMapEntry(out, key, value);
  }

  return out;
}

function readArrayValue(
  reader: ByteReader,
  state: DecodeState,
  length: number
): TwilicValue[] | typeof DECODE_FAIL | typeof DECODE_DEPTH_EXCEEDED {
  const depthError = enterDecodeContainer(state);
  if (depthError === DECODE_DEPTH_EXCEEDED) {
    return DECODE_DEPTH_EXCEEDED;
  }
  try {
    return readArrayValueBody(reader, state, length);
  } finally {
    leaveDecodeContainer(state);
  }
}

function readArrayValueBody(
  reader: ByteReader,
  state: DecodeState,
  length: number
): TwilicValue[] | typeof DECODE_FAIL | typeof DECODE_DEPTH_EXCEEDED {
  claimDecodeOutput(state, length);
  // oxlint-disable-next-line unicorn/no-new-array
  const out = new Array<TwilicValue>(length);
  if (length === 0) {
    return out;
  }
  const firstTag = reader.readByte();
  if (firstTag === null) {
    return DECODE_FAIL;
  }
  if (firstTag === TAG_SHAPE_DEF) {
    const shapeId = reader.readVaruint();
    const keyCount = reader.readVaruint();
    if (shapeId === null || keyCount === null) {
      return DECODE_FAIL;
    }
    checkDecodeCount(shapeId, 65_535);
    checkDecodeCount(keyCount, 256);
    claimDecodeOutput(state, keyCount);
    // oxlint-disable-next-line unicorn/no-new-array
    const keys = new Array<string>(keyCount);
    for (let i = 0; i < keyCount; i += 1) {
      const key = readKey(reader, state);
      if (isDecodeFailure(key)) {
        return key;
      }
      keys[i] = key;
    }
    if (shapeId >= state.shapes.length)
      claimDecodeOutput(state, shapeId + 1 - state.shapes.length);
    state.shapes[shapeId] = keys;
    for (let i = 0; i < length; i += 1) {
      claimDecodeOutput(state, keyCount);
      const row = createDecodedMap();
      for (let j = 0; j < keys.length; j += 1) {
        const item = readValueAuto(reader, state);
        if (isDecodeFailure(item)) {
          return item;
        }
        setDecodedMapEntry(row, keys[j], item);
      }
      out[i] = row;
    }
    return out;
  }
  const first = readValueWithTag(reader, state, firstTag);
  if (isDecodeFailure(first)) {
    return first;
  }
  out[0] = first;
  for (let index = 1; index < length; index += 1) {
    const item = readValueAuto(reader, state);
    if (isDecodeFailure(item)) {
      return item;
    }
    out[index] = item;
  }
  return out;
}

function readMapValue(
  reader: ByteReader,
  state: DecodeState,
  length: number
):
  | { [key: string]: TwilicValue }
  | typeof DECODE_FAIL
  | typeof DECODE_DEPTH_EXCEEDED {
  const depthError = enterDecodeContainer(state);
  if (depthError === DECODE_DEPTH_EXCEEDED) {
    return DECODE_DEPTH_EXCEEDED;
  }
  try {
    return readMapValueBody(reader, state, length);
  } finally {
    leaveDecodeContainer(state);
  }
}

function readMapValueBody(
  reader: ByteReader,
  state: DecodeState,
  length: number
):
  | { [key: string]: TwilicValue }
  | typeof DECODE_FAIL
  | typeof DECODE_DEPTH_EXCEEDED {
  claimDecodeOutput(state, length);
  const out = createDecodedMap();
  for (let index = 0; index < length; index += 1) {
    const key = readKey(reader, state);
    if (isDecodeFailure(key)) {
      return key;
    }
    const value = readValueAuto(reader, state);
    if (isDecodeFailure(value)) {
      return value;
    }
    setDecodedMapEntry(out, key, value);
  }

  return out;
}

function readValueAuto(reader: ByteReader, state: DecodeState): DecodeValue {
  const tag = reader.readByte();
  if (tag === null) {
    return DECODE_FAIL;
  }
  return readValueWithTag(reader, state, tag);
}

function readValueWithTag(
  reader: ByteReader,
  state: DecodeState,
  tag: number
): DecodeValue {
  if (tag <= 0x7f) {
    return tinyBigInt(tag);
  }
  if (tag >= 0xe0) {
    return tinyBigInt((tag << 24) >> 24);
  }
  if (tag >= 0x80 && tag <= 0x9f) {
    const length = tag & 0x1f;
    const s = reader.readStringOfLength(length);
    if (s === null) {
      return DECODE_FAIL;
    }
    pushDecodedString(state, s);
    return s;
  }
  if (tag >= 0xa0 && tag <= 0xaf) {
    return readArrayValue(reader, state, tag & 0x0f);
  }
  if (tag >= 0xb0 && tag <= 0xbf) {
    return readMapValue(reader, state, tag & 0x0f);
  }
  if (tag === TAG_NULL) {
    return null;
  }
  if (tag === TAG_BOOL_FALSE) {
    return false;
  }
  if (tag === TAG_BOOL_TRUE) {
    return true;
  }
  if (tag === TAG_I8) {
    const v = reader.readByte();
    return v === null ? DECODE_FAIL : tinyBigInt((v << 24) >> 24);
  }
  if (tag === TAG_I16) {
    const v = reader.readI16();
    return v === null ? DECODE_FAIL : BigInt(v);
  }
  if (tag === TAG_I32) {
    const v = reader.readI32();
    return v === null ? DECODE_FAIL : BigInt(v);
  }
  if (tag === TAG_I64) {
    const v = reader.readI64();
    return v === null ? DECODE_FAIL : v;
  }
  if (tag === TAG_U8) {
    const v = reader.readByte();
    return v === null ? DECODE_FAIL : tinyBigInt(v);
  }
  if (tag === TAG_U16) {
    const v = reader.readU16();
    return v === null ? DECODE_FAIL : BigInt(v);
  }
  if (tag === TAG_U32) {
    const v = reader.readU32();
    return v === null ? DECODE_FAIL : BigInt(v);
  }
  if (tag === TAG_U64) {
    const v = reader.readU64();
    return v === null ? DECODE_FAIL : v;
  }
  if (tag === TAG_F64) {
    const value = reader.readF64();
    return value === null ? DECODE_FAIL : value;
  }
  if (tag === TAG_STR8 || tag === TAG_STR16 || tag === TAG_STR32) {
    const len =
      tag === TAG_STR8
        ? reader.readByte()
        : tag === TAG_STR16
          ? reader.readU16()
          : reader.readU32();
    if (len === null) {
      return DECODE_FAIL;
    }
    const value = reader.readStringOfLength(len);
    if (value === null) {
      return DECODE_FAIL;
    }
    pushDecodedString(state, value);
    return value;
  }
  if (tag === TAG_STR_REF) {
    const id = reader.readVaruint();
    if (id === null || id >= state.strings.length) {
      return DECODE_FAIL;
    }
    return state.strings[id];
  }
  if (tag === TAG_BIN8 || tag === TAG_BIN16 || tag === TAG_BIN32) {
    const len =
      tag === TAG_BIN8
        ? reader.readByte()
        : tag === TAG_BIN16
          ? reader.readU16()
          : reader.readU32();
    if (len === null) {
      return DECODE_FAIL;
    }
    const value = reader.readBinaryOfLength(len);
    return value === null ? DECODE_FAIL : value;
  }
  if (tag === TAG_ARRAY16 || tag === TAG_ARRAY32) {
    const len = tag === TAG_ARRAY16 ? reader.readU16() : reader.readU32();
    if (len === null) {
      return DECODE_FAIL;
    }
    return readArrayValue(reader, state, len);
  }
  if (tag === TAG_MAP16 || tag === TAG_MAP32) {
    const len = tag === TAG_MAP16 ? reader.readU16() : reader.readU32();
    if (len === null) {
      return DECODE_FAIL;
    }
    return readMapValue(reader, state, len);
  }
  return DECODE_FAIL;
}

function tinyBigInt(value: number): bigint {
  if (value >= -BIGINT_TINY_OFFSET && value <= BIGINT_TINY_MAX) {
    return BIGINT_TINY[value + BIGINT_TINY_OFFSET];
  }
  return BigInt(value);
}

function decodeShortAscii(
  bytes: Uint8Array,
  start: number,
  length: number
): string | null {
  for (let i = 0; i < length; i += 1) {
    if (bytes[start + i] >= 0x80) {
      return null;
    }
  }

  switch (length) {
    case 0:
      return "";
    case 1:
      return String.fromCharCode(bytes[start]);
    case 2:
      return String.fromCharCode(bytes[start], bytes[start + 1]);
    case 3:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2]
      );
    case 4:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3]
      );
    case 5:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4]
      );
    case 6:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5]
      );
    case 7:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6]
      );
    case 8:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7]
      );
    case 9:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8]
      );
    case 10:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8],
        bytes[start + 9]
      );
    case 11:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8],
        bytes[start + 9],
        bytes[start + 10]
      );
    case 12:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8],
        bytes[start + 9],
        bytes[start + 10],
        bytes[start + 11]
      );
    case 13:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8],
        bytes[start + 9],
        bytes[start + 10],
        bytes[start + 11],
        bytes[start + 12]
      );
    case 14:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8],
        bytes[start + 9],
        bytes[start + 10],
        bytes[start + 11],
        bytes[start + 12],
        bytes[start + 13]
      );
    case 15:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8],
        bytes[start + 9],
        bytes[start + 10],
        bytes[start + 11],
        bytes[start + 12],
        bytes[start + 13],
        bytes[start + 14]
      );
    case 16:
      return String.fromCharCode(
        bytes[start],
        bytes[start + 1],
        bytes[start + 2],
        bytes[start + 3],
        bytes[start + 4],
        bytes[start + 5],
        bytes[start + 6],
        bytes[start + 7],
        bytes[start + 8],
        bytes[start + 9],
        bytes[start + 10],
        bytes[start + 11],
        bytes[start + 12],
        bytes[start + 13],
        bytes[start + 14],
        bytes[start + 15]
      );
    default: {
      let result = "";
      for (let i = 0; i < length; i += 1) {
        result += String.fromCharCode(bytes[start + i]);
      }
      return result;
    }
  }
}

function isPlainMap(
  value: TwilicValue
): value is { [key: string]: TwilicValue } {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  if (value instanceof Uint8Array || Array.isArray(value)) {
    return false;
  }

  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function getCachedUtf8(
  cache: Map<string, Uint8Array>,
  value: string
): Uint8Array {
  const cached = cache.get(value);
  if (cached !== undefined) {
    return cached;
  }
  return encodeAndStoreUtf8(cache, value);
}

function encodeAndStoreUtf8(
  cache: Map<string, Uint8Array>,
  value: string
): Uint8Array {
  const encoded = textEncoder.encode(value);
  if (cache.size >= ENCODE_CACHE_LIMIT) {
    cache.clear();
  }
  cache.set(value, encoded);
  return encoded;
}

function writeU64(value: bigint, writer: ByteWriter): void {
  if (value <= 0x7fn) {
    writer.pushByte(Number(value));
  } else if (value <= 0xffn) {
    writer.pushByte(TAG_U8);
    writer.pushByte(Number(value));
  } else if (value <= 0xffffn) {
    writer.pushByte(TAG_U16);
    writer.pushU16(Number(value));
  } else if (value <= 0xffff_ffffn) {
    writer.pushByte(TAG_U32);
    writer.pushU32(Number(value));
  } else {
    writer.pushByte(TAG_U64);
    writer.pushU64(value);
  }
}

function writeI64(value: bigint, writer: ByteWriter): void {
  if (value >= -32n && value <= -1n) {
    writer.pushByte(Number(0x100n + value));
  } else if (value >= 0n && value <= 127n) {
    writer.pushByte(Number(value));
  } else if (value >= -128n && value <= 127n) {
    writer.pushByte(TAG_I8);
    writer.pushByte(Number((value + 256n) & 0xffn));
  } else if (value >= -32768n && value <= 32767n) {
    writer.pushByte(TAG_I16);
    writer.pushU16(Number((value + 0x1_0000n) & 0xffffn));
  } else if (value >= -2147483648n && value <= 2147483647n) {
    writer.pushByte(TAG_I32);
    writer.pushU32(Number((value + 0x1_0000_0000n) & 0xffff_ffffn));
  } else {
    writer.pushByte(TAG_I64);
    writer.pushU64(BigInt.asUintN(64, value));
  }
}

function writeStringLiteral(value: string, writer: ByteWriter): void {
  const encoded = getCachedUtf8(stringUtf8Cache, value);
  if (encoded.byteLength <= 31) {
    writer.pushByte(0x80 | encoded.byteLength);
  } else if (encoded.byteLength <= 0xff) {
    writer.pushByte(TAG_STR8);
    writer.pushByte(encoded.byteLength);
  } else if (encoded.byteLength <= 0xffff) {
    writer.pushByte(TAG_STR16);
    writer.pushU16(encoded.byteLength);
  } else {
    writer.pushByte(TAG_STR32);
    writer.pushU32(encoded.byteLength);
  }
  writer.pushBytes(encoded);
}

function writeBinary(value: Uint8Array, writer: ByteWriter): void {
  if (value.byteLength <= 0xff) {
    writer.pushByte(TAG_BIN8);
    writer.pushByte(value.byteLength);
  } else if (value.byteLength <= 0xffff) {
    writer.pushByte(TAG_BIN16);
    writer.pushU16(value.byteLength);
  } else {
    writer.pushByte(TAG_BIN32);
    writer.pushU32(value.byteLength);
  }
  writer.pushBytes(value);
}

function writeArrayHeader(length: number, writer: ByteWriter): void {
  if (length <= 15) {
    writer.pushByte(0xa0 | length);
  } else if (length <= 0xffff) {
    writer.pushByte(TAG_ARRAY16);
    writer.pushU16(length);
  } else {
    writer.pushByte(TAG_ARRAY32);
    writer.pushU32(length);
  }
}

function writeMapHeader(length: number, writer: ByteWriter): void {
  if (length <= 15) {
    writer.pushByte(0xb0 | length);
  } else if (length <= 0xffff) {
    writer.pushByte(TAG_MAP16);
    writer.pushU16(length);
  } else {
    writer.pushByte(TAG_MAP32);
    writer.pushU32(length);
  }
}

function writeKey(key: string, writer: ByteWriter, state: EncodeState): void {
  const id = state.keyIds.get(key);
  if (id !== undefined) {
    writer.pushByte(TAG_KEY_REF);
    writer.writeVaruint(id);
    return;
  }
  const encoded = getCachedUtf8(mapKeyUtf8Cache, key);
  if (encoded.byteLength <= 31) {
    writer.pushByte(0x80 | encoded.byteLength);
  } else {
    writer.pushByte(TAG_STR8);
    writer.pushByte(encoded.byteLength);
  }
  writer.pushBytes(encoded);
  state.keyIds.set(key, state.nextKeyId++);
}

function readKey(
  reader: ByteReader,
  state: DecodeState
): string | typeof DECODE_FAIL {
  const tag = reader.readByte();
  if (tag === null) {
    return DECODE_FAIL;
  }
  if (tag === TAG_KEY_REF) {
    const id = reader.readVaruint();
    if (id === null || id >= state.keys.length) {
      return DECODE_FAIL;
    }
    return state.keys[id];
  }
  if (tag >= 0x80 && tag <= 0x9f) {
    const value = reader.readStringOfLength(tag & 0x1f);
    if (value === null) {
      return DECODE_FAIL;
    }
    state.keys.push(value);
    return value;
  }
  if (tag === TAG_STR8 || tag === TAG_STR16 || tag === TAG_STR32) {
    const len =
      tag === TAG_STR8
        ? reader.readByte()
        : tag === TAG_STR16
          ? reader.readU16()
          : reader.readU32();
    if (len === null) {
      return DECODE_FAIL;
    }
    const value = reader.readStringOfLength(len);
    if (value === null) {
      return DECODE_FAIL;
    }
    state.keys.push(value);
    return value;
  }
  return DECODE_FAIL;
}

function pushDecodedString(state: DecodeState, value: string): void {
  state.strings.push(value);
}

function detectShape(values: TwilicValue[]): string[] | null {
  if (values.length < 2) {
    return null;
  }
  if (!isPlainMap(values[0])) {
    return null;
  }
  const keys = Object.keys(values[0]);
  if (keys.length === 0) {
    return null;
  }
  for (let i = 1; i < values.length; i += 1) {
    const item = values[i];
    if (!isPlainMap(item)) {
      return null;
    }
    const itemKeys = Object.keys(item);
    if (itemKeys.length !== keys.length) {
      return null;
    }
    for (let j = 0; j < keys.length; j += 1) {
      if (itemKeys[j] !== keys[j]) {
        return null;
      }
    }
  }
  return keys;
}
