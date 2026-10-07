import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

import * as advanced from "../dist/advanced.js";
import * as core from "../dist/index.js";

for (const [name, api] of [
  ["core", core],
  ["advanced", advanced],
]) {
  test(`${name} Dynamic decoder roundtrips fixints and compound values`, () => {
    for (const value of [
      0n,
      1n,
      2n,
      -1n,
      3n,
      true,
      false,
      null,
      [0n, 1n, 2n],
      { zero: 0n, one: 1n, two: 2n },
    ]) {
      assert.deepEqual(api.decode(api.encode(value)), value);
    }
  });

  test(`${name} Dynamic decoder rejects compact messages and trailing bytes`, () => {
    for (const bytes of [[], [0, 0], [2, 1, 0, 1, 0x6b, 4, 1, 0x2a], [1, 0]]) {
      assert.throws(() => api.decode(Uint8Array.from(bytes)));
    }
  });
}

test("raw native compact encoder/decoder remains paired", () => {
  const require = createRequire(import.meta.url);
  const native = require(
    `../native/twilic_napi-${process.platform}-${process.arch}.node`
  );
  for (const value of [0n, 1n, 2n, { k: 42n }]) {
    assert.deepEqual(native.decodeNative(native.encodeNative(value)), value);
  }
});
