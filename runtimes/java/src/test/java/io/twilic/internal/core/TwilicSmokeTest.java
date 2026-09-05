package io.twilic.internal.core;

import io.twilic.Twilic;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

final class TwilicSmokeTest {
  @Test
  void roundTripMap() {
    Value input = Value.ofMap(java.util.List.of(new MapEntry("id", Value.ofU64(42L))));
    byte[] encoded = Twilic.encode(input);
    Value decoded = Twilic.decode(encoded);
    Assertions.assertEquals(ValueKind.MAP, decoded.kind);
    Assertions.assertEquals("id", decoded.map.getFirst().key);
    Assertions.assertEquals(42L, decoded.map.getFirst().value.u64);
  }
}
