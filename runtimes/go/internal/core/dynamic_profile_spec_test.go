package core

import "testing"

func scalarStringMode(t *testing.T, bytes []byte) byte {
	t.Helper()
	if len(bytes) < 3 {
		t.Fatalf("expected at least 3 bytes, got %d", len(bytes))
	}
	if bytes[0] != byte(MessageKindScalar) {
		t.Fatalf("expected scalar kind byte, got %d", bytes[0])
	}
	if bytes[1] != tagString {
		t.Fatalf("expected string tag byte, got %d", bytes[1])
	}
	return bytes[2]
}

func TestDynamicProfile_ShapePromotesAfterSecondThreeFieldMap(t *testing.T) {
	codec := NewTwilicCodec()
	value := NewMap(
		Entry("id", NewU64(1)),
		Entry("name", NewString("alice")),
		Entry("role", NewString("admin")),
	)

	first := value
	firstBytes, err := codec.EncodeValue(&first)
	if err != nil {
		t.Fatalf("encode first: %v", err)
	}
	firstMsg, err := codec.DecodeMessage(firstBytes)
	if err != nil {
		t.Fatalf("decode first: %v", err)
	}
	if firstMsg.Kind != MessageKindMap {
		t.Fatalf("expected first message map, got %v", firstMsg.Kind)
	}

	second := value
	secondBytes, err := codec.EncodeValue(&second)
	if err != nil {
		t.Fatalf("encode second: %v", err)
	}
	secondMsg, err := codec.DecodeMessage(secondBytes)
	if err != nil {
		t.Fatalf("decode second: %v", err)
	}
	if secondMsg.Kind != MessageKindShapedObject {
		t.Fatalf("expected second message shaped object, got %v", secondMsg.Kind)
	}

	third := value
	thirdBytes, err := codec.EncodeValue(&third)
	if err != nil {
		t.Fatalf("encode third: %v", err)
	}
	thirdMsg, err := codec.DecodeMessage(thirdBytes)
	if err != nil {
		t.Fatalf("decode third: %v", err)
	}
	if thirdMsg.Kind != MessageKindShapedObject {
		t.Fatalf("expected third message shaped object, got %v", thirdMsg.Kind)
	}
}

func TestDynamicProfile_TwoFieldMapKeepsMapAndUsesKeyIDs(t *testing.T) {
	codec := NewTwilicCodec()
	value := NewMap(
		Entry("id", NewU64(1)),
		Entry("name", NewString("alice")),
	)

	first := value
	firstBytes, err := codec.EncodeValue(&first)
	if err != nil {
		t.Fatalf("encode first: %v", err)
	}
	firstMsg, err := codec.DecodeMessage(firstBytes)
	if err != nil {
		t.Fatalf("decode first: %v", err)
	}
	if firstMsg.Kind != MessageKindMap {
		t.Fatalf("expected map, got %v", firstMsg.Kind)
	}
	for _, entry := range firstMsg.Map {
		if entry.Key.IsID {
			t.Fatalf("expected literal keys on first map")
		}
	}

	second := value
	secondBytes, err := codec.EncodeValue(&second)
	if err != nil {
		t.Fatalf("encode second: %v", err)
	}
	secondMsg, err := codec.DecodeMessage(secondBytes)
	if err != nil {
		t.Fatalf("decode second: %v", err)
	}
	if secondMsg.Kind != MessageKindMap && secondMsg.Kind != MessageKindShapedObject {
		t.Fatalf("expected map or shaped object, got %v", secondMsg.Kind)
	}
	if secondMsg.Kind == MessageKindMap {
		for _, entry := range secondMsg.Map {
			if !entry.Key.IsID {
				t.Fatalf("expected key ref ids on second map")
			}
		}
	}
}

func TestDynamicProfile_TypedVectorThresholdIsApplied(t *testing.T) {
	codec := NewTwilicCodec()

	short := NewArray([]Value{NewI64(1), NewI64(2), NewI64(3)})
	shortValue := short
	shortBytes, err := codec.EncodeValue(&shortValue)
	if err != nil {
		t.Fatalf("encode short: %v", err)
	}
	shortMsg, err := codec.DecodeMessage(shortBytes)
	if err != nil {
		t.Fatalf("decode short: %v", err)
	}
	if shortMsg.Kind != MessageKindArray {
		t.Fatalf("expected short to stay array, got %v", shortMsg.Kind)
	}

	long := NewArray([]Value{NewI64(1), NewI64(2), NewI64(3), NewI64(4)})
	longValue := long
	longBytes, err := codec.EncodeValue(&longValue)
	if err != nil {
		t.Fatalf("encode long: %v", err)
	}
	longMsg, err := codec.DecodeMessage(longBytes)
	if err != nil {
		t.Fatalf("decode long: %v", err)
	}
	if longMsg.Kind != MessageKindTypedVector {
		t.Fatalf("expected long to become typed vector, got %v", longMsg.Kind)
	}
}

func TestDynamicProfile_StringModesEmptyRefAndPrefixDeltaAreUsed(t *testing.T) {
	codec := NewTwilicCodec()

	empty := NewString("")
	emptyBytes, err := codec.EncodeValue(&empty)
	if err != nil {
		t.Fatalf("encode empty: %v", err)
	}
	if scalarStringMode(t, emptyBytes) != byte(StringModeEmpty) {
		t.Fatalf("expected empty mode")
	}

	lit := NewString("alpha")
	litBytes, err := codec.EncodeValue(&lit)
	if err != nil {
		t.Fatalf("encode literal: %v", err)
	}
	if scalarStringMode(t, litBytes) != byte(StringModeLiteral) {
		t.Fatalf("expected literal mode")
	}

	ref := NewString("alpha")
	refBytes, err := codec.EncodeValue(&ref)
	if err != nil {
		t.Fatalf("encode ref: %v", err)
	}
	if scalarStringMode(t, refBytes) != byte(StringModeRef) {
		t.Fatalf("expected ref mode")
	}

	prefixBase := NewString("prefix_common_aaaa")
	if _, err := codec.EncodeValue(&prefixBase); err != nil {
		t.Fatalf("encode prefix base: %v", err)
	}
	prefixDelta := NewString("prefix_common_bbbb")
	prefixDeltaBytes, err := codec.EncodeValue(&prefixDelta)
	if err != nil {
		t.Fatalf("encode prefix delta: %v", err)
	}
	if scalarStringMode(t, prefixDeltaBytes) != byte(StringModePrefixDelta) {
		t.Fatalf("expected prefix-delta mode")
	}
}

func TestDynamicProfile_ResetTablesClearsStringInterning(t *testing.T) {
	codec := NewTwilicCodec()

	before := NewString("ephemeral")
	if _, err := codec.EncodeValue(&before); err != nil {
		t.Fatalf("encode before reset: %v", err)
	}
	reused := NewString("ephemeral")
	reusedBytes, err := codec.EncodeValue(&reused)
	if err != nil {
		t.Fatalf("encode reused: %v", err)
	}
	if scalarStringMode(t, reusedBytes) != byte(StringModeRef) {
		t.Fatalf("expected ref mode before reset")
	}

	reset := Message{
		Kind: MessageKindControl,
		Control: &ControlMessage{
			Opcode:      ControlOpcodeResetTables,
			ResetTables: true,
		},
	}
	resetBytes, err := codec.EncodeMessage(&reset)
	if err != nil {
		t.Fatalf("encode reset: %v", err)
	}
	if _, err := codec.DecodeMessage(resetBytes); err != nil {
		t.Fatalf("decode reset: %v", err)
	}

	after := NewString("ephemeral")
	afterBytes, err := codec.EncodeValue(&after)
	if err != nil {
		t.Fatalf("encode after reset: %v", err)
	}
	if scalarStringMode(t, afterBytes) != byte(StringModeLiteral) {
		t.Fatalf("expected literal mode after reset")
	}
}
