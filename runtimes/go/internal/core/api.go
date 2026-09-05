package core

// Encode encodes a dynamic value using the v3 Dynamic Profile.
func Encode(value Value) ([]byte, error) {
	return encodeV2(value)
}

// Decode decodes a dynamic value using the v3 Dynamic Profile.
func Decode(bytes []byte) (Value, error) {
	return decodeV2(bytes)
}

// EncodeWithSchema encodes a value with the given schema using a fresh session encoder.
func EncodeWithSchema(schema *Schema, value Value) ([]byte, error) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	v := value
	return enc.EncodeWithSchema(schema, &v)
}

// EncodeBatch encodes multiple values as a batch using a fresh session encoder.
func EncodeBatch(values []Value) ([]byte, error) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	return enc.EncodeBatch(values)
}

// EncodeBoundStream encodes values as a v3 schema-bound compact stream.
func EncodeBoundStream(schema *Schema, values []Value) ([]byte, error) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	return enc.EncodeBoundStream(schema, values)
}

// EncodeBatchWithSchema encodes values as a v3 schema-aware columnar batch.
func EncodeBatchWithSchema(schema *Schema, values []Value) ([]byte, error) {
	enc := NewSessionEncoder(DefaultSessionOptions())
	return enc.EncodeBatchWithSchema(schema, values)
}
