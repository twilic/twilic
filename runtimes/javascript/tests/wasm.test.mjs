import assert from "node:assert/strict";
import test from "node:test";

// Bypass the Node.js runtime guard by importing loadWasmBackend directly.
// This is intentional: the guard exists to steer Node.js users toward the
// faster N-API backend, not because WASM is broken in Node.js.
import { loadWasmBackend } from "../dist/runtime/wasm-backend.js";

/** @type {import("../dist/runtime/types.js").RuntimeBackend} */
let backend;

test("loads WASM backend", async () => {
  backend = await loadWasmBackend();
  assert.equal(backend.kind, "wasm");
});

test("encodes and decodes transport JSON", async () => {
  const input =
    '{"t":"map","v":[["id",{"t":"u64","v":"1"}],["name",{"t":"string","v":"alice"}]]}';
  const bytes = backend.encodeTransportJson(input);
  assert.ok(bytes instanceof Uint8Array && bytes.length > 0);

  const json = backend.decodeToTransportJson(bytes);
  const parsed = JSON.parse(json);
  assert.equal(parsed.t, "map");
});

test("encodes with schema", async () => {
  const schema = JSON.stringify({
    schemaId: 1,
    name: "User",
    fields: [
      { number: 1, name: "id", logicalType: "u64", required: true },
      { number: 2, name: "name", logicalType: "string", required: false },
    ],
  });
  const value =
    '{"t":"map","v":[["id",{"t":"u64","v":"1"}],["name",{"t":"string","v":"alice"}]]}';
  const bytes = backend.encodeWithSchemaTransportJson(schema, value);
  assert.ok(bytes instanceof Uint8Array && bytes.length > 0);
});

test("encodes batch transport JSON", async () => {
  const values = JSON.stringify([
    {
      t: "map",
      v: [
        ["id", { t: "u64", v: "1" }],
        ["name", { t: "string", v: "alice" }],
      ],
    },
    {
      t: "map",
      v: [
        ["id", { t: "u64", v: "2" }],
        ["name", { t: "string", v: "bob" }],
      ],
    },
  ]);
  const bytes = backend.encodeBatchTransportJson(values);
  assert.ok(bytes instanceof Uint8Array && bytes.length > 0);
});

test("encodes v3 bound stream and schema batch transport JSON", async () => {
  const schema = JSON.stringify({
    schemaId: 7,
    name: "User",
    fields: [
      { number: 1, name: "id", logicalType: "u64", required: true },
      { number: 2, name: "name", logicalType: "string", required: false },
    ],
  });
  const values = JSON.stringify([
    {
      t: "map",
      v: [
        ["id", { t: "u64", v: "1" }],
        ["name", { t: "string", v: "alice" }],
      ],
    },
    {
      t: "map",
      v: [
        ["id", { t: "u64", v: "2" }],
        ["name", { t: "string", v: "bob" }],
      ],
    },
  ]);

  const boundStream = backend.encodeBoundStreamTransportJson(schema, values);
  assert.equal(boundStream[0], 0x0f);

  const schemaBatch = backend.encodeBatchWithSchemaTransportJson(
    schema,
    values
  );
  assert.equal(schemaBatch[0], 0x0e);
});

test("session encoder encodes and patches", async () => {
  const session = backend.createSessionEncoder();
  const first = session.encodeTransportJson(
    '{"t":"map","v":[["id",{"t":"u64","v":"1"}],["role",{"t":"string","v":"admin"}]]}'
  );
  const patch = session.encodePatchTransportJson(
    '{"t":"map","v":[["id",{"t":"u64","v":"1"}],["role",{"t":"string","v":"member"}]]}'
  );
  assert.ok(first instanceof Uint8Array && first.length > 0);
  assert.ok(patch instanceof Uint8Array && patch.length > 0);

  session.reset();
  const afterReset = session.encodeTransportJson(
    '{"t":"map","v":[["id",{"t":"u64","v":"9"}],["role",{"t":"string","v":"owner"}]]}'
  );
  assert.ok(afterReset instanceof Uint8Array && afterReset.length > 0);
});

test("direct encode and decode roundtrip", async () => {
  const transport = {
    t: "map",
    v: [
      ["id", { t: "u64", v: "1" }],
      ["name", { t: "string", v: "alice" }],
    ],
  };
  const bytes = backend.encodeDirect(transport);
  assert.ok(bytes instanceof Uint8Array && bytes.length > 0);

  const decoded = backend.decodeDirect(bytes);
  assert.deepEqual(decoded, transport);
});

test("compact encode and decode roundtrip", async () => {
  const compactJson = '[8,["id",[3,"1"],"name",[5,"alice"]]]';
  const encoded = backend.encodeCompactJson(compactJson);
  assert.ok(encoded instanceof Uint8Array && encoded.length > 0);

  const decodedJson = backend.decodeToCompactJson(encoded);
  const parsed = JSON.parse(decodedJson);
  assert.equal(parsed[0], 8);
  assert.equal(parsed[1][0], "id");
});

test("session encoder compact and direct paths", async () => {
  const session = backend.createSessionEncoder();
  const transport = {
    t: "map",
    v: [
      ["id", { t: "u64", v: "42" }],
      ["role", { t: "string", v: "admin" }],
    ],
  };
  const direct = session.encodeDirect(transport);
  assert.ok(direct instanceof Uint8Array && direct.length > 0);

  const compact = session.encodeCompactJson(
    '[8,["id",[3,"42"],"role",[5,"admin"]]]'
  );
  assert.ok(compact instanceof Uint8Array && compact.length > 0);
});

test("session encoder v3 bound stream and schema batch paths", async () => {
  const session = backend.createSessionEncoder();
  const schema = JSON.stringify({
    schemaId: 8,
    name: "User",
    fields: [
      { number: 1, name: "id", logicalType: "u64", required: true },
      { number: 2, name: "name", logicalType: "string", required: false },
    ],
  });
  const values = JSON.stringify([
    {
      t: "map",
      v: [
        ["id", { t: "u64", v: "1" }],
        ["name", { t: "string", v: "alice" }],
      ],
    },
    {
      t: "map",
      v: [
        ["id", { t: "u64", v: "2" }],
        ["name", { t: "string", v: "bob" }],
      ],
    },
  ]);

  const boundStream = session.encodeBoundStreamTransportJson(schema, values);
  assert.equal(boundStream[0], 0x0f);

  const schemaBatch = session.encodeBatchWithSchemaTransportJson(
    schema,
    values
  );
  assert.equal(schemaBatch[0], 0x0e);
});

test("WASM rejects excessive depth and shaped expansion and remains usable", () => {
  const nested = new Uint8Array(71).fill(0xa1);
  nested[70] = 0xc0;
  assert.throws(() => backend.decodeToTransportJson(nested), /depth limit/);
  const shaped = new Uint8Array(8);
  shaped[0] = 0xd3;
  new DataView(shaped.buffer).setUint32(1, 100_000, true);
  shaped[5] = 0xd6;
  assert.throws(() => backend.decodeToTransportJson(shaped), /output ratio/);
  assert.equal(
    JSON.parse(backend.decodeToTransportJson(new Uint8Array([0xc0]))).t,
    "null"
  );
});
