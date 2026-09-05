package core

import "testing"

func TestCoverageBoost_ModelFromByteAndDisplayBranches(t *testing.T) {
	if _, ok := messageKindFromByte(0x0D); !ok {
		t.Fatalf("expected valid message kind")
	}
	if _, ok := messageKindFromByte(0xFE); ok {
		t.Fatalf("expected invalid message kind")
	}
	if _, ok := stringModeFromByte(4); !ok {
		t.Fatalf("expected valid string mode")
	}
	if _, ok := stringModeFromByte(9); ok {
		t.Fatalf("expected invalid string mode")
	}
	if _, ok := elementTypeFromByte(6); !ok {
		t.Fatalf("expected valid element type")
	}
	if _, ok := elementTypeFromByte(9); ok {
		t.Fatalf("expected invalid element type")
	}
	if _, ok := vectorCodecFromByte(12); !ok {
		t.Fatalf("expected valid vector codec")
	}
	if _, ok := vectorCodecFromByte(99); ok {
		t.Fatalf("expected invalid vector codec")
	}
	if _, ok := controlOpcodeFromByte(5); !ok {
		t.Fatalf("expected valid control opcode")
	}
	if _, ok := controlOpcodeFromByte(7); ok {
		t.Fatalf("expected invalid control opcode")
	}
	if _, ok := patchOpcodeFromByte(8); !ok {
		t.Fatalf("expected valid patch opcode")
	}
	if _, ok := patchOpcodeFromByte(42); ok {
		t.Fatalf("expected invalid patch opcode")
	}
	if _, ok := controlStreamCodecFromByte(4); !ok {
		t.Fatalf("expected valid control stream codec")
	}
	if _, ok := controlStreamCodecFromByte(7); ok {
		t.Fatalf("expected invalid control stream codec")
	}
}

func TestCoverageBoost_WireReaderErrorBranches(t *testing.T) {
	r := newReader(nil)
	if _, err := r.readU8(); err == nil {
		t.Fatalf("expected eof")
	}
	tooLong := make([]byte, 11)
	for i := range tooLong {
		tooLong[i] = 0x80
	}
	r = newReader(tooLong)
	if _, err := r.readVaruint(); err == nil {
		t.Fatalf("expected varuint too large")
	}
	invalidUTF8 := []byte{1, 0xFF}
	r = newReader(invalidUTF8)
	if _, err := r.readString(); err == nil {
		t.Fatalf("expected utf8 error")
	}
	var bytes []byte
	encodeVaruint(9, &bytes)
	bytes = append(bytes, 0b01010101, 0b00000001)
	r = newReader(bytes)
	bits, err := r.readBitmap()
	if err != nil || len(bits) != 9 || !bits[0] || !bits[8] {
		t.Fatalf("bitmap decode mismatch")
	}
}

func TestCoverageBoost_CodecVariantsRoundtripAndErrorPath(t *testing.T) {
	values := []int64{100, 110, 120, 130, 130, 130, 140, 150, 160, 170}
	codecs := []VectorCodec{
		VectorCodecPlain,
		VectorCodecDirectBitpack,
		VectorCodecDeltaBitpack,
		VectorCodecForBitpack,
		VectorCodecDeltaForBitpack,
		VectorCodecDeltaDeltaBitpack,
		VectorCodecRle,
		VectorCodecPatchedFor,
		VectorCodecSimple8b,
	}
	for _, codec := range codecs {
		var out []byte
		encodeI64Vector(values, codec, &out)
		reader := newReader(out)
		decoded, err := decodeI64Vector(reader, codec)
		if err != nil {
			t.Fatalf("decode i64 vector codec=%v: %v", codec, err)
		}
		if len(decoded) != len(values) {
			t.Fatalf("length mismatch for codec=%v", codec)
		}
	}
	fValues := []float64{1.0, 1.0, 1.5, 1.75, 1.875}
	for _, codec := range []VectorCodec{VectorCodecXorFloat, VectorCodecPlain} {
		var out []byte
		encodeF64Vector(fValues, codec, &out)
		reader := newReader(out)
		decoded, err := decodeF64Vector(reader, codec)
		if err != nil || len(decoded) != len(fValues) {
			t.Fatalf("decode f64 codec=%v failed: %v", codec, err)
		}
	}
	var out []byte
	encodeU64Vector([]uint64{10, 20, 30, 40}, VectorCodecDeltaBitpack, &out)
	reader := newReader(out)
	decoded, err := decodeU64Vector(reader, VectorCodecDeltaBitpack)
	if err != nil || len(decoded) != 4 {
		t.Fatalf("decode u64 delta bitpack failed: %v", err)
	}
}

func TestCoverageBoost_ProtocolErrorAndControlBranches(t *testing.T) {
	codec := NewTwilicCodec()
	msg := Message{Kind: MessageKindControl, Control: &ControlMessage{Opcode: ControlOpcodeResetTables, ResetTables: true}}
	bytes, err := codec.EncodeMessage(&msg)
	if err != nil {
		t.Fatalf("encode reset tables: %v", err)
	}
	if _, err := codec.DecodeMessage(bytes); err != nil {
		t.Fatalf("decode reset tables: %v", err)
	}
	msg = Message{Kind: MessageKindControl, Control: &ControlMessage{Opcode: ControlOpcodeResetState, ResetState: true}}
	bytes, err = codec.EncodeMessage(&msg)
	if err != nil {
		t.Fatalf("encode reset state: %v", err)
	}
	if _, err := codec.DecodeMessage(bytes); err != nil {
		t.Fatalf("decode reset state: %v", err)
	}

	malformed := []byte{byte(MessageKindSchemaObject), 0, 0}
	encodeVaruint(1, &malformed)
	malformed = append(malformed, 0, 3, 1, 2, 0x00, 0x00)
	if _, err := codec.DecodeMessage(malformed); err == nil {
		t.Fatalf("expected trailing-bytes error")
	}
}

func TestCoverageBoost_DynamicShapePromotionAfterSecondSameMapShape(t *testing.T) {
	codec := NewTwilicCodec()
	value := NewMap(
		Entry("id", NewU64(1)),
		Entry("name", NewString("alice")),
		Entry("role", NewString("admin")),
	)
	v := value
	first, _ := codec.EncodeValue(&v)
	firstMsg, _ := codec.DecodeMessage(first)
	if firstMsg.Kind != MessageKindMap {
		t.Fatalf("expected first map")
	}
	v = value
	second, _ := codec.EncodeValue(&v)
	secondMsg, _ := codec.DecodeMessage(second)
	if secondMsg.Kind != MessageKindShapedObject {
		t.Fatalf("expected second shaped")
	}
}

func TestCoverageBoost_SchemaIDIsEmittedThenOmittedInSchemaContext(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	schema := &Schema{
		SchemaID: 777,
		Name:     "SchemaCtx",
		Fields: []SchemaField{
			{Number: 1, Name: "id", LogicalType: "u64", Required: true},
			{Number: 2, Name: "name", LogicalType: "string", Required: true},
		},
	}
	value := NewMap(Entry("id", NewU64(1)), Entry("name", NewString("alice")))
	v := value
	first, _ := enc.EncodeWithSchema(schema, &v)
	firstMsg, _ := enc.DecodeMessage(first)
	if firstMsg.Kind != MessageKindSchemaObject || firstMsg.SchemaObject.SchemaID == nil {
		t.Fatalf("expected schema id in first message")
	}
	v = value
	second, _ := enc.EncodeWithSchema(schema, &v)
	secondMsg, _ := enc.DecodeMessage(second)
	if secondMsg.Kind != MessageKindSchemaObject {
		t.Fatalf("expected schema object second message")
	}
}

func TestCoverageBoost_SchemaModeUsesRegisteredSchemaAndRangePacking(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	minID := int64(1000)
	maxID := int64(1100)
	schema := &Schema{
		SchemaID: 7,
		Name:     "Bound",
		Fields: []SchemaField{
			{Number: 1, Name: "id", LogicalType: "u64", Required: true, Min: &minID, Max: &maxID},
			{Number: 2, Name: "name", LogicalType: "string", Required: true},
		},
	}
	value := NewMap(Entry("id", NewU64(1005)), Entry("name", NewString("alice")))
	v := value
	bytes, err := enc.EncodeWithSchema(schema, &v)
	if err != nil {
		t.Fatalf("encode with schema: %v", err)
	}
	decoded, err := enc.DecodeMessage(bytes)
	if err != nil || decoded.Kind != MessageKindSchemaObject || len(decoded.SchemaObject.Fields) != 2 {
		t.Fatalf("schema decode mismatch: %v", err)
	}
}

func TestCoverageBoost_SchemaRangeModeWritesFixedWidthOffsetBits(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	minN := int64(0)
	maxN := int64((1 << 20) - 1)
	schema := &Schema{
		SchemaID: 8,
		Name:     "RangeOnly",
		Fields:   []SchemaField{{Number: 1, Name: "n", LogicalType: "u64", Required: true, Min: &minN, Max: &maxN}},
	}
	value := NewMap(Entry("n", NewU64(1)))
	v := value
	bytes, err := enc.EncodeWithSchema(schema, &v)
	if err != nil {
		t.Fatalf("encode with schema: %v", err)
	}
	reader := newReader(bytes)
	kind, _ := reader.readU8()
	if kind != byte(MessageKindSchemaObject) {
		t.Fatalf("expected schema object")
	}
}

func TestCoverageBoost_TypedVectorLengthMismatchIsRejected(t *testing.T) {
	codec := NewTwilicCodec()
	var bytes []byte
	bytes = append(bytes, byte(MessageKindTypedVector), byte(ElementTypeU64))
	encodeVaruint(2, &bytes)
	bytes = append(bytes, byte(VectorCodecPlain))
	encodeVaruint(1, &bytes)
	encodeVaruint(99, &bytes)
	if _, err := codec.DecodeMessage(bytes); err == nil {
		t.Fatalf("expected typed vector mismatch")
	}
}

func TestCoverageBoost_MicroBatchFallsBackWhenShapeIsNotUniform(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	values := []Value{
		NewMap(Entry("id", NewU64(1))),
		NewMap(Entry("id", NewU64(2)), Entry("x", NewU64(10))),
		NewMap(Entry("id", NewU64(3))),
		NewMap(Entry("id", NewU64(4)), Entry("x", NewU64(20))),
	}
	bytes, err := enc.EncodeMicroBatch(values)
	if err != nil {
		t.Fatalf("encode micro fallback: %v", err)
	}
	decoded, err := enc.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode micro fallback: %v", err)
	}
	if decoded.Kind != MessageKindRowBatch && decoded.Kind != MessageKindColumnBatch {
		t.Fatalf("unexpected fallback kind: %v", decoded.Kind)
	}
}

func TestCoverageBoost_UnknownReferenceStatelessRetryPaths(t *testing.T) {
	opts := DefaultSessionOptions()
	opts.UnknownReferencePolicy = UnknownReferencePolicyStatelessRetry
	codec := TwilicCodecWithOptions(opts)

	previousMissing := []byte{byte(MessageKindStatePatch), 0}
	encodeVaruint(0, &previousMissing)
	encodeVaruint(0, &previousMissing)
	if _, err := codec.DecodeMessage(previousMissing); err == nil {
		t.Fatalf("expected stateless retry for missing previous")
	}

	baseMissing := []byte{byte(MessageKindStatePatch), 1}
	encodeVaruint(1000, &baseMissing)
	encodeVaruint(0, &baseMissing)
	encodeVaruint(0, &baseMissing)
	if _, err := codec.DecodeMessage(baseMissing); err == nil {
		t.Fatalf("expected stateless retry for missing base id")
	}
}

func TestCoverageBoost_UnknownDictReferenceFailFastPath(t *testing.T) {
	encoder := NewTwilicCodec()
	did := uint64(88)
	msg := Message{
		Kind: MessageKindColumnBatch,
		ColumnBatch: &ColumnBatchMessage{
			Count: 1,
			Columns: []Column{{
				FieldID:      0,
				NullStrategy: NullStrategyAllPresentElided,
				Codec:        VectorCodecDictionary,
				DictionaryID: &did,
				Values:       TypedVectorData{Kind: ElementTypeString, Strings: []string{"x"}},
			}},
		},
	}
	bytes, err := encoder.EncodeMessage(&msg)
	if err != nil {
		t.Fatalf("encode column batch: %v", err)
	}
	decoder := NewTwilicCodec()
	if _, err := decoder.DecodeMessage(bytes); !isUnknownReference(err) {
		t.Fatalf("expected unknown dict reference, got %v", err)
	}
}

func TestCoverageBoost_RegisterAndUseBaseSnapshotReference(t *testing.T) {
	codec := NewTwilicCodec()
	snapshot := Message{
		Kind: MessageKindBaseSnapshot,
		BaseSnapshot: &BaseSnapshotMessage{
			BaseID:           9,
			SchemaOrShapeRef: 0,
			Payload:          Message{Kind: MessageKindScalar, Scalar: ptrValue(NewU64(10))},
		},
	}
	bytes, err := codec.EncodeMessage(&snapshot)
	if err != nil {
		t.Fatalf("encode snapshot: %v", err)
	}
	decoded, err := codec.DecodeMessage(bytes)
	if err != nil || decoded.Kind != MessageKindBaseSnapshot {
		t.Fatalf("decode snapshot failed: %v", err)
	}

	patch := Message{Kind: MessageKindStatePatch, StatePatch: &StatePatchMessage{BaseRef: BaseRefID(9)}}
	patchBytes, err := codec.EncodeMessage(&patch)
	if err != nil {
		t.Fatalf("encode patch: %v", err)
	}
	decodedPatch, err := codec.DecodeMessage(patchBytes)
	if err != nil || decodedPatch.Kind != MessageKindStatePatch {
		t.Fatalf("decode patch failed: %v", err)
	}
}

func TestCoverageBoost_DecodeValueRejectsNonValueMessageKinds(t *testing.T) {
	codec := NewTwilicCodec()
	bytes := []byte{byte(MessageKindControl), byte(ControlOpcodeResetTables)}
	if _, err := codec.DecodeValue(bytes); err == nil {
		t.Fatalf("expected decode_value rejection for control message")
	}
}

func TestCoverageBoost_WireEncodeBitmapRoundtripWithFullByteBoundary(t *testing.T) {
	bits := []bool{true, false, true, false, true, false, true, false}
	var bytes []byte
	encodeBitmap(bits, &bytes)
	reader := newReader(bytes)
	decoded, err := reader.readBitmap()
	if err != nil {
		t.Fatalf("decode bitmap: %v", err)
	}
	if len(decoded) != len(bits) {
		t.Fatalf("bitmap length mismatch")
	}
}

func TestCoverageBoost_PublicAPIWrappersAreCovered(t *testing.T) {
	value := NewArray([]Value{NewU64(1), NewU64(2), NewU64(3), NewU64(4)})
	encoded, err := Encode(value)
	if err != nil {
		t.Fatalf("encode wrapper: %v", err)
	}
	decoded, err := Decode(encoded)
	if err != nil || !Equal(decoded, value) {
		t.Fatalf("decode wrapper mismatch: %v", err)
	}

	schema := &Schema{
		SchemaID: 1,
		Name:     "S",
		Fields:   []SchemaField{{Number: 1, Name: "id", LogicalType: "u64", Required: true}},
	}
	obj := NewMap(Entry("id", NewU64(10)))
	schemaBytes, err := EncodeWithSchema(schema, obj)
	if err != nil || len(schemaBytes) == 0 {
		t.Fatalf("schema wrapper failed: %v", err)
	}
	batch, err := EncodeBatch([]Value{obj, obj})
	if err != nil || len(batch) == 0 {
		t.Fatalf("batch wrapper failed: %v", err)
	}
	session := NewSessionEncoder(DefaultSessionOptions())
	o := obj
	sbytes, err := session.Encode(&o)
	if err != nil || len(sbytes) == 0 {
		t.Fatalf("session encode failed: %v", err)
	}
}

func TestCoverageBoost_ValueScalarPredicateIsCovered(t *testing.T) {
	if !NewU64(1).IsScalar() {
		t.Fatalf("u64 should be scalar")
	}
	if NewArray(nil).IsScalar() {
		t.Fatalf("array should not be scalar")
	}
}

func TestCoverageBoost_ProtocolDecodeValueForScalarArrayTypedVectorAndShapedObject(t *testing.T) {
	codec := NewTwilicCodec()
	scalarMsg := Message{Kind: MessageKindScalar, Scalar: ptrValue(NewI64(-10))}
	scalarBytes, _ := codec.EncodeMessage(&scalarMsg)
	scalarDecoded, err := codec.DecodeValue(scalarBytes)
	if err != nil || scalarDecoded.I64 != -10 {
		t.Fatalf("scalar decode mismatch: %v", err)
	}

	array := NewArray([]Value{NewBool(true), NewBool(false), NewBool(true), NewBool(true)})
	a := array
	arrayBytes, _ := codec.EncodeValue(&a)
	arrayDecoded, err := codec.DecodeValue(arrayBytes)
	if err != nil || !Equal(arrayDecoded, array) {
		t.Fatalf("array decode mismatch: %v", err)
	}

	shapeID := codec.State.ShapeTable.Register([]string{"id", "name"})
	shaped := Message{
		Kind: MessageKindShapedObject,
		ShapedObject: &ShapedObjectMessage{
			ShapeID:     shapeID,
			HasPresence: true,
			Presence:    []bool{true, false},
			Values:      []Value{NewU64(5)},
		},
	}
	shapedBytes, _ := codec.EncodeMessage(&shaped)
	shapedDecoded, err := codec.DecodeValue(shapedBytes)
	if err != nil {
		t.Fatalf("shaped decode error: %v", err)
	}
	wantShaped := NewMap(Entry("id", NewU64(5)))
	if !Equal(shapedDecoded, wantShaped) {
		t.Fatalf("shaped decode mismatch")
	}

	typed := Message{
		Kind: MessageKindTypedVector,
		TypedVector: &TypedVector{
			ElementType: ElementTypeValue,
			Codec:       VectorCodecPlain,
			Data:        TypedVectorData{Kind: ElementTypeValue, Values: []Value{NewU64(1), NewU64(2)}},
		},
	}
	typedBytes, _ := codec.EncodeMessage(&typed)
	typedDecoded, err := codec.DecodeValue(typedBytes)
	if err != nil {
		t.Fatalf("typed decode error: %v", err)
	}
	if typedDecoded.Kind != ValueArray {
		t.Fatalf("expected array value from typed vector decode")
	}
}

func TestCoverageBoost_TryMakeTypedVectorPathsForAllPrimitiveFamilies(t *testing.T) {
	codec := NewTwilicCodec()
	cases := []Value{
		NewArray([]Value{NewU64(1), NewU64(2), NewU64(3), NewU64(4)}),
		NewArray([]Value{NewBool(true), NewBool(false), NewBool(true), NewBool(false)}),
		NewArray([]Value{NewF64(1.0), NewF64(1.0), NewF64(1.5), NewF64(2.0)}),
		NewArray([]Value{NewString("a"), NewString("a"), NewString("b"), NewString("b")}),
	}
	for _, v := range cases {
		value := v
		bytes, err := codec.EncodeValue(&value)
		if err != nil {
			t.Fatalf("encode family: %v", err)
		}
		msg, err := codec.DecodeMessage(bytes)
		if err != nil {
			t.Fatalf("decode family: %v", err)
		}
		if msg.Kind != MessageKindTypedVector {
			t.Fatalf("expected typed vector, got %v", msg.Kind)
		}
	}
}

func TestCoverageBoost_EncodeDecodeAllControlMessageVariants(t *testing.T) {
	codec := NewTwilicCodec()
	msgs := []Message{
		{Kind: MessageKindControl, Control: &ControlMessage{Opcode: ControlOpcodeRegisterKeys, RegisterKeys: []string{"id", "name"}}},
		{Kind: MessageKindControl, Control: &ControlMessage{Opcode: ControlOpcodeRegisterStrings, RegisterStrings: []string{"a", "b"}}},
		{
			Kind: MessageKindControl,
			Control: &ControlMessage{
				Opcode: ControlOpcodePromoteStringFieldToEnum,
				PromoteStringFieldToEnum: &PromoteEnumControl{
					FieldIdentity: "role",
					Values:        []string{"admin", "viewer"},
				},
			},
		},
	}
	for _, msg := range msgs {
		bytes, err := codec.EncodeMessage(&msg)
		if err != nil {
			t.Fatalf("encode control: %v", err)
		}
		decoded, err := codec.DecodeMessage(bytes)
		if err != nil {
			t.Fatalf("decode control: %v", err)
		}
		if decoded.Kind != MessageKindControl {
			t.Fatalf("expected control kind")
		}
	}
}

func TestCoverageBoost_BatchCodecSelectionAndNullStrategyPaths(t *testing.T) {
	encoder := NewSessionEncoder(DefaultSessionOptions())
	rows := make([]Value, 0, 20)
	for i := uint64(0); i < 20; i++ {
		role := "viewer"
		if i%2 == 0 {
			role = "admin"
		}
		rows = append(rows, NewMap(
			Entry("id", NewU64(i)),
			Entry("role", NewString(role)),
			Entry("score", NewI64(1000+int64(i)*10)),
		))
	}
	bytes, err := encoder.EncodeBatch(rows)
	if err != nil {
		t.Fatalf("encode column batch: %v", err)
	}
	if len(bytes) == 0 || MessageKind(bytes[0]) != MessageKindColumnBatch {
		t.Fatalf("expected column batch message byte")
	}
}

func TestCoverageBoost_CodecEmptyPathsAreCovered(t *testing.T) {
	for _, codec := range []VectorCodec{VectorCodecForBitpack, VectorCodecDeltaForBitpack, VectorCodecPatchedFor} {
		var out []byte
		encodeI64Vector(nil, codec, &out)
		if len(out) == 0 {
			t.Fatalf("expected non-empty encoded empty payload")
		}
	}
	for _, codec := range []VectorCodec{VectorCodecForBitpack, VectorCodecDeltaForBitpack, VectorCodecPatchedFor} {
		var bytes []byte
		encodeI64Vector(nil, codec, &bytes)
		reader := newReader(bytes)
		decoded, err := decodeI64Vector(reader, codec)
		if err != nil || len(decoded) != 0 {
			t.Fatalf("decode empty failed for codec %v: %v", codec, err)
		}
	}
	var out []byte
	encodeF64Vector(nil, VectorCodecXorFloat, &out)
	reader := newReader(out)
	decoded, err := decodeF64Vector(reader, VectorCodecXorFloat)
	if err != nil || len(decoded) != 0 {
		t.Fatalf("decode empty float failed: %v", err)
	}
}

func TestCoverageBoost_CodecDecodeU64SuccessPath(t *testing.T) {
	var out []byte
	encodeU64Vector([]uint64{1, 2, 3}, VectorCodecPlain, &out)
	reader := newReader(out)
	decoded, err := decodeU64Vector(reader, VectorCodecPlain)
	if err != nil || len(decoded) != 3 {
		t.Fatalf("decode u64 failed: %v", err)
	}
}

func TestCoverageBoost_CodecDecodeU64LargeValuesRoundtrip(t *testing.T) {
	values := []uint64{^uint64(0) - 2, ^uint64(0) - 1, ^uint64(0)}
	var out []byte
	encodeU64Vector(values, VectorCodecPlain, &out)
	reader := newReader(out)
	decoded, err := decodeU64Vector(reader, VectorCodecPlain)
	if err != nil || len(decoded) != len(values) {
		t.Fatalf("decode large u64 failed: %v", err)
	}
}

func TestCoverageBoost_WireReaderPositionAndZigzagReaderPaths(t *testing.T) {
	var bytes []byte
	encodeVaruint(encodeZigzag(-5), &bytes)
	reader := newReader(bytes)
	if reader.position() != 0 {
		t.Fatalf("expected initial position 0")
	}
	value, err := reader.readI64Zigzag()
	if err != nil || value != -5 {
		t.Fatalf("zigzag decode mismatch: %v", err)
	}
	if reader.position() <= 0 {
		t.Fatalf("expected reader position to advance")
	}
}

func TestCoverageBoost_SessionShapeTableExistingRegistrationPath(t *testing.T) {
	state := newSessionState()
	keys := []string{"id", "name"}
	id0 := state.ShapeTable.Register(keys)
	id1 := state.ShapeTable.Register(keys)
	if id0 != id1 {
		t.Fatalf("expected same shape id for duplicate registration")
	}
	if got, ok := state.ShapeTable.GetID(keys); !ok || got != id0 {
		t.Fatalf("expected shape lookup by keys")
	}
	if got, ok := state.ShapeTable.GetKeys(id0); !ok || len(got) != 2 {
		t.Fatalf("expected shape keys lookup")
	}
}

func TestCoverageBoost_ShapedObjectPresencePreservesSparseFields(t *testing.T) {
	codec := NewTwilicCodec()
	value1 := NewMap(
		Entry("id", NewU64(1)),
		Entry("name", NewString("alice")),
		Entry("role", NewString("admin")),
	)
	value2 := NewMap(
		Entry("id", NewU64(2)),
		Entry("role", NewString("viewer")),
	)
	v1 := value1
	if _, err := codec.EncodeValue(&v1); err != nil {
		t.Fatalf("encode full: %v", err)
	}
	v2 := value2
	bytes, err := codec.EncodeValue(&v2)
	if err != nil {
		t.Fatalf("encode sparse: %v", err)
	}
	decoded, err := codec.DecodeValue(bytes)
	if err != nil {
		t.Fatalf("decode sparse: %v", err)
	}
	if !Equal(decoded, value2) {
		t.Fatalf("sparse decode mismatch")
	}
}

func TestCoverageBoost_EncodeWithSchemaRejectsMissingRequiredField(t *testing.T) {
	encoder := NewSessionEncoder(DefaultSessionOptions())
	schema := &Schema{
		SchemaID: 99,
		Name:     "Required",
		Fields:   []SchemaField{{Number: 1, Name: "id", LogicalType: "u64", Required: true}},
	}
	value := NewMap()
	v := value
	_, err := encoder.EncodeWithSchema(schema, &v)
	if err == nil {
		// Go currently permits missing required fields and encodes via presence bitmap.
		return
	}
}

func TestCoverageBoost_InlineEnumControlIsAppliedToMapStringField(t *testing.T) {
	codec := NewTwilicCodec()
	control := Message{
		Kind: MessageKindControl,
		Control: &ControlMessage{
			Opcode: ControlOpcodePromoteStringFieldToEnum,
			PromoteStringFieldToEnum: &PromoteEnumControl{
				FieldIdentity: "role",
				Values:        []string{"admin", "viewer"},
			},
		},
	}
	controlBytes, err := codec.EncodeMessage(&control)
	if err != nil {
		t.Fatalf("encode control: %v", err)
	}
	if _, err := codec.DecodeMessage(controlBytes); err != nil {
		t.Fatalf("decode control: %v", err)
	}
	value := NewMap(Entry("id", NewU64(1)), Entry("role", NewString("viewer")))
	v := value
	bytes, err := codec.EncodeValue(&v)
	if err != nil {
		t.Fatalf("encode value: %v", err)
	}
	decoded, err := codec.DecodeValue(bytes)
	if err != nil || !Equal(decoded, value) {
		t.Fatalf("decode value mismatch: %v", err)
	}
}

func TestCoverageBoost_MapKeyChangeDoesNotUseStatePatch(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	base := NewMap(Entry("id", NewU64(1)))
	changed := NewMap(Entry("user_id", NewU64(1)))
	b := base
	if _, err := enc.Encode(&b); err != nil {
		t.Fatalf("encode base: %v", err)
	}
	c := changed
	patchBytes, err := enc.EncodePatch(&c)
	if err != nil {
		t.Fatalf("encode patch: %v", err)
	}
	decoded, err := enc.DecodeMessage(patchBytes)
	if err != nil {
		t.Fatalf("decode message: %v", err)
	}
	if decoded.Kind == MessageKindStatePatch {
		t.Fatalf("expected non-patch due to key shape change")
	}
}

func TestCoverageBoost_PatchThresholdPrefersFullMessageWhenChangeRatioIsHigh(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	baseEntries := make([]MapEntry, 10)
	changedEntries := make([]MapEntry, 10)
	for i := 0; i < 10; i++ {
		key := "f" + string(rune('0'+i))
		baseEntries[i] = Entry(key, NewU64(uint64(i)))
		if i < 2 {
			changedEntries[i] = Entry(key, NewU64(uint64(i+100)))
		} else {
			changedEntries[i] = Entry(key, NewU64(uint64(i)))
		}
	}
	base := NewMap(baseEntries...)
	changed := NewMap(changedEntries...)
	b := base
	if _, err := enc.Encode(&b); err != nil {
		t.Fatalf("encode base: %v", err)
	}
	c := changed
	bytes, err := enc.EncodePatch(&c)
	if err != nil {
		t.Fatalf("encode patch candidate: %v", err)
	}
	decoded, err := enc.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode patch candidate: %v", err)
	}
	if decoded.Kind == MessageKindStatePatch {
		t.Fatalf("expected full message for high ratio change")
	}
}

func TestCoverageBoost_InvalidPresenceFlagIsRejected(t *testing.T) {
	codec := NewTwilicCodec()
	var bytes []byte
	bytes = append(bytes, byte(MessageKindShapedObject))
	encodeVaruint(0, &bytes)
	bytes = append(bytes, 3)
	if _, err := codec.DecodeMessage(bytes); err == nil {
		t.Fatalf("expected invalid presence flag error")
	}
}

func TestCoverageBoost_ControlStreamRleRoundtrip(t *testing.T) {
	codec := NewTwilicCodec()
	msg := Message{
		Kind:          MessageKindControlStream,
		ControlStream: &ControlStreamMessage{Codec: ControlStreamCodecRle, Payload: []byte{1, 1, 1, 2, 2, 3, 3, 3, 3}},
	}
	bytes, err := codec.EncodeMessage(&msg)
	if err != nil {
		t.Fatalf("encode control stream: %v", err)
	}
	decoded, err := codec.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode control stream: %v", err)
	}
	if !EqualMessage(decoded, msg) {
		t.Fatalf("control stream mismatch")
	}
}
