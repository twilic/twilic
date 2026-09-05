import 'dart:typed_data';

import 'model.dart';

enum UnknownReferencePolicy { failFast, statelessRetry }

enum DictionaryFallback { failFast, statelessRetry }

class DictionaryProfile {
  DictionaryProfile({
    required this.version,
    required this.hash,
    required this.expiresAt,
    required this.fallback,
  });
  final int version;
  final int hash;
  final int expiresAt;
  final DictionaryFallback fallback;
}

class SessionOptions {
  SessionOptions({
    this.maxBaseSnapshots = 8,
    this.enableStatePatch = true,
    this.enableTemplateBatch = true,
    this.enableTrainedDictionary = true,
    this.unknownReferencePolicy = UnknownReferencePolicy.failFast,
  });
  final int maxBaseSnapshots;
  final bool enableStatePatch;
  final bool enableTemplateBatch;
  final bool enableTrainedDictionary;
  final UnknownReferencePolicy unknownReferencePolicy;
}

SessionOptions defaultSessionOptions() => SessionOptions();

class InternTable {
  InternTable();
  final Map<String, int> byValue = {};
  final List<String> byId = [];

  (int, bool) getId(String value) {
    final id = byValue[value];
    if (id != null) return (id, true);
    return (0, false);
  }

  (String, bool) getValue(int refId) {
    if (refId >= byId.length) return ('', false);
    return (byId[refId], true);
  }

  int register(String value) {
    final existing = byValue[value];
    if (existing != null) return existing;
    final refId = byId.length;
    byId.add(value);
    byValue[value] = refId;
    return refId;
  }

  void clear() {
    byValue.clear();
    byId.clear();
  }
}

String shapeKey(List<String> keys) => keys.join('\x00');

class ShapeTable {
  ShapeTable();
  final Map<String, int> byKeys = {};
  final Map<int, List<String>> byId = {};
  final Map<String, int> observations = {};
  int nextId = 0;

  (int, bool) getId(List<String> keys) {
    final sk = shapeKey(keys);
    final refId = byKeys[sk];
    if (refId != null) return (refId, true);
    return (0, false);
  }

  (List<String>?, bool) getKeys(int refId) {
    final keys = byId[refId];
    if (keys != null) return (keys, true);
    return (null, false);
  }

  int register(List<String> keys) {
    final sk = shapeKey(keys);
    final existing = byKeys[sk];
    if (existing != null) return existing;
    final refId = nextId++;
    byId[refId] = List<String>.from(keys);
    byKeys[sk] = refId;
    return refId;
  }

  int observe(List<String> keys) {
    final sk = shapeKey(keys);
    final count = (observations[sk] ?? 0) + 1;
    observations[sk] = count;
    return count;
  }

  void clear() {
    byKeys.clear();
    byId.clear();
    observations.clear();
    nextId = 0;
  }
}

class BaseSnapshotEntry {
  BaseSnapshotEntry({required this.id, required this.message});
  final int id;
  final Message message;
}

class SessionState {
  SessionState({SessionOptions? options})
      : options = options ?? defaultSessionOptions();
  SessionOptions options;
  InternTable keyTable = InternTable();
  InternTable stringTable = InternTable();
  ShapeTable shapeTable = ShapeTable();
  final Map<String, int> encodeShapeObservations = {};
  List<BaseSnapshotEntry> baseSnapshots = [];
  final Map<int, TemplateDescriptor> templates = {};
  final Map<int, List<Column>> templateColumns = {};
  final Map<String, List<String>> fieldEnums = {};
  final Map<int, Uint8List> dictionaries = {};
  final Map<int, DictionaryProfile> dictionaryProfiles = {};
  final Map<int, Schema> schemas = {};
  int? lastSchemaId;
  Message? previousMessage;
  int? previousMessageSize;
  int nextBaseId = 0;
  int nextTemplateId = 0;
  int nextDictionaryId = 0;
}

SessionState newSessionState() => SessionState();
SessionState newSessionStateWithOptions(SessionOptions options) =>
    SessionState(options: options);

void registerBaseSnapshot(SessionState state, int baseId, Message message) {
  state.baseSnapshots.removeWhere((e) => e.id == baseId);
  state.baseSnapshots.add(BaseSnapshotEntry(id: baseId, message: message));
  while (state.baseSnapshots.length > state.options.maxBaseSnapshots) {
    state.baseSnapshots.removeAt(0);
  }
}

int allocateBaseId(SessionState state) => state.nextBaseId++;

int allocateTemplateId(SessionState state) => state.nextTemplateId++;

(int, Message?) getBaseSnapshot(SessionState state, int baseId) {
  for (final entry in state.baseSnapshots) {
    if (entry.id == baseId) {
      return (baseId, entry.message);
    }
  }
  return (baseId, null);
}
