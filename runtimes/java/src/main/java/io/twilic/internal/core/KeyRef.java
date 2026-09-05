package io.twilic.internal.core;

public final class KeyRef {
  public String literal;
  public long id;
  public boolean isId;

  public static KeyRef literal(String value) {
    KeyRef out = new KeyRef();
    out.literal = value;
    out.isId = false;
    return out;
  }

  public static KeyRef id(long keyId) {
    KeyRef out = new KeyRef();
    out.id = keyId;
    out.isId = true;
    return out;
  }
}
