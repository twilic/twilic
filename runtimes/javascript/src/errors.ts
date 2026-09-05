export const DEFAULT_MAX_DECODE_DEPTH = 64;

export class TwilicDecodeError extends Error {
  readonly name = "TwilicDecodeError";
  readonly code: "DECODE_DEPTH_EXCEEDED" | "DECODE_LIMIT_EXCEEDED";

  constructor(
    message: string,
    code:
      | "DECODE_DEPTH_EXCEEDED"
      | "DECODE_LIMIT_EXCEEDED" = "DECODE_DEPTH_EXCEEDED"
  ) {
    super(message);
    this.code = code;
  }
}

export function decodeDepthLimitMessage(maxDepth: number): string {
  return `twilic: decode depth limit exceeded (max ${maxDepth})`;
}

export function rethrowDecodeError(error: unknown): never {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes("decode depth limit exceeded")) {
    throw new TwilicDecodeError(message);
  }
  if (
    message.includes("decode count limit exceeded") ||
    message.includes("decode output ratio exceeded") ||
    message.includes("exceeds limit")
  ) {
    throw new TwilicDecodeError(message, "DECODE_LIMIT_EXCEEDED");
  }
  throw error;
}
