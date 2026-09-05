package io.twilic.internal.core;

import io.twilic.internal.core.Errors.TwilicErrorKind;
import java.util.List;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

final class ControlStreamAndControlSpecTest {
  @Test
  void controlStreamRoundtripsForAllDeclaredCodecs() {
    TwilicCodec codec = new TwilicCodec();
    byte[] payload = new byte[] {0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4};
    for (ControlStreamCodec c :
        List.of(
            ControlStreamCodec.PLAIN,
            ControlStreamCodec.RLE,
            ControlStreamCodec.BITPACK,
            ControlStreamCodec.HUFFMAN,
            ControlStreamCodec.FSE)) {
      Message msg = new Message();
      msg.kind = MessageKind.CONTROL_STREAM;
      msg.controlStream = new ControlStreamMessage();
      msg.controlStream.codec = c;
      msg.controlStream.payload = payload.clone();
      Message decoded = codec.decodeMessage(codec.encodeMessage(msg));
      Assertions.assertEquals(MessageKind.CONTROL_STREAM, decoded.kind);
      Assertions.assertEquals(c, decoded.controlStream.codec);
      Assertions.assertArrayEquals(payload, decoded.controlStream.payload);
    }
  }

  @Test
  void controlStreamBitpackHuffmanFseCompactRepetitivePayloads() {
    byte[] binaryPayload = new byte[512];
    for (int i = 0; i < binaryPayload.length; i++) {
      binaryPayload[i] = (byte) (i % 2);
    }
    int plainBinaryLen = encodedControlStreamLen(ControlStreamCodec.PLAIN, binaryPayload.clone());
    int bitpackLen = encodedControlStreamLen(ControlStreamCodec.BITPACK, binaryPayload.clone());
    Assertions.assertTrue(bitpackLen <= plainBinaryLen);

    byte[] rleFriendly = new byte[512];
    for (int i = 0; i < rleFriendly.length; i++) {
      rleFriendly[i] = 7;
    }
    int plainRleLen = encodedControlStreamLen(ControlStreamCodec.PLAIN, rleFriendly.clone());
    int huffmanLen = encodedControlStreamLen(ControlStreamCodec.HUFFMAN, rleFriendly.clone());
    Assertions.assertTrue(huffmanLen <= plainRleLen);

    byte[] lowCard = new byte[512];
    for (int i = 0; i < lowCard.length; i++) {
      lowCard[i] = (byte) (i % 4);
    }
    int plainLowCardLen = encodedControlStreamLen(ControlStreamCodec.PLAIN, lowCard.clone());
    int fseLen = encodedControlStreamLen(ControlStreamCodec.FSE, lowCard.clone());
    Assertions.assertTrue(fseLen <= plainLowCardLen);
  }

  @Test
  void controlStreamFseUsesFseFrameMode() {
    TwilicCodec codec = new TwilicCodec();
    byte[] payload = new byte[512];
    for (int i = 0; i < payload.length; i++) {
      payload[i] = (byte) (i % 4);
    }
    Message msg = new Message();
    msg.kind = MessageKind.CONTROL_STREAM;
    msg.controlStream = new ControlStreamMessage();
    msg.controlStream.codec = ControlStreamCodec.FSE;
    msg.controlStream.payload = payload;

    byte[] bytes = codec.encodeMessage(msg);
    Wire.Reader reader = Wire.newReader(bytes);
    Assertions.assertEquals(
        MessageKind.CONTROL_STREAM.ordinal(), Byte.toUnsignedInt(reader.readU8()));
    Assertions.assertEquals(ControlStreamCodec.FSE.ordinal(), Byte.toUnsignedInt(reader.readU8()));
    byte[] framed = reader.readBytes();
    Assertions.assertTrue(framed.length > 0);
  }

  @Test
  void registerShapeWithKeyIdsRoundtrips() {
    TwilicCodec codec = new TwilicCodec();

    Message regKeys = new Message();
    regKeys.kind = MessageKind.CONTROL;
    regKeys.control = new ControlMessage();
    regKeys.control.opcode = ControlOpcode.REGISTER_KEYS;
    regKeys.control.registerKeys = List.of("id", "name");
    codec.decodeMessage(codec.encodeMessage(regKeys));

    Message regShape = new Message();
    regShape.kind = MessageKind.CONTROL;
    regShape.control = new ControlMessage();
    regShape.control.opcode = ControlOpcode.REGISTER_SHAPE;
    regShape.control.registerShape = new RegisterShapeControl();
    regShape.control.registerShape.shapeId = 99;
    regShape.control.registerShape.keys = List.of(KeyRef.id(0), KeyRef.id(1));
    Message decoded = codec.decodeMessage(codec.encodeMessage(regShape));
    Assertions.assertEquals(MessageKind.CONTROL, decoded.kind);
    Assertions.assertNotNull(decoded.control.registerShape);

    Message shaped = new Message();
    shaped.kind = MessageKind.SHAPED_OBJECT;
    shaped.shapedObject = new ShapedObjectMessage();
    shaped.shapedObject.shapeId = 99;
    shaped.shapedObject.values = List.of(Value.ofU64(1), Value.ofString("alice"));
    Value value = codec.decodeValue(codec.encodeMessage(shaped));
    Assertions.assertEquals(ValueKind.MAP, value.kind);
  }

  @Test
  void resetStateClearsShapeResolution() {
    TwilicCodec codec = new TwilicCodec();

    Message regShape = new Message();
    regShape.kind = MessageKind.CONTROL;
    regShape.control = new ControlMessage();
    regShape.control.opcode = ControlOpcode.REGISTER_SHAPE;
    regShape.control.registerShape = new RegisterShapeControl();
    regShape.control.registerShape.shapeId = 7;
    regShape.control.registerShape.keys = List.of(KeyRef.literal("id"), KeyRef.literal("name"));
    codec.decodeMessage(codec.encodeMessage(regShape));

    Message reset = new Message();
    reset.kind = MessageKind.CONTROL;
    reset.control = new ControlMessage();
    reset.control.opcode = ControlOpcode.RESET_STATE;
    reset.control.resetState = true;
    codec.decodeMessage(codec.encodeMessage(reset));

    Message shaped = new Message();
    shaped.kind = MessageKind.SHAPED_OBJECT;
    shaped.shapedObject = new ShapedObjectMessage();
    shaped.shapedObject.shapeId = 7;
    shaped.shapedObject.values = List.of(Value.ofU64(1), Value.ofString("alice"));
    Throwable err =
        Assertions.assertThrows(
            Errors.TwilicException.class, () -> codec.decodeValue(codec.encodeMessage(shaped)));
    Errors.TwilicException te =
        TestHelpers.requireTwilicErrorKind(err, TwilicErrorKind.ERR_UNKNOWN_REFERENCE);
    Assertions.assertEquals("shape_id", te.refKind());
    Assertions.assertEquals(7L, te.refID());
  }

  private int encodedControlStreamLen(ControlStreamCodec codec, byte[] payload) {
    TwilicCodec impl = new TwilicCodec();
    Message msg = new Message();
    msg.kind = MessageKind.CONTROL_STREAM;
    msg.controlStream = new ControlStreamMessage();
    msg.controlStream.codec = codec;
    msg.controlStream.payload = payload;
    return impl.encodeMessage(msg).length;
  }
}
