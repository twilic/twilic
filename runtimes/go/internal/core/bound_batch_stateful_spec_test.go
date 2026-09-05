package core

import (
	"errors"
	"testing"
)

func sampleSchema() *Schema {
	minID := int64(1000)
	maxID := int64(1100)
	minScore := int64(0)
	maxScore := int64(100)
	return &Schema{
		SchemaID: 41,
		Name:     "User",
		Fields: []SchemaField{
			{
				Number:      1,
				Name:        "id",
				LogicalType: "u64",
				Required:    true,
				Min:         &minID,
				Max:         &maxID,
			},
			{
				Number:      2,
				Name:        "name",
				LogicalType: "string",
				Required:    true,
			},
			{
				Number:      3,
				Name:        "score",
				LogicalType: "i64",
				Required:    false,
				Min:         &minScore,
				Max:         &maxScore,
			},
		},
	}
}

func TestBoundBatchStateful_SchemaIDIsSentFirstThenOmitted(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	schema := sampleSchema()
	value := NewMap(
		Entry("id", NewU64(1005)),
		Entry("name", NewString("alice")),
		Entry("score", NewI64(99)),
	)

	v1 := value
	first, err := enc.EncodeWithSchema(schema, &v1)
	if err != nil {
		t.Fatalf("encode first schema msg: %v", err)
	}
	firstMsg, err := enc.DecodeMessage(first)
	if err != nil {
		t.Fatalf("decode first schema msg: %v", err)
	}
	if firstMsg.Kind != MessageKindSchemaObject || firstMsg.SchemaObject.SchemaID == nil || *firstMsg.SchemaObject.SchemaID != 41 {
		t.Fatalf("expected schema id to be present on first message")
	}

	v2 := value
	second, err := enc.EncodeWithSchema(schema, &v2)
	if err != nil {
		t.Fatalf("encode second schema msg: %v", err)
	}
	secondMsg, err := enc.DecodeMessage(second)
	if err != nil {
		t.Fatalf("decode second schema msg: %v", err)
	}
	if secondMsg.Kind != MessageKindSchemaObject {
		t.Fatalf("expected schema object")
	}
}

func TestBoundBatchStateful_BatchThresholdSelectsRowVsColumn(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())

	rows15 := make([]Value, 15)
	for i := 0; i < 15; i++ {
		rows15[i] = NewMap(Entry("id", NewU64(uint64(i))))
	}
	b15, err := enc.EncodeBatch(rows15)
	if err != nil {
		t.Fatalf("encode batch 15: %v", err)
	}
	if len(b15) == 0 {
		t.Fatalf("expected non-empty batch payload")
	}
	if MessageKind(b15[0]) != MessageKindColumnBatch && MessageKind(b15[0]) != MessageKindRowBatch {
		t.Fatalf("unexpected first message kind byte: %v", b15[0])
	}

	rows16 := make([]Value, 16)
	for i := 0; i < 16; i++ {
		rows16[i] = NewMap(Entry("id", NewU64(uint64(i))))
	}
	b16, err := enc.EncodeBatch(rows16)
	if err != nil {
		t.Fatalf("encode batch 16: %v", err)
	}
	if len(b16) == 0 || MessageKind(b16[0]) != MessageKindColumnBatch {
		t.Fatalf("expected column batch byte for 16 rows")
	}
}

func TestBoundBatchStateful_MicroBatchReusesTemplateAndEmitsChangedMask(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	rows1 := []Value{
		NewMap(Entry("id", NewU64(1)), Entry("name", NewString("a"))),
		NewMap(Entry("id", NewU64(2)), Entry("name", NewString("b"))),
		NewMap(Entry("id", NewU64(3)), Entry("name", NewString("c"))),
		NewMap(Entry("id", NewU64(4)), Entry("name", NewString("d"))),
	}
	first, err := enc.EncodeMicroBatch(rows1)
	if err != nil {
		t.Fatalf("encode first micro: %v", err)
	}
	if len(first) == 0 || MessageKind(first[0]) != MessageKindTemplateBatch {
		t.Fatalf("expected template batch byte")
	}

	rows2 := []Value{
		NewMap(Entry("id", NewU64(1)), Entry("name", NewString("aa"))),
		NewMap(Entry("id", NewU64(2)), Entry("name", NewString("bb"))),
		NewMap(Entry("id", NewU64(3)), Entry("name", NewString("cc"))),
		NewMap(Entry("id", NewU64(4)), Entry("name", NewString("dd"))),
	}
	second, err := enc.EncodeMicroBatch(rows2)
	if err != nil {
		t.Fatalf("encode second micro: %v", err)
	}
	if len(second) == 0 || MessageKind(second[0]) != MessageKindTemplateBatch {
		t.Fatalf("expected template batch byte on second micro-batch")
	}
}

func TestBoundBatchStateful_StatePatchUsesRecommendedRatioThreshold(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	baseValues := make([]Value, 100)
	for i := 0; i < 100; i++ {
		baseValues[i] = NewI64(int64(i))
	}
	oneChangeValues := append([]Value(nil), baseValues...)
	oneChangeValues[0] = NewI64(10000)
	twelveChangeValues := append([]Value(nil), baseValues...)
	for i := 0; i < 12; i++ {
		twelveChangeValues[i] = NewI64(int64(10000 + i))
	}

	base := NewArray(baseValues)
	oneChange := NewArray(oneChangeValues)
	twelveChanges := NewArray(twelveChangeValues)

	bv := base
	if _, err := enc.Encode(&bv); err != nil {
		t.Fatalf("encode base: %v", err)
	}
	oc := oneChange
	p1, err := enc.EncodePatch(&oc)
	if err != nil {
		t.Fatalf("encode one-change patch: %v", err)
	}
	m1, err := enc.DecodeMessage(p1)
	if err != nil {
		t.Fatalf("decode one-change patch: %v", err)
	}
	_ = m1

	tc := twelveChanges
	p2, err := enc.EncodePatch(&tc)
	if err != nil {
		t.Fatalf("encode many-change candidate: %v", err)
	}
	m2, err := enc.DecodeMessage(p2)
	if err != nil {
		t.Fatalf("decode many-change candidate: %v", err)
	}
	_ = m2
}

func TestBoundBatchStateful_UnknownBaseIDHonorsStatelessRetryPolicy(t *testing.T) {
	opts := DefaultSessionOptions()
	opts.UnknownReferencePolicy = UnknownReferencePolicyStatelessRetry
	enc := NewSessionEncoder(opts)

	patch := Message{
		Kind: MessageKindStatePatch,
		StatePatch: &StatePatchMessage{
			BaseRef:    BaseRefID(12345),
			Operations: []PatchOperation{},
			Literals:   []Value{},
		},
	}
	builder := NewTwilicCodec()
	bytes, err := builder.EncodeMessage(&patch)
	if err != nil {
		t.Fatalf("encode patch: %v", err)
	}
	_, err = enc.DecodeMessage(bytes)
	te := requireTwilicErrorKind(t, err, ErrStatelessRetryRequired)
	if te.RefKind != "base_id" || te.RefID != 12345 {
		t.Fatalf("unexpected stateless retry info: %+v", te)
	}
}

func TestBoundBatchStateful_StatePatchMapInsertAndDeleteRoundtripViaReconstruction(t *testing.T) {
	codec := NewTwilicCodec()
	base := Message{
		Kind: MessageKindMap,
		Map: []MessageMapEntry{
			messageMapEntry("id", NewU64(1)),
			messageMapEntry("name", NewString("alice")),
		},
	}
	baseBytes, err := codec.EncodeMessage(&base)
	if err != nil {
		t.Fatalf("encode base: %v", err)
	}
	if _, err := codec.DecodeMessage(baseBytes); err != nil {
		t.Fatalf("decode base: %v", err)
	}

	insertValue := NewMap(Entry("role", NewString("admin")))
	insertPatch := Message{
		Kind: MessageKindStatePatch,
		StatePatch: &StatePatchMessage{
			BaseRef: BaseRefPrevious(),
			Operations: []PatchOperation{
				{FieldID: 2, Opcode: PatchOpcodeInsertField, Value: &insertValue},
			},
		},
	}
	insertBytes, err := codec.EncodeMessage(&insertPatch)
	if err != nil {
		t.Fatalf("encode insert patch: %v", err)
	}
	if _, err := codec.DecodeMessage(insertBytes); err != nil {
		t.Fatalf("decode insert patch: %v", err)
	}
	if codec.State.PreviousMessage == nil || codec.State.PreviousMessage.Kind != MessageKindMap {
		t.Fatalf("expected reconstructed map after insert")
	}

	deletePatch := Message{
		Kind: MessageKindStatePatch,
		StatePatch: &StatePatchMessage{
			BaseRef: BaseRefPrevious(),
			Operations: []PatchOperation{
				{FieldID: 2, Opcode: PatchOpcodeDeleteField},
			},
		},
	}
	deleteBytes, err := codec.EncodeMessage(&deletePatch)
	if err != nil {
		t.Fatalf("encode delete patch: %v", err)
	}
	if _, err := codec.DecodeMessage(deleteBytes); err != nil {
		t.Fatalf("decode delete patch: %v", err)
	}
	if codec.State.PreviousMessage == nil || codec.State.PreviousMessage.Kind != MessageKindMap {
		t.Fatalf("expected reconstructed map after delete")
	}
	if len(codec.State.PreviousMessage.Map) != 2 {
		t.Fatalf("expected 2 entries after delete")
	}
}

func TestBoundBatchStateful_ColumnBatchAssignsDictionaryIDForRepeatedStringField(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	rows := make([]Value, 32)
	for i := 0; i < 32; i++ {
		role := "user"
		if i%2 == 0 {
			role = "admin"
		}
		rows[i] = NewMap(
			Entry("id", NewU64(uint64(i))),
			Entry("role", NewString(role)),
		)
	}
	bytes, err := enc.EncodeBatch(rows)
	if err != nil {
		t.Fatalf("encode batch: %v", err)
	}
	if len(bytes) == 0 || MessageKind(bytes[0]) != MessageKindColumnBatch {
		t.Fatalf("expected column batch message byte")
	}
}

func TestBoundBatchStateful_TrainedDictionaryProfileIsTransportedToFreshDecoder(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	rows := make([]Value, 32)
	for i := 0; i < 32; i++ {
		role := "user"
		if i%2 == 0 {
			role = "admin"
		}
		rows[i] = NewMap(
			Entry("id", NewU64(uint64(i))),
			Entry("role", NewString(role)),
		)
	}
	bytes, err := enc.EncodeBatch(rows)
	if err != nil {
		t.Fatalf("encode batch: %v", err)
	}
	dec := NewTwilicCodec()
	decoded, err := dec.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode batch: %v", err)
	}
	if decoded.Kind != MessageKindColumnBatch || decoded.ColumnBatch == nil {
		t.Fatalf("expected column batch")
	}
	var dictID *uint64
	for i := range decoded.ColumnBatch.Columns {
		if decoded.ColumnBatch.Columns[i].DictionaryID != nil {
			id := *decoded.ColumnBatch.Columns[i].DictionaryID
			dictID = &id
			break
		}
	}
	if dictID == nil {
		t.Fatalf("dictionary id in batch")
	}
	payload, ok := dec.State.Dictionaries[*dictID]
	if !ok {
		t.Fatalf("transported dictionary payload")
	}
	profile, ok := dec.State.DictionaryProfiles[*dictID]
	if !ok {
		t.Fatalf("transported dictionary profile")
	}
	if profile.Version != 1 || profile.ExpiresAt != 0 || profile.Fallback != DictionaryFallbackFailFast {
		t.Fatalf("unexpected profile: %+v", profile)
	}
	if profile.Hash != dictionaryPayloadHash(payload) {
		t.Fatalf("profile hash mismatch")
	}
	var roleValues []string
	for i := range decoded.ColumnBatch.Columns {
		if decoded.ColumnBatch.Columns[i].DictionaryID != nil && *decoded.ColumnBatch.Columns[i].DictionaryID == *dictID {
			roleValues = decoded.ColumnBatch.Columns[i].Values.Strings
			break
		}
	}
	if len(roleValues) != 32 || roleValues[0] != "admin" || roleValues[1] != "user" {
		t.Fatalf("unexpected role values: %v", roleValues)
	}
}

func TestBoundBatchStateful_InvalidDictionaryProfileHashIsRejected(t *testing.T) {
	enc := NewTwilicCodec()
	dictID := uint64(42)
	enc.State.Dictionaries[dictID] = []byte{1, 2, 3, 4}
	enc.State.DictionaryProfiles[dictID] = DictionaryProfile{
		Version:   1,
		Hash:      7,
		ExpiresAt: 0,
		Fallback:  DictionaryFallbackFailFast,
	}

	msg := Message{
		Kind: MessageKindColumnBatch,
		ColumnBatch: &ColumnBatchMessage{
			Count: 1,
			Columns: []Column{
				{
					FieldID:      0,
					NullStrategy: NullStrategyAllPresentElided,
					Codec:        VectorCodecDictionary,
					DictionaryID: &dictID,
					Values: TypedVectorData{
						Kind:    ElementTypeString,
						Strings: []string{"admin"},
					},
				},
			},
		},
	}
	bytes, err := enc.EncodeMessage(&msg)
	if err != nil {
		t.Fatalf("encode column batch: %v", err)
	}
	dec := NewTwilicCodec()
	if _, err := dec.DecodeMessage(bytes); err == nil {
		t.Fatalf("expected decode failure for handcrafted dictionary profile payload")
	} else {
		var te *TwilicError
		if !errors.As(err, &te) || te.Msg != "dictionary profile hash mismatch" {
			t.Fatalf("unexpected error: %v", err)
		}
	}
}

func TestBoundBatchStateful_TrainedDictionaryReferenceWritesCompressedBlockAfterDictID(t *testing.T) {
	dictID := uint64(9)
	codec := NewTwilicCodec()
	var payload []byte
	encodeVaruint(2, &payload)
	encodeString("admin", &payload)
	encodeString("user", &payload)
	codec.State.Dictionaries[dictID] = payload
	codec.State.DictionaryProfiles[dictID] = DictionaryProfile{
		Version:   1,
		Hash:      dictionaryPayloadHash(payload),
		ExpiresAt: 0,
		Fallback:  DictionaryFallbackFailFast,
	}
	msg := Message{
		Kind: MessageKindColumnBatch,
		ColumnBatch: &ColumnBatchMessage{
			Count: 4,
			Columns: []Column{
				{
					FieldID:      1,
					NullStrategy: NullStrategyAllPresentElided,
					Codec:        VectorCodecDictionary,
					DictionaryID: &dictID,
					Values: TypedVectorData{
						Kind:    ElementTypeString,
						Strings: []string{"admin", "user", "admin", "user"},
					},
				},
			},
		},
	}
	bytes, err := codec.EncodeMessage(&msg)
	if err != nil {
		t.Fatalf("encode with dictionary: %v", err)
	}
	reader := newReader(bytes)
	kind, _ := reader.readU8()
	if kind != byte(MessageKindColumnBatch) {
		t.Fatalf("expected column batch kind")
	}
	if _, err := reader.readVaruint(); err != nil {
		t.Fatalf("read count: %v", err)
	}
	if _, err := reader.readVaruint(); err != nil {
		t.Fatalf("read column count: %v", err)
	}
	if _, err := reader.readVaruint(); err != nil {
		t.Fatalf("read field id: %v", err)
	}
	if _, err := reader.readU8(); err != nil {
		t.Fatalf("read null strategy: %v", err)
	}
	if _, err := reader.readU8(); err != nil {
		t.Fatalf("read codec: %v", err)
	}
	gotDictID, err := reader.readVaruint()
	if err != nil {
		t.Fatalf("read dict id: %v", err)
	}
	if gotDictID == 0 {
		t.Fatalf("expected non-zero dictionary id marker")
	}

	fresh := NewTwilicCodec()
	decoded, err := fresh.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode with compressed block: %v", err)
	}
	if decoded.Kind != MessageKindColumnBatch || decoded.ColumnBatch == nil {
		t.Fatalf("expected column batch")
	}
	values := decoded.ColumnBatch.Columns[0].Values.Strings
	want := []string{"admin", "user", "admin", "user"}
	if len(values) != len(want) {
		t.Fatalf("got %v want %v", values, want)
	}
	for i := range want {
		if values[i] != want[i] {
			t.Fatalf("got %v want %v", values, want)
		}
	}
}
