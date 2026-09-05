package io.twilic.internal.core;

import java.util.List;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

final class DynamicProfileSpecTest {
  @Test
  void shapePromotesAfterSecondThreeFieldMap() {
    TwilicCodec codec = new TwilicCodec();
    Value value =
        Value.ofMap(
            List.of(
                new MapEntry("id", Value.ofU64(1)),
                new MapEntry("name", Value.ofString("alice")),
                new MapEntry("role", Value.ofString("admin"))));

    Message firstMsg = codec.decodeMessage(codec.encodeValue(value));
    Assertions.assertEquals(MessageKind.MAP, firstMsg.kind);

    Message secondMsg = codec.decodeMessage(codec.encodeValue(value));
    Assertions.assertEquals(MessageKind.SHAPED_OBJECT, secondMsg.kind);

    Message thirdMsg = codec.decodeMessage(codec.encodeValue(value));
    Assertions.assertEquals(MessageKind.SHAPED_OBJECT, thirdMsg.kind);
  }

  @Test
  void twoFieldMapKeepsMapAndUsesKeyIds() {
    TwilicCodec codec = new TwilicCodec();
    Value value =
        Value.ofMap(
            List.of(
                new MapEntry("id", Value.ofU64(1)), new MapEntry("name", Value.ofString("alice"))));

    Message firstMsg = codec.decodeMessage(codec.encodeValue(value));
    Assertions.assertEquals(MessageKind.MAP, firstMsg.kind);
    for (MessageMapEntry entry : firstMsg.map) {
      Assertions.assertFalse(entry.key.isId, "expected literal keys on first map");
    }

    Message secondMsg = codec.decodeMessage(codec.encodeValue(value));
    Assertions.assertTrue(
        secondMsg.kind == MessageKind.MAP || secondMsg.kind == MessageKind.SHAPED_OBJECT,
        "expected map or shaped object");
    if (secondMsg.kind == MessageKind.MAP) {
      for (MessageMapEntry entry : secondMsg.map) {
        Assertions.assertTrue(entry.key.isId, "expected key ref ids on second map");
      }
    }
  }

  @Test
  void typedVectorThresholdIsApplied() {
    TwilicCodec codec = new TwilicCodec();

    Value shortArr = Value.ofArray(List.of(Value.ofI64(1), Value.ofI64(2), Value.ofI64(3)));
    Message shortMsg = codec.decodeMessage(codec.encodeValue(shortArr));
    Assertions.assertEquals(MessageKind.ARRAY, shortMsg.kind);

    Value longArr =
        Value.ofArray(List.of(Value.ofI64(1), Value.ofI64(2), Value.ofI64(3), Value.ofI64(4)));
    Message longMsg = codec.decodeMessage(codec.encodeValue(longArr));
    Assertions.assertEquals(MessageKind.TYPED_VECTOR, longMsg.kind);
  }

  @Test
  void stringModesEmptyRefAndPrefixDeltaAreUsed() {
    TwilicCodec codec = new TwilicCodec();

    byte[] emptyBytes = codec.encodeValue(Value.ofString(""));
    Assertions.assertEquals(StringMode.EMPTY.ordinal(), scalarStringMode(emptyBytes));

    byte[] litBytes = codec.encodeValue(Value.ofString("alpha"));
    Assertions.assertEquals(StringMode.LITERAL.ordinal(), scalarStringMode(litBytes));

    byte[] refBytes = codec.encodeValue(Value.ofString("alpha"));
    Assertions.assertEquals(StringMode.REF.ordinal(), scalarStringMode(refBytes));

    codec.encodeValue(Value.ofString("prefix_common_aaaa"));
    byte[] prefixDeltaBytes = codec.encodeValue(Value.ofString("prefix_common_bbbb"));
    Assertions.assertEquals(StringMode.PREFIX_DELTA.ordinal(), scalarStringMode(prefixDeltaBytes));
  }

  @Test
  void resetTablesClearsStringInterning() {
    TwilicCodec codec = new TwilicCodec();

    codec.encodeValue(Value.ofString("ephemeral"));
    byte[] reusedBytes = codec.encodeValue(Value.ofString("ephemeral"));
    Assertions.assertEquals(StringMode.REF.ordinal(), scalarStringMode(reusedBytes));

    Message reset = new Message();
    reset.kind = MessageKind.CONTROL;
    reset.control = new ControlMessage();
    reset.control.opcode = ControlOpcode.RESET_TABLES;
    reset.control.resetTables = true;
    codec.decodeMessage(codec.encodeMessage(reset));

    byte[] afterBytes = codec.encodeValue(Value.ofString("ephemeral"));
    Assertions.assertEquals(StringMode.LITERAL.ordinal(), scalarStringMode(afterBytes));
  }

  private int scalarStringMode(byte[] bytes) {
    Assertions.assertTrue(bytes.length >= 3, "expected at least 3 bytes");
    Assertions.assertEquals(MessageKind.SCALAR.ordinal(), Byte.toUnsignedInt(bytes[0]));
    Assertions.assertEquals(Protocol.TAG_STRING, Byte.toUnsignedInt(bytes[1]));
    return Byte.toUnsignedInt(bytes[2]);
  }
}
