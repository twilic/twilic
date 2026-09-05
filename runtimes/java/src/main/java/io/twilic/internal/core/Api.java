package io.twilic.internal.core;

import java.util.List;

public final class Api {
  private Api() {}

  // Encode encodes a dynamic value using the v2 wire profile.
  public static byte[] Encode(Value value) {
    return new TwilicCodec().encodeValue(value);
  }

  // Decode decodes a dynamic value using the v2 wire profile.
  public static Value Decode(byte[] bytes) {
    return new TwilicCodec().decodeValue(bytes);
  }

  // EncodeWithSchema encodes a value with the given schema using a fresh session encoder.
  public static byte[] EncodeWithSchema(Schema schema, Value value) {
    SessionEncoder enc = new SessionEncoder(new SessionOptions());
    return enc.encodeWithSchema(schema, value);
  }

  // EncodeBatch encodes multiple values as a batch using a fresh session encoder.
  public static byte[] EncodeBatch(List<Value> values) {
    SessionEncoder enc = new SessionEncoder(new SessionOptions());
    return enc.encodeBatch(values);
  }
}
