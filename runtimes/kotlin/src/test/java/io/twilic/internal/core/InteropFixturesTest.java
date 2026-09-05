package io.twilic.internal.core;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

final class InteropFixturesTest {
  @Test
  void codecEncodeDecodeRoundtrip() {
    List<InteropFixtures.InteropFrame> frames =
        InteropFixtures.parseInteropFrames(
            new String(InteropFixtures.emitInteropFixtures(), StandardCharsets.UTF_8));

    TwilicCodec codec = new TwilicCodec();
    for (InteropFixtures.InteropFrame frame : frames) {
      if (!"codec".equals(frame.stream())) {
        continue;
      }
      InteropFixtures.assertInteropCodecDecode(codec, frame.label(), frame.bytes());

      if (expectsCodecValue(frame.label())) {
        TwilicCodec iso = replayCodecState(frames, frame.label());
        Value got = iso.decodeValue(frame.bytes());
        byte[] reencoded = iso.encodeValue(got);
        Value roundtrip = iso.decodeValue(reencoded);
        Assertions.assertTrue(
            ProtocolHelpers.equal(roundtrip, got), frame.label() + ": roundtrip value mismatch");
      }
    }
  }

  @Test
  void sessionEncodeDecodeRoundtrip() {
    List<InteropFixtures.InteropFrame> frames =
        InteropFixtures.parseInteropFrames(
            new String(InteropFixtures.emitInteropFixtures(), StandardCharsets.UTF_8));

    TwilicCodec codec = new TwilicCodec();
    for (InteropFixtures.InteropFrame frame : frames) {
      if (!"session".equals(frame.stream())) {
        continue;
      }
      InteropFixtures.assertInteropSessionDecode(codec, frame.label(), frame.bytes());
    }
  }

  @Test
  void decodeRustServerFrames() throws IOException, InterruptedException {
    Path root = interopModuleRoot();
    interopRequireTwilicRust(root);
    Path rustManifest = root.resolve("scripts/rust-server-fixtures/Cargo.toml").normalize();
    Assumptions.assumeTrue(Files.exists(rustManifest), "rust fixtures not available");

    byte[] rustOut =
        runProcess(
            root, null, "cargo", "run", "--quiet", "--manifest-path", rustManifest.toString());
    List<InteropFixtures.InteropFrame> frames =
        InteropFixtures.parseInteropFrames(new String(rustOut, StandardCharsets.UTF_8));

    TwilicCodec codecStream = new TwilicCodec();
    TwilicCodec sessionStream = new TwilicCodec();
    for (InteropFixtures.InteropFrame frame : frames) {
      if ("codec".equals(frame.stream())) {
        InteropFixtures.assertInteropCodecDecode(codecStream, frame.label(), frame.bytes());
      } else if ("session".equals(frame.stream())) {
        InteropFixtures.assertInteropSessionDecode(sessionStream, frame.label(), frame.bytes());
      } else {
        Assertions.fail("unknown stream " + frame.stream());
      }
    }
  }

  @Test
  void rustDecodesJavaFramesWithSameValues() throws IOException, InterruptedException {
    Path root = interopModuleRoot();
    interopRequireTwilicRust(root);
    Path rustCheck = root.resolve("scripts/rust-client-check/Cargo.toml").normalize();
    Assumptions.assumeTrue(Files.exists(rustCheck), "rust client check not available");

    byte[] javaFixtures = InteropFixtures.emitInteropFixtures();
    byte[] out =
        runProcess(
            root, javaFixtures, "cargo", "run", "--quiet", "--manifest-path", rustCheck.toString());
    String text = new String(out, StandardCharsets.UTF_8);
    Assertions.assertTrue(
        text.contains("value checks passed for"), "unexpected rust output: " + text.trim());
  }

  private TwilicCodec replayCodecState(
      List<InteropFixtures.InteropFrame> frames, String stopLabel) {
    TwilicCodec iso = new TwilicCodec();
    for (InteropFixtures.InteropFrame frame : frames) {
      if (!"codec".equals(frame.stream())) {
        continue;
      }
      if (frame.label().equals(stopLabel)) {
        break;
      }
      if ("base_snapshot".equals(frame.label())) {
        iso.decodeMessage(frame.bytes());
        continue;
      }
      if (expectsCodecValue(frame.label())) {
        iso.decodeValue(frame.bytes());
      }
    }
    return iso;
  }

  private boolean expectsCodecValue(String label) {
    return "scalar_string".equals(label)
        || label.startsWith("map_two_fields_")
        || label.startsWith("map_three_fields_")
        || label.startsWith("bulk_map_");
  }

  private Path interopModuleRoot() {
    return Path.of("").toAbsolutePath().normalize();
  }

  private void interopRequireTwilicRust(Path moduleRoot) {
    boolean hasCargo = hasCommand("cargo");
    Assumptions.assumeTrue(hasCargo, "cargo not found in PATH");
    Path envRoot = null;
    String env = System.getenv("TWILIC_RUST_ROOT");
    if (env != null && !env.isBlank()) {
      envRoot = Path.of(env);
    }
    Path sibling = moduleRoot.resolve("../rust").normalize();
    boolean found =
        (envRoot != null && Files.exists(envRoot.resolve("Cargo.toml")))
            || Files.exists(sibling.resolve("Cargo.toml"));
    Assumptions.assumeTrue(found, "Rust runtime not found");
  }

  private boolean hasCommand(String command) {
    try {
      runProcess(Path.of("").toAbsolutePath(), null, "which", command);
      return true;
    } catch (Throwable ignored) {
      return false;
    }
  }

  private byte[] runProcess(Path dir, byte[] stdin, String... command)
      throws IOException, InterruptedException {
    ProcessBuilder pb = new ProcessBuilder(command);
    pb.directory(dir.toFile());
    pb.redirectErrorStream(true);
    Process process = pb.start();
    if (stdin != null) {
      process.getOutputStream().write(stdin);
    }
    process.getOutputStream().close();
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    process.getInputStream().transferTo(out);
    int code = process.waitFor();
    if (code != 0) {
      throw new IOException(
          "command failed (" + code + "): " + String.join(" ", command) + "\n" + out);
    }
    return out.toByteArray();
  }
}
