package core

import "testing"

func v3SparseSchema() *Schema {
	return &Schema{
		SchemaID: 41,
		Name:     "User",
		Fields: []SchemaField{
			{Number: 99, Name: "id", LogicalType: "u64", Required: true},
			{Number: 100, Name: "name", LogicalType: "string", Required: true},
			{Number: 101, Name: "score", LogicalType: "i64", Required: false},
		},
	}
}

func v3Rows() []Value {
	return []Value{
		NewMap(
			Entry("id", NewU64(1)),
			Entry("name", NewString("alice")),
			Entry("score", NewI64(10)),
		),
		NewMap(
			Entry("id", NewU64(2)),
			Entry("name", NewString("bob")),
		),
	}
}

func TestV3Migration_DynamicRejectsOverlongVaruintRefs(t *testing.T) {
	bytes := []byte{0xB2, 0x81, 'a', 0x01, 0xD8, 0x80, 0x00, 0x02}
	_, err := Decode(bytes)
	te := requireTwilicErrorKind(t, err, ErrInvalidData)
	if te.Msg != "varuint overlong" {
		t.Fatalf("unexpected message %q", te.Msg)
	}
}

func TestV3Migration_DynamicRejectsNonCanonicalIntegerWidths(t *testing.T) {
	_, err := Decode([]byte{0xC4, 0x7F})
	te := requireTwilicErrorKind(t, err, ErrInvalidData)
	if te.Msg != "non-canonical integer encoding" {
		t.Fatalf("unexpected message %q", te.Msg)
	}

	_, err = Decode([]byte{0xC8, 0xFF})
	te = requireTwilicErrorKind(t, err, ErrInvalidData)
	if te.Msg != "non-canonical integer encoding" {
		t.Fatalf("unexpected message %q", te.Msg)
	}
}

func TestV3Migration_TwilicPVRejectsOverlongAndAcceptsMaxU64(t *testing.T) {
	overlong := newReader([]byte{0x80, 0x00})
	_, err := overlong.readVaruint()
	te := requireTwilicErrorKind(t, err, ErrInvalidData)
	if te.Msg != "varuint overlong" {
		t.Fatalf("unexpected message %q", te.Msg)
	}

	var encoded []byte
	encodeVaruint(^uint64(0), &encoded)
	reader := newReader(encoded)
	got, err := reader.readVaruint()
	if err != nil {
		t.Fatalf("read u64 max: %v", err)
	}
	if got != ^uint64(0) {
		t.Fatalf("got %d", got)
	}
}

func TestV3Migration_SchemaBatchUsesSchemaOrderEnvelope(t *testing.T) {
	schema := v3SparseSchema()
	enc := NewSessionEncoder(DefaultSessionOptions())
	bytes, err := enc.EncodeBatchWithSchema(schema, v3Rows())
	if err != nil {
		t.Fatalf("encode schema batch: %v", err)
	}
	if len(bytes) == 0 || bytes[0] != byte(MessageKindSchemaBatch) {
		t.Fatalf("expected schema batch kind")
	}

	reader := newReader(bytes)
	kind, _ := reader.readU8()
	if kind != byte(MessageKindSchemaBatch) {
		t.Fatalf("kind mismatch")
	}
	schemaID, _ := reader.readVaruint()
	count, _ := reader.readVaruint()
	columnCount, _ := reader.readVaruint()
	if schemaID != 41 || count != 2 || columnCount != 3 {
		t.Fatalf("unexpected envelope schema=%d count=%d columns=%d", schemaID, count, columnCount)
	}
	nullStrategy, _ := reader.readU8()
	if nullStrategy != 0 {
		t.Fatalf("expected first column null strategy 0, got %d", nullStrategy)
	}

	decoded, err := enc.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode schema batch: %v", err)
	}
	if decoded.Kind != MessageKindSchemaBatch || decoded.SchemaBatch.SchemaID != 41 || decoded.SchemaBatch.Count != 2 {
		t.Fatalf("unexpected decoded schema batch")
	}
	if decoded.SchemaBatch.Columns[0].FieldID != 99 {
		t.Fatalf("expected schema field number 99")
	}
	if decoded.SchemaBatch.Columns[2].NullStrategy != NullStrategyPresenceBitmap {
		t.Fatalf("expected optional score presence bitmap")
	}
}

func TestV3Migration_BoundStreamUsesNewEnvelopeKind(t *testing.T) {
	schema := v3SparseSchema()
	enc := NewSessionEncoder(DefaultSessionOptions())
	bytes, err := enc.EncodeBoundStream(schema, v3Rows())
	if err != nil {
		t.Fatalf("encode bound stream: %v", err)
	}
	if len(bytes) == 0 || bytes[0] != byte(MessageKindBoundStream) {
		t.Fatalf("expected bound stream kind")
	}

	decoded, err := enc.DecodeMessage(bytes)
	if err != nil {
		t.Fatalf("decode bound stream: %v", err)
	}
	if decoded.Kind != MessageKindBoundStream || decoded.BoundStream.SchemaID != 41 {
		t.Fatalf("unexpected decoded bound stream")
	}
	if decoded.BoundStream.PresenceStrategy != PresenceStrategyNormal {
		t.Fatalf("expected normal presence strategy")
	}
	if len(decoded.BoundStream.Records) != 2 || len(decoded.BoundStream.Records[0].Fields) != 3 || len(decoded.BoundStream.Records[1].Fields) != 2 {
		t.Fatalf("unexpected records")
	}
}

func TestV3Migration_BoundStreamRequiresSchemaContextOnDecode(t *testing.T) {
	schema := v3SparseSchema()
	enc := NewSessionEncoder(DefaultSessionOptions())
	bytes, err := enc.EncodeBoundStream(schema, []Value{NewMap(Entry("id", NewU64(1)), Entry("name", NewString("alice")))})
	if err != nil {
		t.Fatalf("encode bound stream: %v", err)
	}

	fresh := NewTwilicCodec()
	_, err = fresh.DecodeMessage(bytes)
	te := requireTwilicErrorKind(t, err, ErrUnknownReference)
	if te.RefKind != "schema_id" || te.RefID != 41 {
		t.Fatalf("unexpected reference error: %+v", te)
	}
}
