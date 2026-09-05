import type { TwilicValue } from "./types.js";

export function isSafeMapKey(key: string): boolean {
  const length = key.length;
  if (length === 9) {
    return key !== "__proto__" && key !== "prototype";
  }
  if (length === 11) {
    return key !== "constructor";
  }
  return true;
}

export function createDecodedMap(): Record<string, TwilicValue> {
  return {};
}

export function setDecodedMapEntry(
  out: Record<string, TwilicValue>,
  key: string,
  value: TwilicValue
): void {
  if (isSafeMapKey(key)) {
    out[key] = value;
  }
}
