import assert from "node:assert/strict";
import test from "node:test";

import {
  createSessionEncoder as createAdvancedSessionEncoder,
  encodeBatch,
  encodeBatchWithSchema,
  encodeBoundStream,
  encodeWithSchema,
} from "../dist/advanced.js";
import { encodeFast, tryDecodeFast } from "../dist/fast-codec.js";
import {
  DEFAULT_MAX_DECODE_DEPTH,
  TwilicDecodeError,
  createSessionEncoder,
  decode,
  encode,
  init,
} from "../dist/index.js";
import { fromTransportValue } from "../dist/transport.js";

test("rejects wasm backend in node", async () => {
  await assert.rejects(
    async () => init({ prefer: "wasm" }),
    /WASM backend is intended for browser JS/
  );
});

test("encodes and decodes with bigint and binary", async () => {
  const payload = {
    id: 123n,
    name: "alice",
    active: true,
    blob: new Uint8Array([1, 2, 3, 4]),
    scores: [1n, 2n, 3n],
  };

  const bytes = encode(payload);
  assert.ok(bytes.length > 0);

  const decoded = decode(bytes);
  assert.equal(decoded.id, 123n);
  assert.equal(decoded.name, "alice");
  assert.equal(decoded.active, true);
  assert.ok(decoded.blob instanceof Uint8Array);
  assert.deepEqual(Array.from(decoded.blob), [1, 2, 3, 4]);
  assert.deepEqual(decoded.scores, [1n, 2n, 3n]);
});

test("decodes from Buffer input", async () => {
  const bytes = encode({ id: 42n, name: "buffer" });
  const decoded = decode(Buffer.from(bytes));
  assert.equal(decoded.id, 42n);
  assert.equal(decoded.name, "buffer");
});

test("decodes u64 values above i64 range", async () => {
  const id = 9_223_372_036_854_775_808n;
  const decoded = decode(encode({ id }));
  assert.equal(decoded.id, id);
});

test("fast codec round-trips single-small benchmark payload", async () => {
  const payload = {
    id: 1234,
    userId: 987654,
    name: "alice",
    active: true,
    score: 98.5,
    tags: ["edge", "premium", "ap-northeast-1"],
    profile: {
      country: "JP",
      locale: "ja-JP",
      timeZone: "Asia/Tokyo",
    },
  };

  const bytes = encodeFast(payload);
  const decoded = tryDecodeFast(bytes);
  assert.notEqual(decoded, undefined);
  assert.deepEqual(decoded, {
    id: 1234n,
    userId: 987654n,
    name: "alice",
    active: true,
    score: 98.5,
    tags: ["edge", "premium", "ap-northeast-1"],
    profile: {
      country: "JP",
      locale: "ja-JP",
      timeZone: "Asia/Tokyo",
    },
  });
});

test("fast codec round-trips representative batch-homogeneous row", async () => {
  const payload = {
    id: 42,
    userId: 100042,
    active: true,
    tier: "standard",
    country: "JP",
    usage: {
      requests: 5042,
      errors: 8,
    },
  };

  const bytes = encodeFast(payload);
  const decoded = tryDecodeFast(bytes);
  assert.notEqual(decoded, undefined);
  assert.deepEqual(decoded, {
    id: 42n,
    userId: 100042n,
    active: true,
    tier: "standard",
    country: "JP",
    usage: {
      requests: 5042n,
      errors: 8n,
    },
  });
});

test("rejects unsupported root values on the native fast path", async () => {
  assert.throws(() => encode(new Date()), /unsupported value type/);
  assert.throws(
    () => encode(Number.MAX_SAFE_INTEGER + 1),
    /unsafe integer number detected/
  );
});

test("supports schema and batch APIs through the advanced entrypoint", async () => {
  const schema = {
    schemaId: 1,
    name: "User",
    fields: [
      {
        number: 1,
        name: "id",
        logicalType: "u64",
        required: true,
      },
      {
        number: 2,
        name: "name",
        logicalType: "string",
        required: false,
      },
    ],
  };

  const schemaBytes = encodeWithSchema(schema, { id: 1n, name: "alice" });
  assert.ok(schemaBytes.length > 0);

  const batchBytes = encodeBatch([
    { id: 1n, name: "alice" },
    { id: 2n, name: "bob" },
    { id: 3n, name: "carol" },
    { id: 4n, name: "dave" },
  ]);
  assert.ok(batchBytes.length > 0);
});

test("supports v3 schema batch and bound stream APIs", async () => {
  const schema = {
    schemaId: 7,
    name: "User",
    fields: [
      { number: 1, name: "id", logicalType: "u64", required: true },
      { number: 2, name: "name", logicalType: "string", required: false },
    ],
  };
  const values = [
    { id: 1n, name: "alice" },
    { id: 2n, name: "bob" },
  ];

  const boundStream = encodeBoundStream(schema, values);
  assert.equal(boundStream[0], 0x0f);

  const schemaBatch = encodeBatchWithSchema(schema, values);
  assert.equal(schemaBatch[0], 0x0e);
});

test("supports session encoder APIs", async () => {
  const session = createSessionEncoder({
    unknownReferencePolicy: "statelessRetry",
  });

  const first = session.encode({ id: 1n, role: "admin" });
  const patch = session.encodePatch({ id: 1n, role: "member" });
  const micro = session.encodeMicroBatch([
    { id: 1n, role: "admin" },
    { id: 2n, role: "member" },
    { id: 3n, role: "member" },
    { id: 4n, role: "admin" },
  ]);

  assert.ok(first.length > 0);
  assert.ok(patch.length > 0);
  assert.ok(micro.length > 0);

  session.reset();
  const afterReset = session.encode({ id: 9n, role: "owner" });
  assert.ok(afterReset.length > 0);
});

test("supports advanced session encoder APIs", async () => {
  const session = createAdvancedSessionEncoder();

  const first = session.encode({ id: 1n, role: "admin" });
  const patch = session.encodePatchTransportJson(
    '{"t":"map","v":[["id",{"t":"u64","v":"1"}],["role",{"t":"string","v":"member"}]]}'
  );

  assert.ok(first.length > 0);
  assert.ok(patch.length > 0);
});

test("supports v3 session encoder APIs", async () => {
  const session = createSessionEncoder();
  const schema = {
    schemaId: 8,
    name: "User",
    fields: [
      { number: 1, name: "id", logicalType: "u64", required: true },
      { number: 2, name: "name", logicalType: "string", required: false },
    ],
  };
  const values = [
    { id: 1n, name: "alice" },
    { id: 2n, name: "bob" },
  ];

  const boundStream = session.encodeBoundStream(schema, values);
  assert.equal(boundStream[0], 0x0f);

  const schemaBatch = session.encodeBatchWithSchema(schema, values);
  assert.equal(schemaBatch[0], 0x0e);
});

function buildDeepNestedV2Array(depth) {
  const bytes = new Uint8Array(depth + 1);
  bytes.fill(0xa1, 0, depth);
  bytes[depth] = 0xc0;
  return bytes;
}

function appendVaruint(bytes, n) {
  let value = BigInt(n);
  while (value >= 0x80n) {
    bytes.push(Number((value & 0x7fn) | 0x80n));
    value >>= 7n;
  }
  bytes.push(Number(value));
}

function buildHostileShapeKeyCountPayload(keyCount) {
  const bytes = [];
  bytes.push(0xd3, 0, 0, 0, 1);
  bytes.push(0xd6);
  appendVaruint(bytes, 0);
  appendVaruint(bytes, keyCount);
  return new Uint8Array(bytes);
}

test("rejects hostile v2 shape key_count in native decode", async () => {
  const payload = buildHostileShapeKeyCountPayload(10_000_000);
  assert.throws(
    () => decode(payload),
    (error) =>
      error instanceof TwilicDecodeError &&
      error.code === "DECODE_LIMIT_EXCEEDED"
  );
});

test("rejects deeply nested v2 arrays in the fast codec", () => {
  const tooDeep = buildDeepNestedV2Array(DEFAULT_MAX_DECODE_DEPTH + 1);
  assert.throws(
    () => tryDecodeFast(tooDeep),
    (error) =>
      error instanceof TwilicDecodeError &&
      error.code === "DECODE_DEPTH_EXCEEDED"
  );
});

test("rejects deeply nested v2 arrays in decode()", async () => {
  const tooDeep = buildDeepNestedV2Array(DEFAULT_MAX_DECODE_DEPTH + 1);
  assert.throws(() => decode(tooDeep), /decode depth limit exceeded/);
});

test("allows v2 arrays nested up to the default depth limit", () => {
  const atLimit = buildDeepNestedV2Array(DEFAULT_MAX_DECODE_DEPTH);
  const decoded = tryDecodeFast(atLimit);
  assert.notEqual(decoded, undefined);
  let current = decoded;
  for (let i = 0; i < DEFAULT_MAX_DECODE_DEPTH; i += 1) {
    assert.ok(Array.isArray(current));
    assert.equal(current.length, 1);
    current = current[0];
  }
  assert.equal(current, null);
});

test("rejects prototype pollution keys when decoding maps", async () => {
  const attack = { polluted: true, isAdmin: true };
  const dangerousKeys = ["__proto__", "constructor", "prototype"];

  for (const key of dangerousKeys) {
    const payload = JSON.parse(
      `{"${key}":{"polluted":true,"isAdmin":true},"safe":"marker"}`
    );
    const decoded = decode(encode(payload));
    assert.equal(decoded.polluted, undefined);
    assert.equal(decoded.isAdmin, undefined);
    assert.equal(Object.hasOwn(decoded, key), false);
    assert.equal(decoded.safe, "marker");
    assert.notDeepEqual(Object.getPrototypeOf(decoded), attack);
  }

  const fastDecoded = tryDecodeFast(
    encodeFast(JSON.parse('{"__proto__":{"polluted":true},"safe":"ok"}'))
  );
  assert.notEqual(fastDecoded, undefined);
  assert.equal(fastDecoded.polluted, undefined);
  assert.equal(fastDecoded.safe, "ok");
  assert.equal(Object.hasOwn(fastDecoded, "__proto__"), false);
});

test("rejects prototype pollution keys in transport map conversion", async () => {
  const decoded = fromTransportValue({
    t: "map",
    v: [
      ["__proto__", { t: "map", v: [["polluted", { t: "bool", v: true }]] }],
      ["safe", { t: "string", v: "ok" }],
    ],
  });
  assert.equal(decoded.polluted, undefined);
  assert.equal(decoded.safe, "ok");
  assert.equal(Object.hasOwn(decoded, "__proto__"), false);
});
