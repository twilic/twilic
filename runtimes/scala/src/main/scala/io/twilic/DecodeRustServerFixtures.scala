package io.twilic

import io.twilic.internal.core.InteropFixtures

object DecodeRustServerFixtures {
  def main(args: Array[String]): Unit =
    try {
      val input =
        if (args.length > 0) java.nio.file.Files.newInputStream(java.nio.file.Path.of(args(0)))
        else System.in
      try InteropFixtures.decodeRustServerInput(input)
      finally if (args.length > 0) input.close()
    } catch {
      case err @ (_: java.io.IOException | _: RuntimeException) =>
        System.err.println("decode fixtures: " + err.getMessage)
        sys.exit(1)
    }
}
