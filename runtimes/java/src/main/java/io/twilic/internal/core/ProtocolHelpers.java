package io.twilic.internal.core;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;

final class ProtocolHelpers {
  private ProtocolHelpers() {}

  static long allocateBaseId(SessionState state) {
    long id = state.nextBaseId;
    state.nextBaseId += 1;
    return id;
  }

  static long allocateTemplateId(SessionState state) {
    long id = state.nextTemplateId;
    state.nextTemplateId += 1;
    return id;
  }

  static void registerBaseSnapshot(SessionState state, long baseId, Message message) {
    BaseSnapshotEntry entry = new BaseSnapshotEntry();
    entry.id = baseId;
    entry.message = cloneMessage(message);
    state.baseSnapshots.add(entry);
    int max = state.options.maxBaseSnapshots;
    if (max >= 0) {
      while (state.baseSnapshots.size() > max) {
        state.baseSnapshots.remove(0);
      }
    }
  }

  static Message getBaseSnapshot(SessionState state, long baseId) {
    for (BaseSnapshotEntry entry : state.baseSnapshots) {
      if (entry.id == baseId) {
        return cloneMessage(entry.message);
      }
    }
    return null;
  }

  static void resetTables(SessionState state) {
    state.keyTable.clear();
    state.stringTable.clear();
    state.shapeTable.byId.clear();
    state.shapeTable.byKeys.clear();
    state.shapeTable.observations.clear();
    state.shapeTable.nextId = 0;
    state.fieldEnums.clear();
    state.templates.clear();
    state.templateColumns.clear();
    state.dictionaries.clear();
    state.dictionaryProfiles.clear();
    state.schemas.clear();
    state.lastSchemaId = null;
  }

  static void resetState(SessionState state) {
    resetTables(state);
    state.previousMessage = null;
    state.previousMessageSize = null;
    state.baseSnapshots.clear();
    state.encodeShapeObservations.clear();
    state.nextBaseId = 0;
    state.nextTemplateId = 0;
    state.nextDictionaryId = 0;
  }

  static String shapeKey(List<String> keys) {
    return Session.shapeKey(keys);
  }

  static long shapeObserve(ShapeTable table, List<String> keys) {
    String key = shapeKey(keys);
    long count = table.observations.getOrDefault(key, 0L) + 1L;
    table.observations.put(key, count);
    return count;
  }

  static long shapeRegister(ShapeTable table, List<String> keys) {
    String key = shapeKey(keys);
    Long existing = table.byKeys.get(key);
    if (existing != null) {
      return existing;
    }
    long id = table.nextId;
    table.nextId += 1L;
    table.byKeys.put(key, id);
    table.byId.put(id, new ArrayList<>(keys));
    return id;
  }

  static void shapeRegisterWithId(ShapeTable table, long shapeId, List<String> keys) {
    String key = shapeKey(keys);
    table.byKeys.put(key, shapeId);
    table.byId.put(shapeId, new ArrayList<>(keys));
    if (shapeId >= table.nextId) {
      table.nextId = shapeId + 1L;
    }
  }

  static Long shapeGetId(ShapeTable table, List<String> keys) {
    return table.byKeys.get(shapeKey(keys));
  }

  static List<String> shapeGetKeys(ShapeTable table, long shapeId) {
    List<String> keys = table.byId.get(shapeId);
    return keys == null ? null : new ArrayList<>(keys);
  }

  static int typedVectorLen(TypedVectorData data) {
    return switch (data.kind) {
      case BOOL -> data.bools.size();
      case I64 -> data.i64s.size();
      case U64 -> data.u64s.size();
      case F64 -> data.f64s.size();
      case STRING -> data.strings.size();
      case BINARY -> data.binary.size();
      case VALUE -> data.values.size();
    };
  }

  static Value lookupMapField(Value value, String key) {
    if (value.kind != ValueKind.MAP) {
      return null;
    }
    for (MapEntry entry : value.map) {
      if (entry.key.equals(key)) {
        return cloneValue(entry.value);
      }
    }
    return null;
  }

  static List<Integer> schemaPresentFieldIndices(
      Schema schema, List<Boolean> presence, boolean hasPresence) {
    if (!hasPresence) {
      List<Integer> out = new ArrayList<>();
      for (int i = 0; i < schema.fields.size(); i++) {
        out.add(i);
      }
      return out;
    }
    if (presence.size() != schema.fields.size()) {
      throw Errors.invalidData("presence bitmap mismatch for schema");
    }
    List<Integer> out = new ArrayList<>();
    for (int i = 0; i < schema.fields.size(); i++) {
      if (presence.get(i)) {
        out.add(i);
      }
    }
    return out;
  }

  static String normalizedLogicalType(String raw) {
    return raw == null ? "" : raw.strip().toLowerCase();
  }

  static List<List<Value>> rowsFromValues(List<Value> values) {
    List<List<Value>> rows = new ArrayList<>();
    for (Value value : values) {
      if (value.kind == ValueKind.ARRAY) {
        List<Value> row = new ArrayList<>();
        for (Value item : value.arr) {
          row.add(cloneValue(item));
        }
        rows.add(row);
      } else {
        List<Value> row = new ArrayList<>();
        row.add(cloneValue(value));
        rows.add(row);
      }
    }
    return rows;
  }

  private record ColumnNullStrategyResult(
      NullStrategy nullStrategy, List<Boolean> presence, boolean hasPresence) {}

  static ColumnNullStrategyResult columnNullStrategy(
      List<Value> values, List<Boolean> presentBits) {
    int nullCount = 0;
    for (Value value : values) {
      if (value.kind == ValueKind.NULL) {
        nullCount++;
      }
    }
    int optionalCount = values.size();
    if (nullCount == 0) {
      return new ColumnNullStrategyResult(NullStrategy.ALL_PRESENT_ELIDED, null, false);
    }
    if (nullCount <= optionalCount / 4) {
      List<Boolean> inverted = new ArrayList<>(presentBits.size());
      for (boolean bit : presentBits) {
        inverted.add(!bit);
      }
      return new ColumnNullStrategyResult(NullStrategy.INVERTED_PRESENCE_BITMAP, inverted, true);
    }
    return new ColumnNullStrategyResult(
        NullStrategy.PRESENCE_BITMAP, new ArrayList<>(presentBits), true);
  }

  static List<Value> stripNulls(List<Value> values) {
    List<Value> out = new ArrayList<>();
    for (Value value : values) {
      if (value.kind != ValueKind.NULL) {
        out.add(value);
      }
    }
    return out;
  }

  static List<Column> columnsFromMapValues(List<Value> values) {
    if (values.isEmpty()) {
      return null;
    }
    for (Value value : values) {
      if (value.kind != ValueKind.MAP) {
        return null;
      }
    }
    List<String> keyOrder = new ArrayList<>();
    Map<String, Integer> keyIndex = new HashMap<>();
    List<List<Value>> columnValues = new ArrayList<>();
    List<List<Boolean>> columnPresence = new ArrayList<>();

    for (int rowIdx = 0; rowIdx < values.size(); rowIdx++) {
      Value row = values.get(rowIdx);
      List<Boolean> present = new ArrayList<>();
      for (int i = 0; i < keyOrder.size(); i++) {
        present.add(false);
      }
      for (MapEntry entry : row.map) {
        String key = entry.key;
        Value entryValue = cloneValue(entry.value);
        Integer colIdx = keyIndex.get(key);
        if (colIdx == null) {
          colIdx = keyOrder.size();
          keyOrder.add(key);
          keyIndex.put(key, colIdx);
          List<Value> seededValues = new ArrayList<>();
          List<Boolean> seededPresence = new ArrayList<>();
          for (int i = 0; i < rowIdx; i++) {
            seededValues.add(Value.ofNull());
            seededPresence.add(false);
          }
          columnValues.add(seededValues);
          columnPresence.add(seededPresence);
          present.add(false);
        }
        columnValues.get(colIdx).add(entryValue);
        columnPresence.get(colIdx).add(true);
        present.set(colIdx, true);
      }
      for (int colIdx = 0; colIdx < keyOrder.size(); colIdx++) {
        if (!present.get(colIdx)) {
          columnValues.get(colIdx).add(Value.ofNull());
          columnPresence.get(colIdx).add(false);
        }
      }
    }

    List<Column> columns = new ArrayList<>();
    for (int fieldId = 0; fieldId < keyOrder.size(); fieldId++) {
      List<Value> colValues = columnValues.get(fieldId);
      List<Boolean> presentBits = columnPresence.get(fieldId);
      ColumnNullStrategyResult nullPlan = columnNullStrategy(colValues, presentBits);
      CodecAndValues codecAndValues = inferColumnCodecAndValues(stripNulls(colValues));
      Column column = new Column();
      column.fieldId = fieldId;
      column.nullStrategy = nullPlan.nullStrategy;
      column.presence = nullPlan.presence == null ? new ArrayList<>() : nullPlan.presence;
      column.hasPresence = nullPlan.hasPresence;
      column.codec = codecAndValues.codec;
      column.values = codecAndValues.values;
      columns.add(column);
    }
    return columns;
  }

  static boolean hasUniformMicroBatchShape(List<Value> values) {
    if (values.isEmpty() || values.getFirst().kind != ValueKind.MAP) {
      return false;
    }
    List<String> keys = new ArrayList<>();
    for (MapEntry entry : values.getFirst().map) {
      keys.add(entry.key);
    }
    for (int i = 1; i < values.size(); i++) {
      Value value = values.get(i);
      if (value.kind != ValueKind.MAP || value.map.size() != keys.size()) {
        return false;
      }
      for (int j = 0; j < keys.size(); j++) {
        if (!value.map.get(j).key.equals(keys.get(j))) {
          return false;
        }
      }
    }
    return true;
  }

  static boolean shouldRegisterShape(List<String> keys, long observedCount) {
    return !keys.isEmpty() && observedCount >= 2L;
  }

  static boolean supportsStatePatch(Message base, Message current) {
    if (base == null) {
      return false;
    }
    return base.kind == current.kind
        && (base.kind == MessageKind.MAP
            || base.kind == MessageKind.SCHEMA_OBJECT
            || base.kind == MessageKind.SHAPED_OBJECT
            || base.kind == MessageKind.ARRAY);
  }

  static int encodedSize(Message message) {
    return estimateMessageSize(message);
  }

  static Value typedVectorToValue(TypedVector vector) {
    List<Value> out = new ArrayList<>();
    switch (vector.elementType) {
      case BOOL -> {
        for (boolean v : vector.data.bools) {
          out.add(Value.ofBool(v));
        }
      }
      case I64 -> {
        for (long v : vector.data.i64s) {
          out.add(Value.ofI64(v));
        }
      }
      case U64 -> {
        for (long v : vector.data.u64s) {
          out.add(Value.ofU64(v));
        }
      }
      case F64 -> {
        for (double v : vector.data.f64s) {
          out.add(Value.ofF64(v));
        }
      }
      case STRING -> {
        for (String v : vector.data.strings) {
          out.add(Value.ofString(v));
        }
      }
      default -> {}
    }
    return Value.ofArray(out);
  }

  static List<MapEntry> entriesToMap(List<MessageMapEntry> entries, SessionState state) {
    List<MapEntry> out = new ArrayList<>();
    for (MessageMapEntry entry : entries) {
      String key = keyRefString(entry.key, state);
      out.add(new MapEntry(key, cloneValue(entry.value)));
      if (state.keyTable.getId(key) == null) {
        state.keyTable.register(key);
      }
    }
    return out;
  }

  static String keyRefString(KeyRef key, SessionState state) {
    if (key.isId) {
      String value = state.keyTable.getValue(key.id);
      return value == null ? "" : value;
    }
    return key.literal;
  }

  static String keyRefFieldIdentity(KeyRef key, SessionState state) {
    String value = keyRefString(key, state);
    return value.isEmpty() ? null : value;
  }

  static List<MapEntry> shapeValuesToMap(
      List<String> keys, List<Boolean> presence, boolean hasPresence, List<Value> values) {
    List<MapEntry> out = new ArrayList<>();
    int idx = 0;
    for (int i = 0; i < keys.size(); i++) {
      if (hasPresence && i < presence.size() && !presence.get(i)) {
        continue;
      }
      if (idx >= values.size()) {
        break;
      }
      out.add(new MapEntry(keys.get(i), cloneValue(values.get(idx))));
      idx++;
    }
    return out;
  }

  static List<Column> rowsToColumns(List<List<Value>> rows) {
    if (rows.isEmpty()) {
      return new ArrayList<>();
    }
    int width = 0;
    for (List<Value> row : rows) {
      width = Math.max(width, row.size());
    }
    List<List<Value>> columnValues = new ArrayList<>();
    List<List<Boolean>> columnPresence = new ArrayList<>();
    for (int i = 0; i < width; i++) {
      columnValues.add(new ArrayList<>());
      columnPresence.add(new ArrayList<>());
    }
    for (List<Value> row : rows) {
      for (int col = 0; col < width; col++) {
        Value value = col < row.size() ? cloneValue(row.get(col)) : Value.ofNull();
        columnValues.get(col).add(value);
        columnPresence.get(col).add(value.kind != ValueKind.NULL);
      }
    }
    List<Column> out = new ArrayList<>();
    for (int col = 0; col < width; col++) {
      ColumnNullStrategyResult nullPlan =
          columnNullStrategy(columnValues.get(col), columnPresence.get(col));
      CodecAndValues codecAndValues = inferColumnCodecAndValues(stripNulls(columnValues.get(col)));
      Column column = new Column();
      column.fieldId = col;
      column.nullStrategy = nullPlan.nullStrategy;
      column.presence = nullPlan.presence == null ? new ArrayList<>() : nullPlan.presence;
      column.hasPresence = nullPlan.hasPresence;
      column.codec = codecAndValues.codec;
      column.values = codecAndValues.values;
      out.add(column);
    }
    return out;
  }

  private record CodecAndValues(VectorCodec codec, TypedVectorData values) {}

  static CodecAndValues inferColumnCodecAndValues(List<Value> values) {
    if (values.isEmpty()) {
      TypedVectorData data = new TypedVectorData();
      data.kind = ElementType.VALUE;
      return new CodecAndValues(VectorCodec.PLAIN, data);
    }
    boolean allI64 = true;
    boolean allU64 = true;
    boolean allF64 = true;
    boolean allBool = true;
    boolean allString = true;
    for (Value value : values) {
      allI64 &= value.kind == ValueKind.I64;
      allU64 &= value.kind == ValueKind.U64;
      allF64 &= value.kind == ValueKind.F64;
      allBool &= value.kind == ValueKind.BOOL;
      allString &= value.kind == ValueKind.STRING;
    }
    if (allI64) {
      List<Long> data = new ArrayList<>();
      for (Value value : values) {
        data.add(value.i64);
      }
      TypedVectorData tvd = new TypedVectorData();
      tvd.kind = ElementType.I64;
      tvd.i64s = data;
      return new CodecAndValues(selectIntegerCodec(data), tvd);
    }
    if (allU64) {
      List<Long> data = new ArrayList<>();
      for (Value value : values) {
        data.add(value.u64);
      }
      TypedVectorData tvd = new TypedVectorData();
      tvd.kind = ElementType.U64;
      tvd.u64s = data;
      return new CodecAndValues(selectU64Codec(data), tvd);
    }
    if (allF64) {
      List<Double> data = new ArrayList<>();
      for (Value value : values) {
        data.add(value.f64);
      }
      TypedVectorData tvd = new TypedVectorData();
      tvd.kind = ElementType.F64;
      tvd.f64s = data;
      return new CodecAndValues(selectFloatCodec(data), tvd);
    }
    if (allBool) {
      List<Boolean> data = new ArrayList<>();
      for (Value value : values) {
        data.add(value.bool);
      }
      TypedVectorData tvd = new TypedVectorData();
      tvd.kind = ElementType.BOOL;
      tvd.bools = data;
      return new CodecAndValues(VectorCodec.DIRECT_BITPACK, tvd);
    }
    if (allString) {
      List<String> data = new ArrayList<>();
      for (Value value : values) {
        data.add(value.str);
      }
      TypedVectorData tvd = new TypedVectorData();
      tvd.kind = ElementType.STRING;
      tvd.strings = data;
      return new CodecAndValues(selectStringCodec(data), tvd);
    }
    TypedVectorData tvd = new TypedVectorData();
    tvd.kind = ElementType.VALUE;
    for (Value value : values) {
      tvd.values.add(cloneValue(value));
    }
    return new CodecAndValues(VectorCodec.PLAIN, tvd);
  }

  static VectorCodec selectIntegerCodec(List<Long> values) {
    if (values.size() < 4) {
      return VectorCodec.PLAIN;
    }
    List<Long> deltaVals = deltas(values);
    List<Long> dd = deltas(deltaVals);
    int nonZeroDd = 0;
    for (int i = 1; i < dd.size(); i++) {
      if (dd.get(i) != 0) {
        nonZeroDd++;
      }
    }
    double nonZeroRatio = dd.size() > 1 ? (double) nonZeroDd / (double) (dd.size() - 1) : 0.0;
    long deltaMin = minSigned(deltaVals);
    long deltaMax = maxSigned(deltaVals);
    int deltaRangeBits = bitWidthSigned(deltaMin, deltaMax);
    if (values.size() >= 8 && (nonZeroRatio <= 0.25 || deltaRangeBits <= 2)) {
      return VectorCodec.DELTA_DELTA_BITPACK;
    }
    RunStats stats = runStats(values);
    if (stats.repeatedRatio >= 0.5 && stats.avgRun >= 3.0) {
      return VectorCodec.RLE;
    }
    int plainBits = 64;
    long minValue = minSigned(values);
    long maxValue = maxSigned(values);
    int rangeBits = bitWidthSigned(minValue, maxValue);
    if (rangeBits <= plainBits - 4) {
      return VectorCodec.FOR_BITPACK;
    }
    boolean monotonic = true;
    for (int i = 1; i < values.size(); i++) {
      if (values.get(i) < values.get(i - 1)) {
        monotonic = false;
        break;
      }
    }
    if (values.size() >= 8 && monotonic && deltaRangeBits <= rangeBits - 3) {
      return VectorCodec.DELTA_FOR_BITPACK;
    }
    int maxAbsDeltaBits = 1;
    for (long value : deltaVals) {
      maxAbsDeltaBits = Math.max(maxAbsDeltaBits, bitWidthU64(abs64(value)));
    }
    if (maxAbsDeltaBits <= plainBits - 3) {
      return VectorCodec.DELTA_BITPACK;
    }
    int maxBitWidth = 1;
    for (long value : values) {
      maxBitWidth = Math.max(maxBitWidth, bitWidthU64(abs64(value)));
    }
    if (values.size() >= 8 && maxBitWidth <= 16 && !monotonic) {
      return VectorCodec.SIMPLE8B;
    }
    if (maxBitWidth < 64) {
      return VectorCodec.DIRECT_BITPACK;
    }
    return VectorCodec.PLAIN;
  }

  static VectorCodec selectU64Codec(List<Long> values) {
    boolean allSigned = true;
    for (long value : values) {
      if (Long.compareUnsigned(value, Long.MAX_VALUE) > 0) {
        allSigned = false;
        break;
      }
    }
    if (allSigned) {
      VectorCodec chosen = selectIntegerCodec(values);
      if (chosen == VectorCodec.RLE
          || chosen == VectorCodec.FOR_BITPACK
          || chosen == VectorCodec.SIMPLE8B
          || chosen == VectorCodec.DIRECT_BITPACK
          || chosen == VectorCodec.PLAIN) {
        return chosen;
      }
      return VectorCodec.DIRECT_BITPACK;
    }
    if (values.size() < 4) {
      return VectorCodec.DIRECT_BITPACK;
    }
    RunStats stats = runStatsU64(values);
    if (stats.repeatedRatio >= 0.5 && stats.avgRun >= 3.0) {
      return VectorCodec.RLE;
    }
    long minValue = minUnsigned(values);
    long maxValue = maxUnsigned(values);
    int rangeBits = bitWidthU64(maxValue - minValue);
    if (rangeBits <= 60) {
      return VectorCodec.FOR_BITPACK;
    }
    int maxWidth = 1;
    for (long value : values) {
      maxWidth = Math.max(maxWidth, bitWidthU64(value));
    }
    if (values.size() >= 8 && maxWidth <= 16) {
      return VectorCodec.SIMPLE8B;
    }
    if (maxWidth < 64) {
      return VectorCodec.DIRECT_BITPACK;
    }
    return VectorCodec.PLAIN;
  }

  static List<Long> deltas(List<Long> values) {
    List<Long> out = new ArrayList<>();
    for (int i = 0; i < values.size(); i++) {
      long value = values.get(i);
      out.add(i == 0 ? value : value - values.get(i - 1));
    }
    return out;
  }

  private record RunStats(double repeatedRatio, double avgRun) {}

  static RunStats runStats(List<Long> values) {
    if (values.isEmpty()) {
      return new RunStats(0.0, 0.0);
    }
    int runLen = 1;
    List<Integer> runs = new ArrayList<>();
    for (int i = 1; i < values.size(); i++) {
      if (values.get(i).equals(values.get(i - 1))) {
        runLen++;
      } else {
        runs.add(runLen);
        runLen = 1;
      }
    }
    runs.add(runLen);
    int repeatedItems = 0;
    for (int run : runs) {
      if (run > 1) {
        repeatedItems += run;
      }
    }
    double repeatedRatio = (double) repeatedItems / (double) values.size();
    double avgRun = (double) values.size() / (double) runs.size();
    return new RunStats(repeatedRatio, avgRun);
  }

  static RunStats runStatsU64(List<Long> values) {
    return runStats(values);
  }

  static int bitWidthSigned(long minValue, long maxValue) {
    long range = minValue <= maxValue ? maxValue - minValue : minValue - maxValue;
    return bitWidthU64(range);
  }

  static int bitWidthU64(long value) {
    if (value == 0L) {
      return 1;
    }
    return 64 - Long.numberOfLeadingZeros(value);
  }

  static long abs64(long value) {
    return value < 0 ? -value : value;
  }

  static VectorCodec selectFloatCodec(List<Double> values) {
    if (values.size() < 4) {
      return VectorCodec.PLAIN;
    }
    long prev = Double.doubleToRawLongBits(values.getFirst());
    int changes = 0;
    for (int i = 1; i < values.size(); i++) {
      long cur = Double.doubleToRawLongBits(values.get(i));
      if (cur != prev) {
        changes++;
      }
      prev = cur;
    }
    return changes * 2 <= values.size() ? VectorCodec.XOR_FLOAT : VectorCodec.PLAIN;
  }

  static VectorCodec selectStringCodec(List<String> values) {
    if (values.isEmpty()) {
      return VectorCodec.PLAIN;
    }
    HashSet<String> uniq = new HashSet<>(values);
    if (uniq.size() * 2 <= values.size()) {
      return VectorCodec.DICTIONARY;
    }
    int prefixGain = 0;
    String prev = "";
    for (String value : values) {
      prefixGain +=
          commonPrefixLen(
              prev.getBytes(StandardCharsets.UTF_8), value.getBytes(StandardCharsets.UTF_8));
      prev = value;
    }
    if (prefixGain > values.size() * 2) {
      return VectorCodec.PREFIX_DELTA;
    }
    return VectorCodec.PLAIN;
  }

  static void writeSmallestU64(long value, List<Byte> out) {
    if (Long.compareUnsigned(value, 0xFFL) <= 0) {
      out.add((byte) 1);
      out.add((byte) (value & 0xFF));
    } else if (Long.compareUnsigned(value, 0xFFFFL) <= 0) {
      out.add((byte) 2);
      out.add((byte) (value & 0xFF));
      out.add((byte) ((value >>> 8) & 0xFF));
    } else if (Long.compareUnsigned(value, 0xFFFFFFFFL) <= 0) {
      out.add((byte) 4);
      out.add((byte) (value & 0xFF));
      out.add((byte) ((value >>> 8) & 0xFF));
      out.add((byte) ((value >>> 16) & 0xFF));
      out.add((byte) ((value >>> 24) & 0xFF));
    } else {
      out.add((byte) 8);
      for (byte b : toLittleEndianU64(value)) {
        out.add(b);
      }
    }
  }

  static long readSmallestU64(Wire.Reader reader) {
    int size = Byte.toUnsignedInt(reader.readU8());
    return switch (size) {
      case 1 -> Byte.toUnsignedLong(reader.readU8());
      case 2 -> {
        byte[] b = reader.readExact(2);
        yield Byte.toUnsignedLong(b[0]) | (Byte.toUnsignedLong(b[1]) << 8);
      }
      case 4 -> {
        byte[] b = reader.readExact(4);
        yield Byte.toUnsignedLong(b[0])
            | (Byte.toUnsignedLong(b[1]) << 8)
            | (Byte.toUnsignedLong(b[2]) << 16)
            | (Byte.toUnsignedLong(b[3]) << 24);
      }
      case 8 -> Wire.readU64LE(reader);
      default -> throw Errors.invalidData("smallest u64 size");
    };
  }

  static byte[] rleEncodeBytes(byte[] inputData) {
    if (inputData.length == 0) {
      return new byte[0];
    }
    List<Byte> out = new ArrayList<>();
    int i = 0;
    while (i < inputData.length) {
      int j = i + 1;
      while (j < inputData.length && inputData[j] == inputData[i] && j - i < 255) {
        j++;
      }
      out.add((byte) (j - i));
      out.add(inputData[i]);
      i = j;
    }
    return toByteArray(out);
  }

  static byte[] rleDecodeBytes(byte[] inputData) {
    List<Byte> out = new ArrayList<>();
    int i = 0;
    while (i < inputData.length) {
      if (i + 1 >= inputData.length) {
        throw Errors.invalidData("rle payload");
      }
      int run = Byte.toUnsignedInt(inputData[i]);
      byte b = inputData[i + 1];
      for (int j = 0; j < run; j++) {
        out.add(b);
      }
      i += 2;
    }
    return toByteArray(out);
  }

  static byte[] controlBitpackEncodeBytes(byte[] inputData) {
    return inputData.clone();
  }

  static byte[] controlBitpackDecodeBytes(byte[] inputData) {
    return inputData.clone();
  }

  static byte[] controlHuffmanEncodeBytes(byte[] inputData) {
    return inputData.clone();
  }

  static byte[] controlHuffmanDecodeBytes(byte[] inputData) {
    return inputData.clone();
  }

  static byte[] controlFseEncodeBytes(byte[] inputData) {
    return inputData.clone();
  }

  static byte[] controlFseDecodeBytes(byte[] inputData) {
    return inputData.clone();
  }

  static int commonPrefixLen(byte[] a, byte[] b) {
    int n = Math.min(a.length, b.length);
    for (int i = 0; i < n; i++) {
      if (a[i] != b[i]) {
        return i;
      }
    }
    return n;
  }

  static TemplateDescriptor templateDescriptorFromColumns(long templateId, List<Column> columns) {
    TemplateDescriptor descriptor = new TemplateDescriptor();
    descriptor.templateId = templateId;
    for (Column column : columns) {
      descriptor.fieldIds.add(column.fieldId);
      descriptor.nullStrategies.add(column.nullStrategy);
      descriptor.codecs.add(column.codec);
    }
    return descriptor;
  }

  static Long findTemplateId(Map<Long, TemplateDescriptor> templates, List<Column> columns) {
    List<Long> keys = new ArrayList<>(templates.keySet());
    keys.sort(Long::compareUnsigned);
    for (Long key : keys) {
      TemplateDescriptor descriptor = templates.get(key);
      if (descriptor.fieldIds.size() != columns.size()) {
        continue;
      }
      boolean match = true;
      for (int i = 0; i < columns.size(); i++) {
        if (descriptor.fieldIds.get(i) != columns.get(i).fieldId
            || descriptor.nullStrategies.get(i) != columns.get(i).nullStrategy) {
          match = false;
          break;
        }
      }
      if (match) {
        return key;
      }
    }
    return null;
  }

  record DiffTemplateResult(List<Boolean> mask, List<Column> changed) {}

  static DiffTemplateResult diffTemplateColumns(List<Column> previous, List<Column> current) {
    List<Boolean> mask = new ArrayList<>();
    List<Column> changed = new ArrayList<>();
    for (int i = 0; i < current.size(); i++) {
      Column column = current.get(i);
      if (i >= previous.size()
          || estimateColumnSize(previous.get(i)) != estimateColumnSize(column)) {
        mask.add(true);
        changed.add(column);
      } else {
        mask.add(false);
      }
    }
    return new DiffTemplateResult(mask, changed);
  }

  static List<Column> mergeTemplateColumns(
      List<Column> previous, List<Boolean> changedMask, List<Column> changed) {
    List<Column> out = new ArrayList<>();
    int idx = 0;
    for (int i = 0; i < changedMask.size(); i++) {
      if (changedMask.get(i)) {
        if (idx >= changed.size()) {
          throw Errors.invalidData("template changed column count mismatch");
        }
        out.add(changed.get(idx));
        idx++;
      } else {
        if (i >= previous.size()) {
          throw Errors.invalidData("template reference out of range");
        }
        out.add(previous.get(i));
      }
    }
    return out;
  }

  record DiffMessageResult(List<PatchOperation> operations, int literalsCount) {}

  static DiffMessageResult diffMessage(Message previous, Message current) {
    List<Value> a = messageFields(previous);
    List<Value> b = messageFields(current);
    int n = Math.max(a.size(), b.size());
    List<PatchOperation> ops = new ArrayList<>();
    for (int i = 0; i < n; i++) {
      PatchOperation operation = new PatchOperation();
      operation.fieldId = i;
      if (i < a.size() && i < b.size()) {
        if (equal(a.get(i), b.get(i))) {
          operation.opcode = PatchOpcode.KEEP;
        } else {
          operation.opcode = PatchOpcode.REPLACE_SCALAR;
          operation.value = cloneValue(b.get(i));
        }
      } else if (i < b.size()) {
        operation.opcode = PatchOpcode.INSERT_FIELD;
        operation.value = cloneValue(b.get(i));
      } else {
        operation.opcode = PatchOpcode.DELETE_FIELD;
      }
      ops.add(operation);
    }
    return new DiffMessageResult(ops, 0);
  }

  static List<Value> messageFields(Message message) {
    return switch (message.kind) {
      case ARRAY -> cloneValues(message.array);
      case MAP -> {
        List<Value> out = new ArrayList<>();
        for (MessageMapEntry entry : message.map) {
          out.add(cloneValue(entry.value));
        }
        yield out;
      }
      case SHAPED_OBJECT -> cloneValues(message.shapedObject.values);
      case SCHEMA_OBJECT -> cloneValues(message.schemaObject.fields);
      default -> new ArrayList<>();
    };
  }

  static Message rebuildMessageLike(Message base, List<Value> fields) {
    Message message = new Message();
    switch (base.kind) {
      case ARRAY -> {
        message.kind = MessageKind.ARRAY;
        message.array = cloneValues(fields);
        return message;
      }
      case MAP -> {
        message.kind = MessageKind.MAP;
        for (int i = 0; i < fields.size(); i++) {
          if (i >= base.map.size()) {
            throw Errors.invalidData("patch map shape mismatch");
          }
          message.map.add(new MessageMapEntry(base.map.get(i).key, cloneValue(fields.get(i))));
        }
        return message;
      }
      case SHAPED_OBJECT -> {
        message.kind = MessageKind.SHAPED_OBJECT;
        ShapedObjectMessage shaped = new ShapedObjectMessage();
        shaped.shapeId = base.shapedObject.shapeId;
        shaped.presence = new ArrayList<>(base.shapedObject.presence);
        shaped.hasPresence = base.shapedObject.hasPresence;
        shaped.values = cloneValues(fields);
        message.shapedObject = shaped;
        return message;
      }
      case SCHEMA_OBJECT -> {
        message.kind = MessageKind.SCHEMA_OBJECT;
        SchemaObjectMessage schemaObject = new SchemaObjectMessage();
        schemaObject.schemaId = base.schemaObject.schemaId;
        schemaObject.presence = new ArrayList<>(base.schemaObject.presence);
        schemaObject.hasPresence = base.schemaObject.hasPresence;
        schemaObject.fields = cloneValues(fields);
        message.schemaObject = schemaObject;
        return message;
      }
      default ->
          throw Errors.invalidData("state patch reconstruction unsupported for this message kind");
    }
  }

  static int estimateMessageSize(Message message) {
    return switch (message.kind) {
      case SCALAR -> 1 + estimateValueSize(message.scalar);
      case ARRAY -> {
        int size = 1 + varuintSize(message.array.size());
        for (Value value : message.array) {
          size += estimateValueSize(value);
        }
        yield size;
      }
      case MAP -> {
        int size = 1 + varuintSize(message.map.size());
        for (MessageMapEntry entry : message.map) {
          size += encodedKeyRefSize(entry.key) + estimateValueSize(entry.value);
        }
        yield size;
      }
      case STATE_PATCH -> {
        StatePatchMessage patch = message.statePatch;
        int total = 1 + 2 + varuintSize(patch.operations.size());
        for (PatchOperation operation : patch.operations) {
          total += varuintSize(operation.fieldId) + 2;
          if (operation.value != null) {
            total += estimateValueSize(operation.value);
          }
        }
        yield total;
      }
      default -> 16;
    };
  }

  static int estimateColumnSize(Column column) {
    int size = varuintSize(column.fieldId) + 4;
    return switch (column.values.kind) {
      case BOOL -> size + column.values.bools.size() / 8 + 2;
      case I64 -> size + column.values.i64s.size() * 4;
      case U64 -> size + column.values.u64s.size() * 4;
      case F64 -> size + column.values.f64s.size() * 8;
      case STRING -> {
        int total = size;
        for (String value : column.values.strings) {
          total += encodedStringSize(value);
        }
        yield total;
      }
      default -> size;
    };
  }

  static int estimateValueSize(Value value) {
    return switch (value.kind) {
      case NULL, BOOL -> 1;
      case I64 -> 2 + smallestU64Size(Wire.encodeZigzag(value.i64));
      case U64 -> 2 + smallestU64Size(value.u64);
      case F64 -> 9;
      case STRING -> 2 + encodedStringSize(value.str);
      case BINARY -> 1 + encodedBytesSize(value.bin.length);
      case ARRAY -> {
        int size = 1 + varuintSize(value.arr.size());
        for (Value item : value.arr) {
          size += estimateValueSize(item);
        }
        yield size;
      }
      case MAP -> {
        int size = 1 + varuintSize(value.map.size());
        for (MapEntry entry : value.map) {
          size += encodedStringSize(entry.key) + estimateValueSize(entry.value);
        }
        yield size;
      }
    };
  }

  static int encodedBytesSize(int length) {
    return varuintSize(length) + length;
  }

  static int encodedStringSize(String value) {
    return encodedBytesSize(value.getBytes(StandardCharsets.UTF_8).length);
  }

  static int encodedKeyRefSize(KeyRef key) {
    if (key.isId) {
      return 1 + varuintSize(key.id);
    }
    return encodedStringSize(key.literal);
  }

  static int varuintSize(long value) {
    int sz = 1;
    long v = value;
    while (Long.compareUnsigned(v, 0x80L) >= 0) {
      v >>>= 7;
      sz++;
    }
    return sz;
  }

  static int smallestU64Size(long value) {
    if (Long.compareUnsigned(value, 0xFFL) <= 0) {
      return 1;
    }
    if (Long.compareUnsigned(value, 0xFFFFL) <= 0) {
      return 2;
    }
    if (Long.compareUnsigned(value, 0xFFFFFFFFL) <= 0) {
      return 4;
    }
    return 8;
  }

  static Value cloneValue(Value value) {
    return value == null ? null : value.cloneValue();
  }

  static List<Value> cloneValues(List<Value> values) {
    List<Value> out = new ArrayList<>();
    for (Value value : values) {
      out.add(cloneValue(value));
    }
    return out;
  }

  static TypedVectorData cloneTypedVectorData(TypedVectorData data) {
    TypedVectorData out = new TypedVectorData();
    out.kind = data.kind;
    out.bools = new ArrayList<>(data.bools);
    out.i64s = new ArrayList<>(data.i64s);
    out.u64s = new ArrayList<>(data.u64s);
    out.f64s = new ArrayList<>(data.f64s);
    out.strings = new ArrayList<>(data.strings);
    for (byte[] bytes : data.binary) {
      out.binary.add(bytes.clone());
    }
    out.values = cloneValues(data.values);
    return out;
  }

  static Column cloneColumn(Column column) {
    Column out = new Column();
    out.fieldId = column.fieldId;
    out.nullStrategy = column.nullStrategy;
    out.presence = new ArrayList<>(column.presence);
    out.hasPresence = column.hasPresence;
    out.codec = column.codec;
    out.dictionaryId = column.dictionaryId;
    out.values = cloneTypedVectorData(column.values);
    return out;
  }

  static Message cloneMessage(Message message) {
    Message out = new Message();
    out.kind = message.kind;
    out.scalar = cloneValue(message.scalar);
    out.array = cloneValues(message.array);
    for (MessageMapEntry entry : message.map) {
      out.map.add(new MessageMapEntry(entry.key, cloneValue(entry.value)));
    }
    if (message.shapedObject != null) {
      ShapedObjectMessage shaped = new ShapedObjectMessage();
      shaped.shapeId = message.shapedObject.shapeId;
      shaped.presence = new ArrayList<>(message.shapedObject.presence);
      shaped.hasPresence = message.shapedObject.hasPresence;
      shaped.values = cloneValues(message.shapedObject.values);
      out.shapedObject = shaped;
    }
    if (message.schemaObject != null) {
      SchemaObjectMessage schemaObject = new SchemaObjectMessage();
      schemaObject.schemaId = message.schemaObject.schemaId;
      schemaObject.presence = new ArrayList<>(message.schemaObject.presence);
      schemaObject.hasPresence = message.schemaObject.hasPresence;
      schemaObject.fields = cloneValues(message.schemaObject.fields);
      out.schemaObject = schemaObject;
    }
    if (message.typedVector != null) {
      TypedVector vector = new TypedVector();
      vector.elementType = message.typedVector.elementType;
      vector.codec = message.typedVector.codec;
      vector.data = cloneTypedVectorData(message.typedVector.data);
      out.typedVector = vector;
    }
    if (message.rowBatch != null) {
      RowBatchMessage batch = new RowBatchMessage();
      for (List<Value> row : message.rowBatch.rows) {
        batch.rows.add(cloneValues(row));
      }
      out.rowBatch = batch;
    }
    if (message.columnBatch != null) {
      ColumnBatchMessage batch = new ColumnBatchMessage();
      batch.count = message.columnBatch.count;
      for (Column column : message.columnBatch.columns) {
        batch.columns.add(cloneColumn(column));
      }
      out.columnBatch = batch;
    }
    if (message.control != null) {
      ControlMessage control = new ControlMessage();
      control.opcode = message.control.opcode;
      control.registerKeys = new ArrayList<>(message.control.registerKeys);
      if (message.control.registerShape != null) {
        RegisterShapeControl shape = new RegisterShapeControl();
        shape.shapeId = message.control.registerShape.shapeId;
        shape.keys = new ArrayList<>(message.control.registerShape.keys);
        control.registerShape = shape;
      }
      control.registerStrings = new ArrayList<>(message.control.registerStrings);
      if (message.control.promoteStringFieldToEnum != null) {
        PromoteEnumControl promote = new PromoteEnumControl();
        promote.fieldIdentity = message.control.promoteStringFieldToEnum.fieldIdentity;
        promote.values = new ArrayList<>(message.control.promoteStringFieldToEnum.values);
        control.promoteStringFieldToEnum = promote;
      }
      control.resetTables = message.control.resetTables;
      control.resetState = message.control.resetState;
      out.control = control;
    }
    if (message.ext != null) {
      ExtMessage ext = new ExtMessage();
      ext.extType = message.ext.extType;
      ext.payload = message.ext.payload.clone();
      out.ext = ext;
    }
    if (message.statePatch != null) {
      StatePatchMessage patch = new StatePatchMessage();
      patch.baseRef = message.statePatch.baseRef;
      for (PatchOperation operation : message.statePatch.operations) {
        PatchOperation copy = new PatchOperation();
        copy.fieldId = operation.fieldId;
        copy.opcode = operation.opcode;
        copy.value = cloneValue(operation.value);
        patch.operations.add(copy);
      }
      patch.literals = cloneValues(message.statePatch.literals);
      out.statePatch = patch;
    }
    if (message.templateBatch != null) {
      TemplateBatchMessage batch = new TemplateBatchMessage();
      batch.templateId = message.templateBatch.templateId;
      batch.count = message.templateBatch.count;
      batch.changedColumnMask = new ArrayList<>(message.templateBatch.changedColumnMask);
      for (Column column : message.templateBatch.columns) {
        batch.columns.add(cloneColumn(column));
      }
      out.templateBatch = batch;
    }
    if (message.controlStream != null) {
      ControlStreamMessage stream = new ControlStreamMessage();
      stream.codec = message.controlStream.codec;
      stream.payload = message.controlStream.payload.clone();
      out.controlStream = stream;
    }
    if (message.baseSnapshot != null) {
      BaseSnapshotMessage snapshot = new BaseSnapshotMessage();
      snapshot.baseId = message.baseSnapshot.baseId;
      snapshot.schemaOrShapeRef = message.baseSnapshot.schemaOrShapeRef;
      snapshot.payload = cloneMessage(message.baseSnapshot.payload);
      out.baseSnapshot = snapshot;
    }
    return out;
  }

  static boolean equal(Value a, Value b) {
    if (a.kind != b.kind) {
      return false;
    }
    return switch (a.kind) {
      case NULL -> true;
      case BOOL -> a.bool == b.bool;
      case I64 -> a.i64 == b.i64;
      case U64 -> a.u64 == b.u64;
      case F64 -> Double.compare(a.f64, b.f64) == 0;
      case STRING -> a.str.equals(b.str);
      case BINARY -> java.util.Arrays.equals(a.bin, b.bin);
      case ARRAY -> {
        if (a.arr.size() != b.arr.size()) {
          yield false;
        }
        boolean same = true;
        for (int i = 0; i < a.arr.size(); i++) {
          if (!equal(a.arr.get(i), b.arr.get(i))) {
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
          MapEntry ea = a.map.get(i);
          MapEntry eb = b.map.get(i);
          if (!ea.key.equals(eb.key) || !equal(ea.value, eb.value)) {
            same = false;
            break;
          }
        }
        yield same;
      }
    };
  }

  private static long minSigned(List<Long> values) {
    long out = values.getFirst();
    for (int i = 1; i < values.size(); i++) {
      out = Math.min(out, values.get(i));
    }
    return out;
  }

  private static long maxSigned(List<Long> values) {
    long out = values.getFirst();
    for (int i = 1; i < values.size(); i++) {
      out = Math.max(out, values.get(i));
    }
    return out;
  }

  private static long minUnsigned(List<Long> values) {
    long out = values.getFirst();
    for (int i = 1; i < values.size(); i++) {
      if (Long.compareUnsigned(values.get(i), out) < 0) {
        out = values.get(i);
      }
    }
    return out;
  }

  private static long maxUnsigned(List<Long> values) {
    long out = values.getFirst();
    for (int i = 1; i < values.size(); i++) {
      if (Long.compareUnsigned(values.get(i), out) > 0) {
        out = values.get(i);
      }
    }
    return out;
  }

  private static byte[] toLittleEndianU64(long value) {
    return new byte[] {
      (byte) value,
      (byte) (value >>> 8),
      (byte) (value >>> 16),
      (byte) (value >>> 24),
      (byte) (value >>> 32),
      (byte) (value >>> 40),
      (byte) (value >>> 48),
      (byte) (value >>> 56),
    };
  }

  static byte[] toByteArray(List<Byte> bytes) {
    byte[] out = new byte[bytes.size()];
    for (int i = 0; i < bytes.size(); i++) {
      out[i] = bytes.get(i);
    }
    return out;
  }
}
