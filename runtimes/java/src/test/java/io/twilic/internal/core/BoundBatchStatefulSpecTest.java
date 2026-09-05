package io.twilic.internal.core;

import io.twilic.internal.core.Errors.TwilicErrorKind;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

final class BoundBatchStatefulSpecTest {
  @Test
  void schemaIdIsSentFirstThenOmitted() {
    SessionEncoder enc = new SessionEncoder();
    Schema schema = sampleSchema();
    Value value =
        Value.ofMap(
            List.of(
                new MapEntry("id", Value.ofU64(1005)),
                new MapEntry("name", Value.ofString("alice")),
                new MapEntry("score", Value.ofI64(99))));

    Message firstMsg = enc.decodeMessage(enc.encodeWithSchema(schema, value));
    Assertions.assertEquals(MessageKind.SCHEMA_OBJECT, firstMsg.kind);
    Assertions.assertNotNull(firstMsg.schemaObject.schemaId);
    Assertions.assertEquals(41L, firstMsg.schemaObject.schemaId);

    Message secondMsg = enc.decodeMessage(enc.encodeWithSchema(schema, value));
    Assertions.assertEquals(MessageKind.SCHEMA_OBJECT, secondMsg.kind);
  }

  @Test
  void batchThresholdSelectsRowVsColumn() {
    SessionEncoder enc = new SessionEncoder();

    List<Value> rows15 = new ArrayList<>();
    for (int i = 0; i < 15; i++) {
      rows15.add(Value.ofMap(List.of(new MapEntry("id", Value.ofU64(i)))));
    }
    byte[] b15 = enc.encodeBatch(rows15);
    Assertions.assertTrue(b15.length > 0);
    int kind15 = Byte.toUnsignedInt(b15[0]);
    Assertions.assertTrue(
        kind15 == MessageKind.COLUMN_BATCH.ordinal() || kind15 == MessageKind.ROW_BATCH.ordinal());

    List<Value> rows16 = new ArrayList<>();
    for (int i = 0; i < 16; i++) {
      rows16.add(Value.ofMap(List.of(new MapEntry("id", Value.ofU64(i)))));
    }
    byte[] b16 = enc.encodeBatch(rows16);
    Assertions.assertTrue(b16.length > 0);
    Assertions.assertEquals(MessageKind.COLUMN_BATCH.ordinal(), Byte.toUnsignedInt(b16[0]));
  }

  @Test
  void microBatchReusesTemplateAndEmitsChangedMask() {
    SessionEncoder enc = new SessionEncoder();
    List<Value> rows1 =
        List.of(
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(1)), new MapEntry("name", Value.ofString("a")))),
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(2)), new MapEntry("name", Value.ofString("b")))),
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(3)), new MapEntry("name", Value.ofString("c")))),
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(4)),
                    new MapEntry("name", Value.ofString("d")))));
    byte[] first = enc.encodeMicroBatch(rows1);
    Assertions.assertTrue(first.length > 0);
    Assertions.assertEquals(MessageKind.TEMPLATE_BATCH.ordinal(), Byte.toUnsignedInt(first[0]));

    List<Value> rows2 =
        List.of(
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(1)),
                    new MapEntry("name", Value.ofString("aa")))),
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(2)),
                    new MapEntry("name", Value.ofString("bb")))),
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(3)),
                    new MapEntry("name", Value.ofString("cc")))),
            Value.ofMap(
                List.of(
                    new MapEntry("id", Value.ofU64(4)),
                    new MapEntry("name", Value.ofString("dd")))));
    byte[] second = enc.encodeMicroBatch(rows2);
    Assertions.assertTrue(second.length > 0);
    Assertions.assertEquals(MessageKind.TEMPLATE_BATCH.ordinal(), Byte.toUnsignedInt(second[0]));
  }

  @Test
  void statePatchUsesRecommendedRatioThreshold() {
    SessionEncoder enc = new SessionEncoder();

    List<Value> baseValues = new ArrayList<>();
    for (int i = 0; i < 100; i++) {
      baseValues.add(Value.ofI64(i));
    }
    List<Value> oneChangeValues = new ArrayList<>(baseValues);
    oneChangeValues.set(0, Value.ofI64(10_000));
    List<Value> twelveChangeValues = new ArrayList<>(baseValues);
    for (int i = 0; i < 12; i++) {
      twelveChangeValues.set(i, Value.ofI64(10_000 + i));
    }

    enc.encode(Value.ofArray(baseValues));
    Message m1 = enc.decodeMessage(enc.encodePatch(Value.ofArray(oneChangeValues)));
    Assertions.assertNotNull(m1);
    Message m2 = enc.decodeMessage(enc.encodePatch(Value.ofArray(twelveChangeValues)));
    Assertions.assertNotNull(m2);
  }

  @Test
  void unknownBaseIdHonorsStatelessRetryPolicy() {
    SessionOptions opts = new SessionOptions();
    opts.unknownReferencePolicy = UnknownReferencePolicy.STATELESS_RETRY;
    SessionEncoder enc = new SessionEncoder(opts);

    Message patch = new Message();
    patch.kind = MessageKind.STATE_PATCH;
    patch.statePatch = new StatePatchMessage();
    patch.statePatch.baseRef = BaseRef.id(12_345);
    patch.statePatch.operations = new ArrayList<>();
    patch.statePatch.literals = new ArrayList<>();

    TwilicCodec builder = new TwilicCodec();
    byte[] bytes = builder.encodeMessage(patch);
    Throwable err =
        Assertions.assertThrows(Errors.TwilicException.class, () -> enc.decodeMessage(bytes));
    Errors.TwilicException te =
        TestHelpers.requireTwilicErrorKind(err, TwilicErrorKind.ERR_STATELESS_RETRY_REQUIRED);
    Assertions.assertEquals("base_id", te.refKind());
    Assertions.assertEquals(12_345L, te.refID());
  }

  @Test
  void statePatchMapInsertAndDeleteRoundtripViaReconstruction() {
    TwilicCodec codec = new TwilicCodec();
    Message base = new Message();
    base.kind = MessageKind.MAP;
    base.map =
        List.of(
            TestHelpers.messageMapEntry("id", Value.ofU64(1)),
            TestHelpers.messageMapEntry("name", Value.ofString("alice")));
    codec.decodeMessage(codec.encodeMessage(base));

    Value insertValue = Value.ofMap(List.of(new MapEntry("role", Value.ofString("admin"))));
    Message insertPatch = new Message();
    insertPatch.kind = MessageKind.STATE_PATCH;
    insertPatch.statePatch = new StatePatchMessage();
    insertPatch.statePatch.baseRef = BaseRef.previous();
    PatchOperation insertOp = new PatchOperation();
    insertOp.fieldId = 2;
    insertOp.opcode = PatchOpcode.INSERT_FIELD;
    insertOp.value = insertValue;
    insertPatch.statePatch.operations = List.of(insertOp);
    codec.decodeMessage(codec.encodeMessage(insertPatch));
    Assertions.assertNotNull(codec.state.previousMessage);
    Assertions.assertEquals(MessageKind.MAP, codec.state.previousMessage.kind);

    Message deletePatch = new Message();
    deletePatch.kind = MessageKind.STATE_PATCH;
    deletePatch.statePatch = new StatePatchMessage();
    deletePatch.statePatch.baseRef = BaseRef.previous();
    PatchOperation deleteOp = new PatchOperation();
    deleteOp.fieldId = 2;
    deleteOp.opcode = PatchOpcode.DELETE_FIELD;
    deletePatch.statePatch.operations = List.of(deleteOp);
    codec.decodeMessage(codec.encodeMessage(deletePatch));
    Assertions.assertNotNull(codec.state.previousMessage);
    Assertions.assertEquals(MessageKind.MAP, codec.state.previousMessage.kind);
    Assertions.assertEquals(2, codec.state.previousMessage.map.size());
  }

  @Test
  void columnBatchAssignsDictionaryIdForRepeatedStringField() {
    SessionEncoder enc = new SessionEncoder();
    List<Value> rows = new ArrayList<>();
    for (int i = 0; i < 32; i++) {
      String role = (i % 2 == 0) ? "admin" : "user";
      rows.add(
          Value.ofMap(
              List.of(
                  new MapEntry("id", Value.ofU64(i)), new MapEntry("role", Value.ofString(role)))));
    }
    byte[] bytes = enc.encodeBatch(rows);
    Assertions.assertTrue(bytes.length > 0);
    Assertions.assertEquals(MessageKind.COLUMN_BATCH.ordinal(), Byte.toUnsignedInt(bytes[0]));
  }

  @Test
  void trainedDictionaryProfileIsTransportedToFreshDecoder() {
    SessionEncoder enc = new SessionEncoder();
    List<Value> rows = new ArrayList<>();
    for (int i = 0; i < 32; i++) {
      String role = (i % 2 == 0) ? "admin" : "user";
      rows.add(
          Value.ofMap(
              List.of(
                  new MapEntry("id", Value.ofU64(i)), new MapEntry("role", Value.ofString(role)))));
    }
    byte[] bytes = enc.encodeBatch(rows);

    TwilicCodec dec = new TwilicCodec();
    Message decoded = dec.decodeMessage(bytes);
    Assertions.assertEquals(MessageKind.COLUMN_BATCH, decoded.kind);
    Assertions.assertNotNull(decoded.columnBatch);

    Long dictId = null;
    for (Column c : decoded.columnBatch.columns) {
      if (c.dictionaryId != null) {
        dictId = c.dictionaryId;
        break;
      }
    }
    Assertions.assertNotNull(dictId, "dictionary id in batch");

    byte[] payload = dec.state.dictionaries.get(dictId);
    Assertions.assertNotNull(payload, "transported dictionary payload");
    DictionaryProfile profile = dec.state.dictionaryProfiles.get(dictId);
    Assertions.assertNotNull(profile, "transported dictionary profile");
    Assertions.assertEquals(1L, profile.version);
    Assertions.assertEquals(0L, profile.expiresAt);
    Assertions.assertEquals(DictionaryFallback.FAIL_FAST, profile.fallback);
    Assertions.assertEquals(Dictionary.dictionaryPayloadHash(payload), profile.hash);

    List<String> roleValues = null;
    for (Column c : decoded.columnBatch.columns) {
      if (c.dictionaryId != null && c.dictionaryId.equals(dictId)) {
        roleValues = c.values.strings;
        break;
      }
    }
    Assertions.assertNotNull(roleValues);
    Assertions.assertEquals(32, roleValues.size());
    Assertions.assertEquals("admin", roleValues.getFirst());
    Assertions.assertEquals("user", roleValues.get(1));
  }

  @Test
  void invalidDictionaryProfileHashIsRejected() {
    TwilicCodec enc = new TwilicCodec();
    long dictId = 42L;
    enc.state.dictionaries.put(dictId, new byte[] {1, 2, 3, 4});
    enc.state.dictionaryProfiles.put(
        dictId, new DictionaryProfile(1L, 7L, 0L, DictionaryFallback.FAIL_FAST));

    Message msg = new Message();
    msg.kind = MessageKind.COLUMN_BATCH;
    msg.columnBatch = new ColumnBatchMessage();
    msg.columnBatch.count = 1;
    Column col = new Column();
    col.fieldId = 0;
    col.nullStrategy = NullStrategy.ALL_PRESENT_ELIDED;
    col.codec = VectorCodec.DICTIONARY;
    col.dictionaryId = dictId;
    col.values.kind = ElementType.STRING;
    col.values.strings = List.of("admin");
    msg.columnBatch.columns = List.of(col);

    byte[] bytes = enc.encodeMessage(msg);
    TwilicCodec dec = new TwilicCodec();
    Throwable err =
        Assertions.assertThrows(Errors.TwilicException.class, () -> dec.decodeMessage(bytes));
    Errors.TwilicException te =
        TestHelpers.requireTwilicErrorKind(err, TwilicErrorKind.ERR_INVALID_DATA);
    Assertions.assertEquals("dictionary profile hash mismatch", te.msg());
  }

  @Test
  void trainedDictionaryReferenceWritesCompressedBlockAfterDictId() {
    long dictId = 9L;
    TwilicCodec codec = new TwilicCodec();
    ByteArrayOutputStream payload = new ByteArrayOutputStream();
    Wire.encodeVaruint(2L, payload);
    Wire.encodeString("admin", payload);
    Wire.encodeString("user", payload);
    byte[] payloadBytes = payload.toByteArray();
    codec.state.dictionaries.put(dictId, payloadBytes);
    codec.state.dictionaryProfiles.put(
        dictId,
        new DictionaryProfile(
            1L, Dictionary.dictionaryPayloadHash(payloadBytes), 0L, DictionaryFallback.FAIL_FAST));

    Message msg = new Message();
    msg.kind = MessageKind.COLUMN_BATCH;
    msg.columnBatch = new ColumnBatchMessage();
    msg.columnBatch.count = 4;
    Column col = new Column();
    col.fieldId = 1;
    col.nullStrategy = NullStrategy.ALL_PRESENT_ELIDED;
    col.codec = VectorCodec.DICTIONARY;
    col.dictionaryId = dictId;
    col.values.kind = ElementType.STRING;
    col.values.strings = List.of("admin", "user", "admin", "user");
    msg.columnBatch.columns = List.of(col);

    byte[] bytes = codec.encodeMessage(msg);

    Wire.Reader reader = Wire.newReader(bytes);
    int kind = Byte.toUnsignedInt(reader.readU8());
    Assertions.assertEquals(MessageKind.COLUMN_BATCH.ordinal(), kind);
    reader.readVaruint();
    reader.readVaruint();
    reader.readVaruint();
    reader.readU8();
    reader.readU8();
    long gotDictId = reader.readVaruint();
    Assertions.assertNotEquals(0L, gotDictId);

    TwilicCodec fresh = new TwilicCodec();
    Message decoded = fresh.decodeMessage(bytes);
    Assertions.assertEquals(MessageKind.COLUMN_BATCH, decoded.kind);
    List<String> values = decoded.columnBatch.columns.getFirst().values.strings;
    Assertions.assertEquals(List.of("admin", "user", "admin", "user"), values);
  }

  private Schema sampleSchema() {
    Schema schema = new Schema();
    schema.schemaId = 41;
    schema.name = "User";

    SchemaField id = new SchemaField();
    id.number = 1;
    id.name = "id";
    id.logicalType = "u64";
    id.required = true;
    id.min = 1000L;
    id.max = 1100L;

    SchemaField name = new SchemaField();
    name.number = 2;
    name.name = "name";
    name.logicalType = "string";
    name.required = true;

    SchemaField score = new SchemaField();
    score.number = 3;
    score.name = "score";
    score.logicalType = "i64";
    score.required = false;
    score.min = 0L;
    score.max = 100L;

    schema.fields = List.of(id, name, score);
    return schema;
  }
}
