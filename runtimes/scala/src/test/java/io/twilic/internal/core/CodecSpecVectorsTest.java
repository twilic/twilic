package io.twilic.internal.core;

import io.twilic.internal.core.Errors.TwilicErrorKind;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

final class CodecSpecVectorsTest {
  @Test
  void simple8bI64RoundtripSmallValues() {
    List<Long> values = List.of(1L, 2L, 3L, -1L, 0L, 4L, -2L, 6L, 8L, 10L, -3L, 5L);
    List<Byte> out = new ArrayList<>();
    Codec.encodeI64Vector(values, VectorCodec.SIMPLE8B, out);

    List<Long> decoded =
        Codec.decodeI64Vector(
            Wire.newReader(ProtocolHelpers.toByteArray(out)), VectorCodec.SIMPLE8B);
    Assertions.assertEquals(values, decoded);
  }

  @Test
  void simple8bU64RoundtripWithLongZeroRuns() {
    List<Long> values = new ArrayList<>();
    for (int i = 0; i < 130; i++) {
      values.add(0L);
    }
    values.addAll(List.of(1L, 2L, 3L, 4L, 5L));
    for (int i = 0; i < 250; i++) {
      values.add(0L);
    }

    List<Byte> out = new ArrayList<>();
    Codec.encodeU64Vector(values, VectorCodec.SIMPLE8B, out);

    List<Long> decoded =
        Codec.decodeU64Vector(
            Wire.newReader(ProtocolHelpers.toByteArray(out)), VectorCodec.SIMPLE8B);
    Assertions.assertEquals(values, decoded);
  }

  @Test
  void simple8bU64FallsBackForLargeValues() {
    List<Long> values = List.of(1L << 61, (1L << 61) + 7L, (1L << 61) + 99L);
    List<Byte> out = new ArrayList<>();
    Codec.encodeU64Vector(values, VectorCodec.SIMPLE8B, out);

    List<Long> decoded =
        Codec.decodeU64Vector(
            Wire.newReader(ProtocolHelpers.toByteArray(out)), VectorCodec.SIMPLE8B);
    Assertions.assertEquals(values, decoded);
  }

  @Test
  void forU64OverflowIsRejected() {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    Wire.encodeVaruint(-1L, bytes);
    Wire.encodeVaruint(1L, bytes);
    bytes.write(1);
    bytes.write(0x01);

    Throwable err =
        Assertions.assertThrows(
            Errors.TwilicException.class,
            () ->
                Codec.decodeU64Vector(
                    Wire.newReader(bytes.toByteArray()), VectorCodec.FOR_BITPACK));
    Errors.TwilicException te =
        TestHelpers.requireTwilicErrorKind(err, TwilicErrorKind.ERR_INVALID_DATA);
    Assertions.assertEquals("u64 FOR overflow", te.msg());
  }

  @Test
  void directBitpackInvalidWidthIsRejected() {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    Wire.encodeVaruint(1L, bytes);
    bytes.write(0);

    Throwable err =
        Assertions.assertThrows(
            Errors.TwilicException.class,
            () ->
                Codec.decodeI64Vector(
                    Wire.newReader(bytes.toByteArray()), VectorCodec.DIRECT_BITPACK));
    Errors.TwilicException te =
        TestHelpers.requireTwilicErrorKind(err, TwilicErrorKind.ERR_INVALID_DATA);
    Assertions.assertEquals("bitpack width", te.msg());
  }

  @Test
  void xorFloatRoundtripSmoothSeries() {
    List<Double> values = List.of(1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5);
    List<Byte> out = new ArrayList<>();
    Codec.encodeF64Vector(values, VectorCodec.XOR_FLOAT, out);

    List<Double> decoded =
        Codec.decodeF64Vector(
            Wire.newReader(ProtocolHelpers.toByteArray(out)), VectorCodec.XOR_FLOAT);
    Assertions.assertEquals(values, decoded);
  }
}
