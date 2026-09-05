package twilic

import "github.com/twilic/twilic-go/internal/core"

// Public API re-exports from internal/core.
// Keep this as the only alias file in package twilic (do not add types.go with the same declarations).

// Types
type (
	MessageKind            = core.MessageKind
	ValueKind              = core.ValueKind
	Value                  = core.Value
	MapEntry               = core.MapEntry
	MessageMapEntry        = core.MessageMapEntry
	KeyRef                 = core.KeyRef
	StringMode             = core.StringMode
	StringValue            = core.StringValue
	ElementType            = core.ElementType
	VectorCodec            = core.VectorCodec
	TypedVectorData        = core.TypedVectorData
	TypedVector            = core.TypedVector
	SchemaField            = core.SchemaField
	Schema                 = core.Schema
	NullStrategy           = core.NullStrategy
	Column                 = core.Column
	PresenceStrategy       = core.PresenceStrategy
	BoundRecord            = core.BoundRecord
	ControlOpcode          = core.ControlOpcode
	ControlMessage         = core.ControlMessage
	RegisterShapeControl   = core.RegisterShapeControl
	PromoteEnumControl     = core.PromoteEnumControl
	PatchOpcode            = core.PatchOpcode
	BaseRef                = core.BaseRef
	PatchOperation         = core.PatchOperation
	ControlStreamCodec     = core.ControlStreamCodec
	Message                = core.Message
	ShapedObjectMessage    = core.ShapedObjectMessage
	SchemaObjectMessage    = core.SchemaObjectMessage
	RowBatchMessage        = core.RowBatchMessage
	ColumnBatchMessage     = core.ColumnBatchMessage
	SchemaBatchMessage     = core.SchemaBatchMessage
	BoundStreamMessage     = core.BoundStreamMessage
	ExtMessage             = core.ExtMessage
	StatePatchMessage      = core.StatePatchMessage
	TemplateBatchMessage   = core.TemplateBatchMessage
	ControlStreamMessage   = core.ControlStreamMessage
	BaseSnapshotMessage    = core.BaseSnapshotMessage
	TemplateDescriptor     = core.TemplateDescriptor
	TwilicError            = core.TwilicError
	TwilicErrorKind        = core.TwilicErrorKind
	UnknownReferencePolicy = core.UnknownReferencePolicy
	DictionaryFallback     = core.DictionaryFallback
	DictionaryProfile      = core.DictionaryProfile
	SessionOptions         = core.SessionOptions
	SessionState           = core.SessionState
	TwilicCodec            = core.TwilicCodec
	SessionEncoder         = core.SessionEncoder
)

// Message kinds
const (
	MessageKindScalar        = core.MessageKindScalar
	MessageKindArray         = core.MessageKindArray
	MessageKindMap           = core.MessageKindMap
	MessageKindShapedObject  = core.MessageKindShapedObject
	MessageKindSchemaObject  = core.MessageKindSchemaObject
	MessageKindTypedVector   = core.MessageKindTypedVector
	MessageKindRowBatch      = core.MessageKindRowBatch
	MessageKindColumnBatch   = core.MessageKindColumnBatch
	MessageKindControl       = core.MessageKindControl
	MessageKindExt           = core.MessageKindExt
	MessageKindStatePatch    = core.MessageKindStatePatch
	MessageKindTemplateBatch = core.MessageKindTemplateBatch
	MessageKindControlStream = core.MessageKindControlStream
	MessageKindBaseSnapshot  = core.MessageKindBaseSnapshot
	MessageKindSchemaBatch   = core.MessageKindSchemaBatch
	MessageKindBoundStream   = core.MessageKindBoundStream
)

// Value kinds
const (
	ValueNull   = core.ValueNull
	ValueBool   = core.ValueBool
	ValueI64    = core.ValueI64
	ValueU64    = core.ValueU64
	ValueF64    = core.ValueF64
	ValueString = core.ValueString
	ValueBinary = core.ValueBinary
	ValueArray  = core.ValueArray
	ValueMap    = core.ValueMap
)

// String modes
const (
	StringModeEmpty       = core.StringModeEmpty
	StringModeLiteral     = core.StringModeLiteral
	StringModeRef         = core.StringModeRef
	StringModePrefixDelta = core.StringModePrefixDelta
	StringModeInlineEnum  = core.StringModeInlineEnum
)

// Element types
const (
	ElementTypeBool   = core.ElementTypeBool
	ElementTypeI64    = core.ElementTypeI64
	ElementTypeU64    = core.ElementTypeU64
	ElementTypeF64    = core.ElementTypeF64
	ElementTypeString = core.ElementTypeString
	ElementTypeBinary = core.ElementTypeBinary
	ElementTypeValue  = core.ElementTypeValue
)

// Vector codecs
const (
	VectorCodecPlain             = core.VectorCodecPlain
	VectorCodecDirectBitpack     = core.VectorCodecDirectBitpack
	VectorCodecDeltaBitpack      = core.VectorCodecDeltaBitpack
	VectorCodecForBitpack        = core.VectorCodecForBitpack
	VectorCodecDeltaForBitpack   = core.VectorCodecDeltaForBitpack
	VectorCodecDeltaDeltaBitpack = core.VectorCodecDeltaDeltaBitpack
	VectorCodecRle               = core.VectorCodecRle
	VectorCodecPatchedFor        = core.VectorCodecPatchedFor
	VectorCodecSimple8b          = core.VectorCodecSimple8b
	VectorCodecXorFloat          = core.VectorCodecXorFloat
	VectorCodecDictionary        = core.VectorCodecDictionary
	VectorCodecStringRef         = core.VectorCodecStringRef
	VectorCodecPrefixDelta       = core.VectorCodecPrefixDelta
)

// Null strategies
const (
	NullStrategyNone                   = core.NullStrategyNone
	NullStrategyPresenceBitmap         = core.NullStrategyPresenceBitmap
	NullStrategyInvertedPresenceBitmap = core.NullStrategyInvertedPresenceBitmap
	NullStrategyAllPresentElided       = core.NullStrategyAllPresentElided
)

// Presence strategies
const (
	PresenceStrategyNormal     = core.PresenceStrategyNormal
	PresenceStrategyInverted   = core.PresenceStrategyInverted
	PresenceStrategyAllPresent = core.PresenceStrategyAllPresent
)

// Control opcodes
const (
	ControlOpcodeRegisterKeys             = core.ControlOpcodeRegisterKeys
	ControlOpcodeRegisterShape            = core.ControlOpcodeRegisterShape
	ControlOpcodeRegisterStrings          = core.ControlOpcodeRegisterStrings
	ControlOpcodePromoteStringFieldToEnum = core.ControlOpcodePromoteStringFieldToEnum
	ControlOpcodeResetTables              = core.ControlOpcodeResetTables
	ControlOpcodeResetState               = core.ControlOpcodeResetState
)

// Patch opcodes
const (
	PatchOpcodeKeep           = core.PatchOpcodeKeep
	PatchOpcodeReplaceScalar  = core.PatchOpcodeReplaceScalar
	PatchOpcodeReplaceVector  = core.PatchOpcodeReplaceVector
	PatchOpcodeAppendVector   = core.PatchOpcodeAppendVector
	PatchOpcodeTruncateVector = core.PatchOpcodeTruncateVector
	PatchOpcodeDeleteField    = core.PatchOpcodeDeleteField
	PatchOpcodeInsertField    = core.PatchOpcodeInsertField
	PatchOpcodeStringRef      = core.PatchOpcodeStringRef
	PatchOpcodePrefixDelta    = core.PatchOpcodePrefixDelta
)

// Control stream codecs
const (
	ControlStreamCodecPlain   = core.ControlStreamCodecPlain
	ControlStreamCodecRle     = core.ControlStreamCodecRle
	ControlStreamCodecBitpack = core.ControlStreamCodecBitpack
	ControlStreamCodecHuffman = core.ControlStreamCodecHuffman
	ControlStreamCodecFse     = core.ControlStreamCodecFse
)

// Errors
const (
	ErrUnexpectedEOF          = core.ErrUnexpectedEOF
	ErrInvalidKind            = core.ErrInvalidKind
	ErrInvalidTag             = core.ErrInvalidTag
	ErrInvalidData            = core.ErrInvalidData
	ErrUTF8                   = core.ErrUTF8
	ErrUnknownReference       = core.ErrUnknownReference
	ErrStatelessRetryRequired = core.ErrStatelessRetryRequired
)

// Session / dictionary
const (
	UnknownReferencePolicyFailFast       = core.UnknownReferencePolicyFailFast
	UnknownReferencePolicyStatelessRetry = core.UnknownReferencePolicyStatelessRetry
	DictionaryFallbackFailFast           = core.DictionaryFallbackFailFast
	DictionaryFallbackStatelessRetry     = core.DictionaryFallbackStatelessRetry
)

// Encode encodes a dynamic value using the v3 Dynamic Profile.
func Encode(value Value) ([]byte, error) {
	return core.Encode(value)
}

// Decode decodes a dynamic value using the v3 Dynamic Profile.
func Decode(bytes []byte) (Value, error) {
	return core.Decode(bytes)
}

// EncodeWithSchema encodes a value with the given schema using a fresh session encoder.
func EncodeWithSchema(schema *Schema, value Value) ([]byte, error) {
	return core.EncodeWithSchema(schema, value)
}

// EncodeBatch encodes multiple values as a batch using a fresh session encoder.
func EncodeBatch(values []Value) ([]byte, error) {
	return core.EncodeBatch(values)
}

// EncodeBoundStream encodes values as a v3 schema-bound compact stream.
func EncodeBoundStream(schema *Schema, values []Value) ([]byte, error) {
	return core.EncodeBoundStream(schema, values)
}

// EncodeBatchWithSchema encodes values as a v3 schema-aware columnar batch.
func EncodeBatchWithSchema(schema *Schema, values []Value) ([]byte, error) {
	return core.EncodeBatchWithSchema(schema, values)
}

func NewNull() Value                         { return core.NewNull() }
func NewBool(b bool) Value                   { return core.NewBool(b) }
func NewI64(n int64) Value                   { return core.NewI64(n) }
func NewU64(n uint64) Value                  { return core.NewU64(n) }
func NewF64(n float64) Value                 { return core.NewF64(n) }
func NewString(s string) Value               { return core.NewString(s) }
func NewBinary(b []byte) Value               { return core.NewBinary(b) }
func NewArray(items []Value) Value           { return core.NewArray(items) }
func Entry(key string, value Value) MapEntry { return core.Entry(key, value) }
func NewMap(entries ...MapEntry) Value       { return core.NewMap(entries...) }
func Equal(a, b Value) bool                  { return core.Equal(a, b) }
func KeyRefLiteral(s string) KeyRef          { return core.KeyRefLiteral(s) }
func KeyRefID(id uint64) KeyRef              { return core.KeyRefID(id) }
func BaseRefPrevious() BaseRef               { return core.BaseRefPrevious() }
func BaseRefID(id uint64) BaseRef            { return core.BaseRefID(id) }
func DefaultSessionOptions() SessionOptions  { return core.DefaultSessionOptions() }
func NewTwilicCodec() *TwilicCodec           { return core.NewTwilicCodec() }
func TwilicCodecWithOptions(options SessionOptions) *TwilicCodec {
	return core.TwilicCodecWithOptions(options)
}
func NewSessionEncoder(options SessionOptions) *SessionEncoder {
	return core.NewSessionEncoder(options)
}

// ResetEncodeShapeObservation clears encode-side shape promotion counters for the given field names.
func ResetEncodeShapeObservation(codec *TwilicCodec, keys []string) {
	core.ResetEncodeShapeObservation(codec, keys)
}
