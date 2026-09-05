package io.twilic

import io.twilic.internal.core.InteropFixtures

object EmitRustClientFixtures {
  def main(args: Array[String]): Unit =
    try System.out.write(InteropFixtures.emitInteropFixtures())
    catch {
      case err: RuntimeException =>
        System.err.println("emit fixtures: " + err.getMessage)
        sys.exit(1)
    }
}
