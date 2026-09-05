package io.twilic.internal.core;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
class SecurityLimitsTest {
  @Test void cumulativeBudgetAndBounds() {
    Wire.Reader reader = new Wire.Reader(new byte[]{0});
    reader.claimOutput(100);
    assertThrows(RuntimeException.class, () -> reader.claimOutput(100));
    assertThrows(RuntimeException.class, () -> reader.readExact(-1));
    assertThrows(RuntimeException.class, () -> reader.readExact(Integer.MAX_VALUE));
  }
  @Test void rejectsDeepSessionInput() {
    byte[] bytes = new byte[142];
    for (int i = 0; i < 70; i++) { bytes[1 + i * 2] = 8; bytes[2 + i * 2] = 1; }
    assertThrows(RuntimeException.class, () -> new TwilicCodec().decodeMessage(bytes));
  }
}
