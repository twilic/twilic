package io.twilic.internal.core;

import java.util.List;

public final class Session {
  private Session() {}

  public static SessionOptions DefaultSessionOptions() {
    return new SessionOptions();
  }

  public static String shapeKey(List<String> keys) {
    return String.join("\0", keys);
  }
}
