package io.twilic.internal.core;

public final class BaseRef {
  public boolean previous;
  public long baseId;

  public static BaseRef previous() {
    BaseRef out = new BaseRef();
    out.previous = true;
    return out;
  }

  public static BaseRef id(long id) {
    BaseRef out = new BaseRef();
    out.baseId = id;
    return out;
  }
}
