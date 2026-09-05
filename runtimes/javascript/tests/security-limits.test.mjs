import assert from "node:assert/strict";
import test from "node:test";

import { tryDecodeFast, encodeFast } from "../dist/fast-codec.js";
import { decode, init, TwilicDecodeError } from "../dist/index.js";

function shapedRows(count) {
  const bytes = new Uint8Array(8);
  bytes[0] = 0xd3;
  new DataView(bytes.buffer).setUint32(1, count, true);
  bytes[5] = 0xd6;
  return bytes;
}

test("native and fast decoding reject excessive shaped expansion and recover", async () => {
  await init({ prefer: "napi" });
  for (const parse of [decode, tryDecodeFast]) {
    assert.throws(
      () => parse(shapedRows(100_000)),
      (error) =>
        error instanceof TwilicDecodeError &&
        error.code === "DECODE_LIMIT_EXCEEDED"
    );
    assert.deepEqual(parse(encodeFast({ ok: true })), { ok: true });
    assert.deepEqual(parse(shapedRows(2)), [{}, {}]);
  }
});

test("fast decoding rejects excessive declared lengths before allocation", () => {
  assert.throws(
    () => tryDecodeFast(shapedRows(2 ** 32 - 1)),
    TwilicDecodeError
  );
});
