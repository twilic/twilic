package io.twilic;

import io.twilic.internal.core.InteropFixtures;
import java.io.IOException;

public final class EmitRustClientFixtures {
  private EmitRustClientFixtures() {}

  public static void main(String[] args) throws IOException {
    try {
      System.out.write(InteropFixtures.emitInteropFixtures());
    } catch (RuntimeException err) {
      System.err.println("emit fixtures: " + err.getMessage());
      System.exit(1);
    }
  }
}
