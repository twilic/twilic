package core

import (
	"errors"
	"testing"
)

func TestTwilic_RoundtripDynamicValue(t *testing.T) {
	value := NewMap(
		Entry("id", NewU64(1001)),
		Entry("name", NewString("alice")),
		Entry("admin", NewBool(false)),
		Entry("scores", NewArray([]Value{NewI64(12), NewI64(15), NewI64(18), NewI64(21)})),
	)
	codec := NewTwilicCodec()
	v := value
	encoded, err := codec.EncodeValue(&v)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	decoded, err := codec.DecodeValue(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !Equal(decoded, value) {
		t.Fatalf("decoded value mismatch")
	}
}

func TestTwilic_RoundtripAllMessageKinds(t *testing.T) {
	codec := NewTwilicCodec()
	prev := Message{Kind: MessageKindScalar, Scalar: ptrValue(NewU64(0))}
	codec.State.PreviousMessage = &prev

	shapeID := codec.State.ShapeTable.Register([]string{"id"})
	schemaID := uint64(42)
	msgs := []Message{
		{Kind: MessageKindScalar, Scalar: ptrValue(NewU64(1))},
		{Kind: MessageKindArray, Array: []Value{NewBool(true), NewI64(3)}},
		{Kind: MessageKindMap, Map: []MessageMapEntry{messageMapEntry("id", NewU64(7))}},
		{Kind: MessageKindShapedObject, ShapedObject: &ShapedObjectMessage{ShapeID: shapeID, Values: []Value{NewU64(8)}}},
		{Kind: MessageKindSchemaObject, SchemaObject: &SchemaObjectMessage{SchemaID: &schemaID, Fields: []Value{NewU64(9)}}},
		{Kind: MessageKindTypedVector, TypedVector: &TypedVector{
			ElementType: ElementTypeI64,
			Codec:       VectorCodecDeltaDeltaBitpack,
			Data:        TypedVectorData{Kind: ElementTypeI64, I64s: []int64{10, 20, 30, 40}},
		}},
		{Kind: MessageKindRowBatch, RowBatch: &RowBatchMessage{Rows: [][]Value{{NewU64(1)}, {NewU64(2)}}}},
		{Kind: MessageKindControl, Control: &ControlMessage{Opcode: ControlOpcodeRegisterKeys, RegisterKeys: []string{"id"}}},
		{Kind: MessageKindExt, Ext: &ExtMessage{ExtType: 1, Payload: []byte{1, 2, 3}}},
		{Kind: MessageKindStatePatch, StatePatch: &StatePatchMessage{
			BaseRef: BaseRefPrevious(),
			Operations: []PatchOperation{
				{FieldID: 0, Opcode: PatchOpcodeKeep},
			},
		}},
		{Kind: MessageKindControlStream, ControlStream: &ControlStreamMessage{Codec: ControlStreamCodecRle, Payload: []byte{0, 1}}},
		{Kind: MessageKindBaseSnapshot, BaseSnapshot: &BaseSnapshotMessage{
			BaseID:           1,
			SchemaOrShapeRef: 0,
			Payload:          Message{Kind: MessageKindScalar, Scalar: ptrValue(NewU64(10))},
		}},
	}

	for _, msg := range msgs {
		msg := msg
		encoded, err := codec.EncodeMessage(&msg)
		if err != nil {
			t.Fatalf("encode message kind %v: %v", msg.Kind, err)
		}
		decoded, err := codec.DecodeMessage(encoded)
		if err != nil {
			t.Fatalf("decode message kind %v: %v", msg.Kind, err)
		}
		if decoded.Kind != msg.Kind {
			t.Fatalf("kind mismatch: got %v want %v", decoded.Kind, msg.Kind)
		}
	}
}

func TestTwilic_SessionPatchAndMicroBatch(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	base := NewMap(Entry("id", NewU64(1)), Entry("name", NewString("alice")))
	next := NewMap(Entry("id", NewU64(1)), Entry("name", NewString("alicia")))
	b := base
	if _, err := enc.Encode(&b); err != nil {
		t.Fatalf("encode base: %v", err)
	}
	n := next
	patch, err := enc.EncodePatch(&n)
	if err != nil {
		t.Fatalf("encode patch: %v", err)
	}
	if len(patch) == 0 {
		t.Fatalf("expected non-empty patch")
	}
	micro, err := enc.EncodeMicroBatch([]Value{base, next, base, next})
	if err != nil {
		t.Fatalf("encode micro: %v", err)
	}
	if len(micro) == 0 {
		t.Fatalf("expected non-empty micro batch")
	}
}

func TestTwilic_CodecSelectionUsesDeltaDeltaForRegularSeries(t *testing.T) {
	items := make([]Value, 16)
	for i := 0; i < 16; i++ {
		items[i] = NewI64(int64(1000 + i*10))
	}
	value := NewArray(items)
	codec := NewTwilicCodec()
	v := value
	bytes, err := codec.EncodeValue(&v)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	msg, err := codec.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode message: %v", err)
	}
	if msg.Kind != MessageKindTypedVector {
		t.Fatalf("expected typed vector, got %v", msg.Kind)
	}
}

func TestTwilic_UnknownReferencePolicySupportsStatelessRetry(t *testing.T) {
	opts := DefaultSessionOptions()
	opts.UnknownReferencePolicy = UnknownReferencePolicyStatelessRetry
	codec := TwilicCodecWithOptions(opts)
	patch := Message{
		Kind: MessageKindStatePatch,
		StatePatch: &StatePatchMessage{
			BaseRef:    BaseRefID(777),
			Operations: []PatchOperation{},
		},
	}
	raw, err := codec.EncodeMessage(&patch)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	decodeCodec := TwilicCodecWithOptions(opts)
	_, err = decodeCodec.DecodeMessage(raw)
	var te *TwilicError
	if !errors.As(err, &te) || te.Kind != ErrStatelessRetryRequired || te.RefKind != "base_id" || te.RefID != 777 {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestTwilic_PatchSelectionUsesPreviousBaseForSafeInterop(t *testing.T) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	base := NewMap(
		Entry("id", NewU64(1)),
		Entry("name", NewString("alice")),
		Entry("score", NewI64(100)),
	)
	unrelated := NewMap(
		Entry("id", NewU64(999)),
		Entry("name", NewString("zeta")),
		Entry("score", NewI64(-500)),
	)
	nearBase := NewMap(
		Entry("id", NewU64(1)),
		Entry("name", NewString("alice")),
		Entry("score", NewI64(101)),
	)

	b := base
	if _, err := enc.Encode(&b); err != nil {
		t.Fatalf("encode base: %v", err)
	}
	u := unrelated
	if _, err := enc.Encode(&u); err != nil {
		t.Fatalf("encode unrelated: %v", err)
	}
	n := nearBase
	patchBytes, err := enc.EncodePatch(&n)
	if err != nil {
		t.Fatalf("encode patch: %v", err)
	}
	decoded, err := enc.DecodeMessage(patchBytes)
	if err != nil {
		t.Fatalf("decode patch: %v", err)
	}
	if decoded.Kind == MessageKindStatePatch && !decoded.StatePatch.BaseRef.Previous {
		t.Fatalf("expected previous-message patch base ref")
	}
}

func ptrValue(v Value) *Value {
	return &v
}
