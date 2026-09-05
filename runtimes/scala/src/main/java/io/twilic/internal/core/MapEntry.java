package io.twilic.internal.core;

public final class MapEntry {
  public String key;
  public Value value;

  public MapEntry() {}

  public MapEntry(String key, Value value) {
    this.key = key;
    this.value = value;
  }
}
