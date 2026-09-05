package core

import "testing"

func encodedControlStreamLen(codec ControlStreamCodec, payload []byte) int {
	codecImpl := NewTwilicCodec()
	msg := Message{
		Kind:          MessageKindControlStream,
		ControlStream: &ControlStreamMessage{Codec: codec, Payload: payload},
	}
	b, err := codecImpl.EncodeMessage(&msg)
	if err != nil {
		return 0
	}
	return len(b)
}

func TestControlStreamAndControlSpec_ControlStreamRoundtripsForAllDeclaredCodecs(t *testing.T) {
	codec := NewTwilicCodec()
	payload := []byte{0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4}
	for _, c := range []ControlStreamCodec{
		ControlStreamCodecPlain,
		ControlStreamCodecRle,
		ControlStreamCodecBitpack,
		ControlStreamCodecHuffman,
		ControlStreamCodecFse,
	} {
		msg := Message{
			Kind:          MessageKindControlStream,
			ControlStream: &ControlStreamMessage{Codec: c, Payload: append([]byte(nil), payload...)},
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
			t.Fatalf("control stream mismatch for codec %v", c)
		}
	}
}

func TestControlStreamAndControlSpec_ControlStreamBitpackHuffmanFseCompactRepetitivePayloads(t *testing.T) {
	binaryPayload := make([]byte, 512)
	for i := range binaryPayload {
		binaryPayload[i] = byte(i % 2)
	}
	plainBinaryLen := encodedControlStreamLen(ControlStreamCodecPlain, append([]byte(nil), binaryPayload...))
	bitpackLen := encodedControlStreamLen(ControlStreamCodecBitpack, append([]byte(nil), binaryPayload...))
	if bitpackLen > plainBinaryLen {
		t.Fatalf("expected bitpack <= plain for binary payload")
	}

	rleFriendly := make([]byte, 512)
	for i := range rleFriendly {
		rleFriendly[i] = 7
	}
	plainRLELen := encodedControlStreamLen(ControlStreamCodecPlain, append([]byte(nil), rleFriendly...))
	huffmanLen := encodedControlStreamLen(ControlStreamCodecHuffman, append([]byte(nil), rleFriendly...))
	if huffmanLen > plainRLELen {
		t.Fatalf("expected huffman <= plain for repetitive payload")
	}

	lowCard := make([]byte, 512)
	for i := range lowCard {
		lowCard[i] = byte(i % 4)
	}
	plainLowCardLen := encodedControlStreamLen(ControlStreamCodecPlain, append([]byte(nil), lowCard...))
	fseLen := encodedControlStreamLen(ControlStreamCodecFse, append([]byte(nil), lowCard...))
	if fseLen > plainLowCardLen {
		t.Fatalf("expected fse <= plain for low-cardinality payload")
	}
}

func TestControlStreamAndControlSpec_ControlStreamFseUsesFseFrameMode(t *testing.T) {
	codec := NewTwilicCodec()
	payload := make([]byte, 512)
	for i := range payload {
		payload[i] = byte(i % 4)
	}
	msg := Message{
		Kind:          MessageKindControlStream,
		ControlStream: &ControlStreamMessage{Codec: ControlStreamCodecFse, Payload: payload},
	}
	bytes, err := codec.EncodeMessage(&msg)
	if err != nil {
		t.Fatalf("encode fse control stream: %v", err)
	}
	reader := newReader(bytes)
	kind, _ := reader.readU8()
	if kind != byte(MessageKindControlStream) {
		t.Fatalf("expected control stream kind, got %d", kind)
	}
	codecByte, _ := reader.readU8()
	if codecByte != byte(ControlStreamCodecFse) {
		t.Fatalf("expected fse codec byte, got %d", codecByte)
	}
	framed, err := reader.readBytes()
	if err != nil {
		t.Fatalf("read framed payload: %v", err)
	}
	if len(framed) == 0 {
		t.Fatalf("expected non-empty framed payload")
	}
}

func TestControlStreamAndControlSpec_RegisterShapeWithKeyIDsRoundtrips(t *testing.T) {
	codec := NewTwilicCodec()
	regKeys := Message{
		Kind: MessageKindControl,
		Control: &ControlMessage{
			Opcode:       ControlOpcodeRegisterKeys,
			RegisterKeys: []string{"id", "name"},
		},
	}
	regKeysBytes, err := codec.EncodeMessage(&regKeys)
	if err != nil {
		t.Fatalf("encode register keys: %v", err)
	}
	if _, err := codec.DecodeMessage(regKeysBytes); err != nil {
		t.Fatalf("decode register keys: %v", err)
	}

	regShape := Message{
		Kind: MessageKindControl,
		Control: &ControlMessage{
			Opcode: ControlOpcodeRegisterShape,
			RegisterShape: &RegisterShapeControl{
				ShapeID: 99,
				Keys:    []KeyRef{KeyRefID(0), KeyRefID(1)},
			},
		},
	}
	regShapeBytes, err := codec.EncodeMessage(&regShape)
	if err != nil {
		t.Fatalf("encode register shape: %v", err)
	}
	decoded, err := codec.DecodeMessage(regShapeBytes)
	if err != nil {
		t.Fatalf("decode register shape: %v", err)
	}
	if decoded.Kind != MessageKindControl || decoded.Control.RegisterShape == nil {
		t.Fatalf("expected register-shape control")
	}

	shaped := Message{
		Kind: MessageKindShapedObject,
		ShapedObject: &ShapedObjectMessage{
			ShapeID: 99,
			Values:  []Value{NewU64(1), NewString("alice")},
		},
	}
	shapedBytes, err := codec.EncodeMessage(&shaped)
	if err != nil {
		t.Fatalf("encode shaped: %v", err)
	}
	value, err := codec.DecodeValue(shapedBytes)
	if err != nil {
		t.Fatalf("decode shaped value: %v", err)
	}
	if value.Kind != ValueMap {
		t.Fatalf("expected map-shaped value")
	}
}

func TestControlStreamAndControlSpec_ResetStateClearsShapeResolution(t *testing.T) {
	codec := NewTwilicCodec()
	regShape := Message{
		Kind: MessageKindControl,
		Control: &ControlMessage{
			Opcode: ControlOpcodeRegisterShape,
			RegisterShape: &RegisterShapeControl{
				ShapeID: 7,
				Keys: []KeyRef{
					KeyRefLiteral("id"),
					KeyRefLiteral("name"),
				},
			},
		},
	}
	regBytes, err := codec.EncodeMessage(&regShape)
	if err != nil {
		t.Fatalf("encode register shape: %v", err)
	}
	if _, err := codec.DecodeMessage(regBytes); err != nil {
		t.Fatalf("decode register shape: %v", err)
	}

	reset := Message{
		Kind: MessageKindControl,
		Control: &ControlMessage{
			Opcode:     ControlOpcodeResetState,
			ResetState: true,
		},
	}
	resetBytes, err := codec.EncodeMessage(&reset)
	if err != nil {
		t.Fatalf("encode reset state: %v", err)
	}
	if _, err := codec.DecodeMessage(resetBytes); err != nil {
		t.Fatalf("decode reset state: %v", err)
	}

	shaped := Message{
		Kind: MessageKindShapedObject,
		ShapedObject: &ShapedObjectMessage{
			ShapeID: 7,
			Values:  []Value{NewU64(1), NewString("alice")},
		},
	}
	shapedBytes, err := codec.EncodeMessage(&shaped)
	if err != nil {
		t.Fatalf("encode shaped: %v", err)
	}
	_, err = codec.DecodeValue(shapedBytes)
	te := requireTwilicErrorKind(t, err, ErrUnknownReference)
	if te.RefKind != "shape_id" || te.RefID != 7 {
		t.Fatalf("unexpected reference error: %+v", te)
	}
}
