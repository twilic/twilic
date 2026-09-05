package io.twilic.internal.core;

public enum MessageKind {
  SCALAR,
  ARRAY,
  MAP,
  SHAPED_OBJECT,
  SCHEMA_OBJECT,
  TYPED_VECTOR,
  ROW_BATCH,
  COLUMN_BATCH,
  CONTROL,
  EXT,
  STATE_PATCH,
  TEMPLATE_BATCH,
  CONTROL_STREAM,
  BASE_SNAPSHOT;

  static MessageKind fromByte(int b) {
    int idx = b & 0xFF;
    if (idx < 0 || idx >= values().length) {
      throw Errors.invalidData("invalid message kind");
    }
    return values()[idx];
  }
}
