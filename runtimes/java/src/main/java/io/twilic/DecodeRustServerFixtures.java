package io.twilic;

import io.twilic.internal.core.InteropFixtures;
import java.io.IOException;

public final class DecodeRustServerFixtures {
  private DecodeRustServerFixtures() {}

  public static void main(String[] args) {
    try {
      InteropFixtures.decodeRustServerInput(System.in);
    } catch (IOException | RuntimeException err) {
      System.err.println("decode fixtures: " + err.getMessage());
      System.exit(1);
    }
  }
}
