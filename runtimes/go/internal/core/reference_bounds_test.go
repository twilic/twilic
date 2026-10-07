package core

import "testing"

func TestReferenceBoundsRejectHugeIDs(t *testing.T) {
	for _, id := range []uint64{1 << 32, 1 << 63, ^uint64(0)} {
		var encoded []byte
		encodeVaruint(id, &encoded)
		table := newInternTable()
		table.Register("valid")
		if _, ok := table.GetValue(id); ok {
			t.Fatalf("intern ID %d accepted", id)
		}
		if value, ok := table.GetValue(0); !ok || value != "valid" {
			t.Fatal("valid intern ID rejected")
		}
		state := &v2DecodeState{keys: []string{"k"}, strings: []string{"v"}}
		if _, err := decodeV2Value(newReader(append([]byte{strRefTag}, encoded...)), state); err == nil {
			t.Fatalf("str_ref %d accepted", id)
		}
		if _, err := decodeV2Key(newReader(append([]byte{keyRefTag}, encoded...)), state); err == nil {
			t.Fatalf("key_ref %d accepted", id)
		}
		c := NewTwilicCodec()
		field := "field"
		c.State.FieldEnums[field] = []string{"valid"}
		inline := append([]byte{tagString, byte(StringModeInlineEnum)}, encoded...)
		if _, err := c.readValueWithField(newReader(inline), &field); err == nil {
			t.Fatalf("inline enum %d accepted", id)
		}
		schemaField := SchemaField{LogicalType: "string", EnumValues: []string{"valid"}}
		if _, err := c.readSchemaFieldValue(&schemaField, newReader(append([]byte{1}, encoded...))); err == nil {
			t.Fatalf("schema enum %d accepted", id)
		}
		var vector []byte
		encodeVaruint(1, &vector)
		encodeString("valid", &vector)
		encodeU64Vector([]uint64{id}, VectorCodecDirectBitpack, &vector)
		if _, err := c.readStringVector(newReader(vector), VectorCodecDictionary); err == nil {
			t.Fatalf("dictionary vector %d accepted", id)
		}
		block := append([]byte{0, 1}, encoded...)
		if _, err := decodeTrainedDictionaryBlock(block, []string{"valid"}); err == nil {
			t.Fatalf("trained dictionary %d accepted", id)
		}
	}
}

func TestPatchBoundsRejectHugeFieldIDsAndTruncateLengths(t *testing.T) {
	value := NewArray([]Value{NewU64(1)})
	base := Message{Kind: MessageKindArray, Array: []Value{value}}
	for _, id := range []uint64{1 << 32, 1 << 63, ^uint64(0)} {
		for _, opcode := range []PatchOpcode{PatchOpcodeReplaceScalar, PatchOpcodeReplaceVector,
			PatchOpcodeInsertField, PatchOpcodeStringRef, PatchOpcodePrefixDelta,
			PatchOpcodeDeleteField, PatchOpcodeAppendVector, PatchOpcodeTruncateVector} {
			c := NewTwilicCodec()
			c.State.PreviousMessage = &base
			if _, err := c.applyStatePatch(BaseRefPrevious(), []PatchOperation{{FieldID: id, Opcode: opcode, Value: &value}}, nil); err == nil {
				t.Fatalf("patch opcode %d ID %d accepted", opcode, id)
			}
		}
		c := NewTwilicCodec()
		c.State.PreviousMessage = &base
		length := NewU64(id)
		if _, err := c.applyStatePatch(BaseRefPrevious(), []PatchOperation{{Opcode: PatchOpcodeTruncateVector, Value: &length}}, nil); err == nil {
			t.Fatalf("truncate length %d accepted", id)
		}
	}
	c := NewTwilicCodec()
	c.State.PreviousMessage = &base
	appended, err := c.applyStatePatch(BaseRefPrevious(), []PatchOperation{{FieldID: 1, Opcode: PatchOpcodeInsertField, Value: &value}}, nil)
	if err != nil || len(appended.Array) != 2 {
		t.Fatalf("valid end insertion rejected: %v", err)
	}

}
