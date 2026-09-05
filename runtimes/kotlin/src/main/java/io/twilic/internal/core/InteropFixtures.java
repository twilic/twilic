package io.twilic.internal.core;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public final class InteropFixtures {
  private InteropFixtures() {}

  record InteropFrame(String stream, String label, String hex, byte[] bytes) {}

  static Value interopIdNameMap(long id, String name) {
    return Value.ofMap(
        List.of(new MapEntry("id", Value.ofU64(id)), new MapEntry("name", Value.ofString(name))));
  }

  static Value interopIdNameRoleMap(long id, String name, String role) {
    return Value.ofMap(
        List.of(
            new MapEntry("id", Value.ofU64(id)),
            new MapEntry("name", Value.ofString(name)),
            new MapEntry("role", Value.ofString(role))));
  }

  static List<Value> interopMakeI64Array(int length, long start) {
    List<Value> out = new ArrayList<>(length);
    for (int i = 0; i < length; i++) {
      out.add(Value.ofI64(start + i));
    }
    return out;
  }

  static List<Value> interopMakeUserRows(List<String> names) {
    List<Value> rows = new ArrayList<>(names.size());
    for (int i = 0; i < names.size(); i++) {
      rows.add(
          Value.ofMap(
              List.of(
                  new MapEntry("id", Value.ofU64(i + 1L)),
                  new MapEntry("name", Value.ofString(names.get(i))))));
    }
    return rows;
  }

  public static byte[] emitInteropFixtures() {
    StringBuilder out = new StringBuilder();
    TwilicCodec codec = new TwilicCodec();

    Value alpha = Value.ofString("alpha");
    emitInteropValue(out, "codec", "scalar_string", codec, alpha);

    Value mapTwo = interopIdNameMap(1, "alice");
    emitInteropValue(out, "codec", "map_two_fields_first", codec, mapTwo);
    resetEncodeShapeObservation(codec, List.of("id", "name"));
    emitInteropValue(out, "codec", "map_two_fields_second", codec, mapTwo);

    Value mapThree = interopIdNameRoleMap(1, "alice", "admin");
    emitInteropValue(out, "codec", "map_three_fields_first", codec, mapThree);
    resetEncodeShapeObservation(codec, List.of("id", "name", "role"));
    emitInteropValue(out, "codec", "map_three_fields_second", codec, mapThree);

    for (int i = 0; i < 8; i++) {
      Value dynamic = interopIdNameMap(10L + i, "user-" + i);
      emitInteropValue(out, "codec", "bulk_map_" + i, codec, dynamic);
    }

    Message baseSnapshot = new Message();
    baseSnapshot.kind = MessageKind.BASE_SNAPSHOT;
    baseSnapshot.baseSnapshot = new BaseSnapshotMessage();
    baseSnapshot.baseSnapshot.baseId = 77;
    baseSnapshot.baseSnapshot.schemaOrShapeRef = 0;
    baseSnapshot.baseSnapshot.payload = new Message();
    baseSnapshot.baseSnapshot.payload.kind = MessageKind.SCALAR;
    baseSnapshot.baseSnapshot.payload.scalar = Value.ofI64(42);
    emitInteropMessage(out, "codec", "base_snapshot", codec, baseSnapshot);

    SessionEncoder enc = new SessionEncoder();
    Value baseArray = Value.ofArray(interopMakeI64Array(100, 0));
    emitInteropFrame(out, "session", "session_base_array", enc.encode(baseArray));

    List<Value> oneChangeArr = interopMakeI64Array(100, 0);
    oneChangeArr.set(0, Value.ofI64(10_000));
    emitInteropFrame(
        out, "session", "session_patch_one_change", enc.encodePatch(Value.ofArray(oneChangeArr)));

    for (int step = 0; step < 4; step++) {
      List<Value> iterArr = interopMakeI64Array(100, 0);
      iterArr.set(step, Value.ofI64(20_000 + step));
      emitInteropFrame(
          out, "session", "session_patch_iter_" + step, enc.encodePatch(Value.ofArray(iterArr)));
    }

    List<Value> manyArr = interopMakeI64Array(100, 0);
    for (int i = 0; i < 12; i++) {
      manyArr.set(i, Value.ofI64(10_000 + i));
    }
    emitInteropFrame(
        out, "session", "session_patch_many_changes", enc.encodePatch(Value.ofArray(manyArr)));

    emitInteropFrame(
        out,
        "session",
        "session_micro_batch_first",
        enc.encodeMicroBatch(interopMakeUserRows(List.of("a", "b", "c", "d"))));
    emitInteropFrame(
        out,
        "session",
        "session_micro_batch_second",
        enc.encodeMicroBatch(interopMakeUserRows(List.of("aa", "bb", "cc", "dd"))));

    return out.toString().getBytes(StandardCharsets.UTF_8);
  }

  static List<InteropFrame> parseInteropFrames(String input) {
    List<InteropFrame> frames = new ArrayList<>();
    String[] lines = input.split("\n");
    for (int i = 0; i < lines.length; i++) {
      String line = lines[i].trim();
      if (line.isEmpty()) {
        continue;
      }
      String[] parts = line.split("\\|", 3);
      if (parts.length != 3) {
        throw new IllegalArgumentException("line " + (i + 1) + ": invalid frame");
      }
      byte[] bytes = decodeInteropHex(parts[2]);
      frames.add(new InteropFrame(parts[0], parts[1], parts[2], bytes));
    }
    if (frames.isEmpty()) {
      throw new IllegalArgumentException("no fixture frames found");
    }
    return frames;
  }

  public static void decodeRustServerInput(InputStream input) throws IOException {
    String text = new String(input.readAllBytes(), StandardCharsets.UTF_8);
    decodeRustServerFrames(text);
  }

  static void decodeRustServerFrames(String input) {
    List<InteropFrame> frames = parseInteropFrames(input);
    TwilicCodec codecStream = new TwilicCodec();
    TwilicCodec sessionStream = new TwilicCodec();
    int decoded = 0;
    for (InteropFrame frame : frames) {
      if ("codec".equals(frame.stream())) {
        assertInteropCodecDecode(codecStream, frame.label(), frame.bytes());
      } else if ("session".equals(frame.stream())) {
        assertInteropSessionDecode(sessionStream, frame.label(), frame.bytes());
      } else {
        throw new IllegalArgumentException("unknown stream " + frame.stream());
      }
      decoded++;
    }
    System.out.printf("Java client decode and value checks passed for %d Rust frames%n", decoded);
  }

  static void assertInteropCodecDecode(TwilicCodec codec, String label, byte[] frame) {
    if ("base_snapshot".equals(label)) {
      Message msg = codec.decodeMessage(frame);
      require(msg.kind == MessageKind.BASE_SNAPSHOT, "expected base snapshot");
      require(msg.baseSnapshot != null, "missing base snapshot");
      require(msg.baseSnapshot.baseId == 77L, "base_id mismatch");
      require(msg.baseSnapshot.payload.kind == MessageKind.SCALAR, "payload kind mismatch");
      require(
          msg.baseSnapshot.payload.scalar.kind == ValueKind.I64, "payload scalar kind mismatch");
      require(msg.baseSnapshot.payload.scalar.i64 == 42L, "payload mismatch");
      return;
    }

    ControlStreamCodec controlCodec = interopExpectControlStreamCodec(label);
    if (controlCodec != null) {
      Message msg = codec.decodeMessage(frame);
      require(msg.kind == MessageKind.CONTROL_STREAM, "expected control stream");
      require(msg.controlStream != null, "missing control stream");
      require(
          msg.controlStream.codec == controlCodec, "control stream codec mismatch for " + label);
      require(msg.controlStream.payload.length > 0, "control stream payload empty for " + label);
      return;
    }

    Value expected = interopExpectCodecValue(label);
    if (expected == null) {
      throw new IllegalArgumentException("no codec expectation for label " + label);
    }
    Value got = codec.decodeValue(frame);
    require(ProtocolHelpers.equal(got, expected), "decoded value mismatch for " + label);
  }

  static void assertInteropSessionDecode(TwilicCodec codec, String label, byte[] frame) {
    switch (label) {
      case "session_base_array" -> {
        Value got = codec.decodeValue(frame);
        Value want = Value.ofArray(interopMakeI64Array(100, 0));
        require(ProtocolHelpers.equal(got, want), "session_base_array value mismatch");
      }
      case "session_patch_one_change" -> {
        Message msg = codec.decodeMessage(frame);
        require(
            msg.kind == MessageKind.STATE_PATCH
                || msg.kind == MessageKind.TYPED_VECTOR
                || msg.kind == MessageKind.ARRAY,
            "unexpected message kind for session_patch_one_change");
      }
      case "session_patch_many_changes",
          "session_micro_batch_first",
          "session_micro_batch_second" -> {
        Message msg = codec.decodeMessage(frame);
        if ("session_patch_many_changes".equals(label)) {
          require(
              msg.kind == MessageKind.STATE_PATCH
                  || msg.kind == MessageKind.TYPED_VECTOR
                  || msg.kind == MessageKind.ARRAY,
              "expected patch or array message");
        } else {
          require(msg.kind == MessageKind.TEMPLATE_BATCH, "expected template batch");
          require(msg.templateBatch != null, "missing template batch");
          require(msg.templateBatch.count == 4L, "expected template batch with 4 rows");
        }
      }
      default -> {
        if (label.startsWith("session_patch_iter_")) {
          Message msg = codec.decodeMessage(frame);
          require(
              msg.kind == MessageKind.STATE_PATCH
                  || msg.kind == MessageKind.TYPED_VECTOR
                  || msg.kind == MessageKind.ARRAY,
              "expected patch or array message");
          return;
        }
        throw new IllegalArgumentException("no session expectation for label " + label);
      }
    }
  }

  private static void require(boolean condition, String message) {
    if (!condition) {
      throw new IllegalStateException(message);
    }
  }

  private static void resetEncodeShapeObservation(TwilicCodec codec, List<String> keys) {
    codec.state.encodeShapeObservations.remove(ProtocolHelpers.shapeKey(keys));
  }

  private static void emitInteropValue(
      StringBuilder out, String stream, String label, TwilicCodec codec, Value value) {
    emitInteropFrame(out, stream, label, codec.encodeValue(value));
  }

  private static void emitInteropMessage(
      StringBuilder out, String stream, String label, TwilicCodec codec, Message message) {
    emitInteropFrame(out, stream, label, codec.encodeMessage(message));
  }

  private static void emitInteropFrame(
      StringBuilder out, String stream, String label, byte[] bytes) {
    out.append(stream).append('|').append(label).append('|');
    for (byte b : bytes) {
      out.append(Character.forDigit((b >> 4) & 0xF, 16));
      out.append(Character.forDigit(b & 0xF, 16));
    }
    out.append('\n');
  }

  private static byte[] decodeInteropHex(String hex) {
    if (hex.length() % 2 != 0) {
      throw new IllegalArgumentException("invalid hex length");
    }
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    for (int i = 0; i < hex.length(); i += 2) {
      int hi = Character.digit(hex.charAt(i), 16);
      int lo = Character.digit(hex.charAt(i + 1), 16);
      if (hi < 0 || lo < 0) {
        throw new IllegalArgumentException("invalid hex");
      }
      out.write((hi << 4) | lo);
    }
    return out.toByteArray();
  }

  private static Value interopExpectCodecValue(String label) {
    if ("scalar_string".equals(label)) {
      return Value.ofString("alpha");
    }
    if (label.startsWith("map_two_fields_")) {
      return interopIdNameMap(1, "alice");
    }
    if (label.startsWith("map_three_fields_")) {
      return interopIdNameRoleMap(1, "alice", "admin");
    }
    if (label.startsWith("bulk_map_")) {
      int idx = Integer.parseInt(label.substring("bulk_map_".length()));
      return interopIdNameMap(10L + idx, "user-" + idx);
    }
    return null;
  }

  private static ControlStreamCodec interopExpectControlStreamCodec(String label) {
    return switch (label) {
      case "control_stream_bitpack" -> ControlStreamCodec.BITPACK;
      case "control_stream_huffman" -> ControlStreamCodec.HUFFMAN;
      case "control_stream_fse" -> ControlStreamCodec.FSE;
      default -> null;
    };
  }
}
