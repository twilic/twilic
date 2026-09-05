package io.twilic.internal.core;

import io.twilic.internal.core.Errors.TwilicErrorKind;
import io.twilic.internal.core.Errors.TwilicException;
import org.junit.jupiter.api.Assertions;

final class TestHelpers {
  private TestHelpers() {}

  static TwilicException requireTwilicErrorKind(Throwable err, TwilicErrorKind kind) {
    Assertions.assertNotNull(err, "expected TwilicException");
    Assertions.assertInstanceOf(TwilicException.class, err);
    TwilicException te = (TwilicException) err;
    Assertions.assertEquals(kind, te.kind(), "unexpected TwilicError kind");
    return te;
  }

  static MessageMapEntry messageMapEntry(String key, Value value) {
    return new MessageMapEntry(KeyRef.literal(key), value);
  }

  static boolean equalMessage(Message a, Message b) {
    if (a.kind != b.kind) {
      return false;
    }
    return switch (a.kind) {
      case SCALAR ->
          ProtocolHelpers.equal(
              ProtocolHelpers.cloneValue(a.scalar), ProtocolHelpers.cloneValue(b.scalar));
      case ARRAY -> {
        if (a.array.size() != b.array.size()) {
          yield false;
        }
        boolean same = true;
        for (int i = 0; i < a.array.size(); i++) {
          if (!ProtocolHelpers.equal(a.array.get(i), b.array.get(i))) {
            same = false;
            break;
          }
        }
        yield same;
      }
      case MAP -> {
        if (a.map.size() != b.map.size()) {
          yield false;
        }
        boolean same = true;
        for (int i = 0; i < a.map.size(); i++) {
          MessageMapEntry ea = a.map.get(i);
          MessageMapEntry eb = b.map.get(i);
          if (ea.key.isId != eb.key.isId
              || ea.key.id != eb.key.id
              || !String.valueOf(ea.key.literal).equals(String.valueOf(eb.key.literal))
              || !ProtocolHelpers.equal(ea.value, eb.value)) {
            same = false;
            break;
          }
        }
        yield same;
      }
      default -> ProtocolHelpers.cloneMessage(a).equals(ProtocolHelpers.cloneMessage(b));
    };
  }
}
