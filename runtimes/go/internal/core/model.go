package core

type MessageKind byte

const (
	MessageKindScalar        MessageKind = 0x00
	MessageKindArray         MessageKind = 0x01
	MessageKindMap           MessageKind = 0x02
	MessageKindShapedObject  MessageKind = 0x03
	MessageKindSchemaObject  MessageKind = 0x04
	MessageKindTypedVector   MessageKind = 0x05
	MessageKindRowBatch      MessageKind = 0x06
	MessageKindColumnBatch   MessageKind = 0x07
	MessageKindControl       MessageKind = 0x08
	MessageKindExt           MessageKind = 0x09
	MessageKindStatePatch    MessageKind = 0x0A
	MessageKindTemplateBatch MessageKind = 0x0B
	MessageKindControlStream MessageKind = 0x0C
	MessageKindBaseSnapshot  MessageKind = 0x0D
	MessageKindSchemaBatch   MessageKind = 0x0E
	MessageKindBoundStream   MessageKind = 0x0F
)

func messageKindFromByte(b byte) (MessageKind, bool) {
	switch b {
	case 0x00:
		return MessageKindScalar, true
	case 0x01:
		return MessageKindArray, true
	case 0x02:
		return MessageKindMap, true
	case 0x03:
		return MessageKindShapedObject, true
	case 0x04:
		return MessageKindSchemaObject, true
	case 0x05:
		return MessageKindTypedVector, true
	case 0x06:
		return MessageKindRowBatch, true
	case 0x07:
		return MessageKindColumnBatch, true
	case 0x08:
		return MessageKindControl, true
	case 0x09:
		return MessageKindExt, true
	case 0x0A:
		return MessageKindStatePatch, true
	case 0x0B:
		return MessageKindTemplateBatch, true
	case 0x0C:
		return MessageKindControlStream, true
	case 0x0D:
		return MessageKindBaseSnapshot, true
	case 0x0E:
		return MessageKindSchemaBatch, true
	case 0x0F:
		return MessageKindBoundStream, true
	default:
		return 0, false
	}
}

type ValueKind int

const (
	ValueNull ValueKind = iota
	ValueBool
	ValueI64
	ValueU64
	ValueF64
	ValueString
	ValueBinary
	ValueArray
	ValueMap
)

type Value struct {
	Kind ValueKind
	Bool bool
	I64  int64
	U64  uint64
	F64  float64
	Str  string
	Bin  []byte
	Arr  []Value
	Map  []MapEntry
}

type MapEntry struct {
	Key   string
	Value Value
}

// MessageMapEntry is a map entry in protocol messages (key may be literal or interned id).
type MessageMapEntry struct {
	Key   KeyRef
	Value Value
}

func (v Value) IsScalar() bool {
	return v.Kind != ValueArray && v.Kind != ValueMap
}

func NewNull() Value {
	return Value{Kind: ValueNull}
}

func NewBool(b bool) Value {
	return Value{Kind: ValueBool, Bool: b}
}

func NewI64(n int64) Value {
	return Value{Kind: ValueI64, I64: n}
}

func NewU64(n uint64) Value {
	return Value{Kind: ValueU64, U64: n}
}

func NewF64(n float64) Value {
	return Value{Kind: ValueF64, F64: n}
}

func NewString(s string) Value {
	return Value{Kind: ValueString, Str: s}
}

func NewBinary(b []byte) Value {
	return Value{Kind: ValueBinary, Bin: append([]byte(nil), b...)}
}

func NewArray(items []Value) Value {
	cloned := make([]Value, len(items))
	for i := range items {
		cloned[i] = items[i].Clone()
	}
	return Value{Kind: ValueArray, Arr: cloned}
}

func Entry(key string, value Value) MapEntry {
	return MapEntry{Key: key, Value: value}
}

func NewMap(entries ...MapEntry) Value {
	cloned := make([]MapEntry, len(entries))
	for i := range entries {
		cloned[i] = MapEntry{Key: entries[i].Key, Value: entries[i].Value.Clone()}
	}
	return Value{Kind: ValueMap, Map: cloned}
}

func (v Value) Clone() Value {
	switch v.Kind {
	case ValueNull, ValueBool, ValueI64, ValueU64, ValueF64, ValueString:
		out := v
		return out
	case ValueBinary:
		return Value{Kind: ValueBinary, Bin: append([]byte(nil), v.Bin...)}
	case ValueArray:
		arr := make([]Value, len(v.Arr))
		for i := range v.Arr {
			arr[i] = v.Arr[i].Clone()
		}
		return Value{Kind: ValueArray, Arr: arr}
	case ValueMap:
		m := make([]MapEntry, len(v.Map))
		for i := range v.Map {
			m[i] = MapEntry{Key: v.Map[i].Key, Value: v.Map[i].Value.Clone()}
		}
		return Value{Kind: ValueMap, Map: m}
	default:
		return Value{}
	}
}

func Equal(a, b Value) bool {
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case ValueNull:
		return true
	case ValueBool:
		return a.Bool == b.Bool
	case ValueI64:
		return a.I64 == b.I64
	case ValueU64:
		return a.U64 == b.U64
	case ValueF64:
		return a.F64 == b.F64
	case ValueString:
		return a.Str == b.Str
	case ValueBinary:
		return bytesEqual(a.Bin, b.Bin)
	case ValueArray:
		if len(a.Arr) != len(b.Arr) {
			return false
		}
		for i := range a.Arr {
			if !Equal(a.Arr[i], b.Arr[i]) {
				return false
			}
		}
		return true
	case ValueMap:
		if len(a.Map) != len(b.Map) {
			return false
		}
		for i := range a.Map {
			if a.Map[i].Key != b.Map[i].Key || !Equal(a.Map[i].Value, b.Map[i].Value) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

type KeyRef struct {
	Literal string
	ID      uint64
	IsID    bool
}

func KeyRefLiteral(s string) KeyRef {
	return KeyRef{Literal: s}
}

func KeyRefID(id uint64) KeyRef {
	return KeyRef{ID: id, IsID: true}
}

type StringMode byte

const (
	StringModeEmpty       StringMode = 0
	StringModeLiteral     StringMode = 1
	StringModeRef         StringMode = 2
	StringModePrefixDelta StringMode = 3
	StringModeInlineEnum  StringMode = 4
)

func stringModeFromByte(b byte) (StringMode, bool) {
	switch b {
	case 0, 1, 2, 3, 4:
		return StringMode(b), true
	default:
		return 0, false
	}
}

type StringValue struct {
	Mode      StringMode
	Value     string
	RefID     *uint64
	PrefixLen *uint64
}

type ElementType byte

const (
	ElementTypeBool   ElementType = 0
	ElementTypeI64    ElementType = 1
	ElementTypeU64    ElementType = 2
	ElementTypeF64    ElementType = 3
	ElementTypeString ElementType = 4
	ElementTypeBinary ElementType = 5
	ElementTypeValue  ElementType = 6
)

func elementTypeFromByte(b byte) (ElementType, bool) {
	switch b {
	case 0, 1, 2, 3, 4, 5, 6:
		return ElementType(b), true
	default:
		return 0, false
	}
}

type VectorCodec byte

const (
	VectorCodecPlain             VectorCodec = 0
	VectorCodecDirectBitpack     VectorCodec = 1
	VectorCodecDeltaBitpack      VectorCodec = 2
	VectorCodecForBitpack        VectorCodec = 3
	VectorCodecDeltaForBitpack   VectorCodec = 4
	VectorCodecDeltaDeltaBitpack VectorCodec = 5
	VectorCodecRle               VectorCodec = 6
	VectorCodecPatchedFor        VectorCodec = 7
	VectorCodecSimple8b          VectorCodec = 8
	VectorCodecXorFloat          VectorCodec = 9
	VectorCodecDictionary        VectorCodec = 10
	VectorCodecStringRef         VectorCodec = 11
	VectorCodecPrefixDelta       VectorCodec = 12
)

func vectorCodecFromByte(b byte) (VectorCodec, bool) {
	if b <= 12 {
		return VectorCodec(b), true
	}
	return 0, false
}

type TypedVectorData struct {
	Bools   []bool
	I64s    []int64
	U64s    []uint64
	F64s    []float64
	Strings []string
	Binary  [][]byte
	Values  []Value
	Kind    ElementType
}

type TypedVector struct {
	ElementType ElementType
	Codec       VectorCodec
	Data        TypedVectorData
}

type SchemaField struct {
	Number       uint64
	Name         string
	LogicalType  string
	Required     bool
	DefaultValue *Value
	Min          *int64
	Max          *int64
	EnumValues   []string
}

type Schema struct {
	SchemaID uint64
	Name     string
	Fields   []SchemaField
}

type NullStrategy byte

const (
	NullStrategyNone                   NullStrategy = 0
	NullStrategyPresenceBitmap         NullStrategy = 1
	NullStrategyInvertedPresenceBitmap NullStrategy = 2
	NullStrategyAllPresentElided       NullStrategy = 3
)

func nullStrategyFromByte(b byte) (NullStrategy, bool) {
	switch b {
	case 0, 1, 2, 3:
		return NullStrategy(b), true
	default:
		return 0, false
	}
}

type Column struct {
	FieldID      uint64
	NullStrategy NullStrategy
	Presence     []bool
	HasPresence  bool
	Codec        VectorCodec
	DictionaryID *uint64
	Values       TypedVectorData
}

type PresenceStrategy byte

const (
	PresenceStrategyNormal     PresenceStrategy = 0
	PresenceStrategyInverted   PresenceStrategy = 1
	PresenceStrategyAllPresent PresenceStrategy = 2
)

func presenceStrategyFromByte(b byte) (PresenceStrategy, bool) {
	switch b {
	case 0, 1, 2:
		return PresenceStrategy(b), true
	default:
		return 0, false
	}
}

type BoundRecord struct {
	Presence    []bool
	HasPresence bool
	Fields      []Value
}

type ControlOpcode byte

const (
	ControlOpcodeRegisterKeys             ControlOpcode = 0
	ControlOpcodeRegisterShape            ControlOpcode = 1
	ControlOpcodeRegisterStrings          ControlOpcode = 2
	ControlOpcodePromoteStringFieldToEnum ControlOpcode = 3
	ControlOpcodeResetTables              ControlOpcode = 4
	ControlOpcodeResetState               ControlOpcode = 5
)

func controlOpcodeFromByte(b byte) (ControlOpcode, bool) {
	switch b {
	case 0, 1, 2, 3, 4, 5:
		return ControlOpcode(b), true
	default:
		return 0, false
	}
}

type ControlMessage struct {
	RegisterKeys             []string
	RegisterShape            *RegisterShapeControl
	RegisterStrings          []string
	PromoteStringFieldToEnum *PromoteEnumControl
	ResetTables              bool
	ResetState               bool
	Opcode                   ControlOpcode
}

type RegisterShapeControl struct {
	ShapeID uint64
	Keys    []KeyRef
}

type PromoteEnumControl struct {
	FieldIdentity string
	Values        []string
}

type PatchOpcode byte

const (
	PatchOpcodeKeep           PatchOpcode = 0
	PatchOpcodeReplaceScalar  PatchOpcode = 1
	PatchOpcodeReplaceVector  PatchOpcode = 2
	PatchOpcodeAppendVector   PatchOpcode = 3
	PatchOpcodeTruncateVector PatchOpcode = 4
	PatchOpcodeDeleteField    PatchOpcode = 5
	PatchOpcodeInsertField    PatchOpcode = 6
	PatchOpcodeStringRef      PatchOpcode = 7
	PatchOpcodePrefixDelta    PatchOpcode = 8
)

func patchOpcodeFromByte(b byte) (PatchOpcode, bool) {
	if b <= 8 {
		return PatchOpcode(b), true
	}
	return 0, false
}

type BaseRef struct {
	Previous bool
	BaseID   uint64
}

func BaseRefPrevious() BaseRef {
	return BaseRef{Previous: true}
}

func BaseRefID(id uint64) BaseRef {
	return BaseRef{BaseID: id}
}

type PatchOperation struct {
	FieldID uint64
	Opcode  PatchOpcode
	Value   *Value
}

type ControlStreamCodec byte

const (
	ControlStreamCodecPlain   ControlStreamCodec = 0
	ControlStreamCodecRle     ControlStreamCodec = 1
	ControlStreamCodecBitpack ControlStreamCodec = 2
	ControlStreamCodecHuffman ControlStreamCodec = 3
	ControlStreamCodecFse     ControlStreamCodec = 4
)

func controlStreamCodecFromByte(b byte) (ControlStreamCodec, bool) {
	if b <= 4 {
		return ControlStreamCodec(b), true
	}
	return 0, false
}

type Message struct {
	Scalar        *Value
	Array         []Value
	Map           []MessageMapEntry
	ShapedObject  *ShapedObjectMessage
	SchemaObject  *SchemaObjectMessage
	TypedVector   *TypedVector
	RowBatch      *RowBatchMessage
	ColumnBatch   *ColumnBatchMessage
	SchemaBatch   *SchemaBatchMessage
	BoundStream   *BoundStreamMessage
	Control       *ControlMessage
	Ext           *ExtMessage
	StatePatch    *StatePatchMessage
	TemplateBatch *TemplateBatchMessage
	ControlStream *ControlStreamMessage
	BaseSnapshot  *BaseSnapshotMessage
	Kind          MessageKind
}

type ShapedObjectMessage struct {
	ShapeID     uint64
	Presence    []bool
	HasPresence bool
	Values      []Value
}

type SchemaObjectMessage struct {
	SchemaID    *uint64
	Presence    []bool
	HasPresence bool
	Fields      []Value
}

type RowBatchMessage struct {
	Rows [][]Value
}

type ColumnBatchMessage struct {
	Count   uint64
	Columns []Column
}

type SchemaBatchMessage struct {
	SchemaID uint64
	Count    uint64
	Columns  []Column
}

type BoundStreamMessage struct {
	SchemaID         uint64
	PresenceStrategy PresenceStrategy
	Records          []BoundRecord
}

type ExtMessage struct {
	ExtType uint64
	Payload []byte
}

type StatePatchMessage struct {
	BaseRef    BaseRef
	Operations []PatchOperation
	Literals   []Value
}

type TemplateBatchMessage struct {
	TemplateID        uint64
	Count             uint64
	ChangedColumnMask []bool
	Columns           []Column
}

type ControlStreamMessage struct {
	Codec   ControlStreamCodec
	Payload []byte
}

type BaseSnapshotMessage struct {
	BaseID           uint64
	SchemaOrShapeRef uint64
	Payload          Message
}

type TemplateDescriptor struct {
	TemplateID     uint64
	FieldIDs       []uint64
	NullStrategies []NullStrategy
	Codecs         []VectorCodec
}

func (m Message) Clone() Message {
	switch m.Kind {
	case MessageKindScalar:
		v := m.Scalar.Clone()
		return Message{Kind: MessageKindScalar, Scalar: &v}
	case MessageKindArray:
		arr := make([]Value, len(m.Array))
		for i := range m.Array {
			arr[i] = m.Array[i].Clone()
		}
		return Message{Kind: MessageKindArray, Array: arr}
	case MessageKindMap:
		entries := make([]MessageMapEntry, len(m.Map))
		for i := range m.Map {
			entries[i] = MessageMapEntry{Key: m.Map[i].Key, Value: m.Map[i].Value.Clone()}
		}
		return Message{Kind: MessageKindMap, Map: entries}
	case MessageKindShapedObject:
		s := m.ShapedObject
		vals := make([]Value, len(s.Values))
		for i := range s.Values {
			vals[i] = s.Values[i].Clone()
		}
		var pres []bool
		if s.HasPresence {
			pres = append([]bool(nil), s.Presence...)
		}
		return Message{Kind: MessageKindShapedObject, ShapedObject: &ShapedObjectMessage{
			ShapeID: s.ShapeID, Presence: pres, HasPresence: s.HasPresence, Values: vals,
		}}
	case MessageKindSchemaObject:
		s := m.SchemaObject
		fields := make([]Value, len(s.Fields))
		for i := range s.Fields {
			fields[i] = s.Fields[i].Clone()
		}
		var pres []bool
		if s.HasPresence {
			pres = append([]bool(nil), s.Presence...)
		}
		var sid *uint64
		if s.SchemaID != nil {
			v := *s.SchemaID
			sid = &v
		}
		return Message{Kind: MessageKindSchemaObject, SchemaObject: &SchemaObjectMessage{
			SchemaID: sid, Presence: pres, HasPresence: s.HasPresence, Fields: fields,
		}}
	case MessageKindTypedVector:
		return Message{Kind: MessageKindTypedVector, TypedVector: cloneTypedVector(m.TypedVector)}
	case MessageKindRowBatch:
		rows := make([][]Value, len(m.RowBatch.Rows))
		for i := range m.RowBatch.Rows {
			rows[i] = make([]Value, len(m.RowBatch.Rows[i]))
			for j := range m.RowBatch.Rows[i] {
				rows[i][j] = m.RowBatch.Rows[i][j].Clone()
			}
		}
		return Message{Kind: MessageKindRowBatch, RowBatch: &RowBatchMessage{Rows: rows}}
	case MessageKindColumnBatch:
		cols := make([]Column, len(m.ColumnBatch.Columns))
		for i := range m.ColumnBatch.Columns {
			cols[i] = cloneColumn(m.ColumnBatch.Columns[i])
		}
		return Message{Kind: MessageKindColumnBatch, ColumnBatch: &ColumnBatchMessage{
			Count: m.ColumnBatch.Count, Columns: cols,
		}}
	case MessageKindSchemaBatch:
		cols := make([]Column, len(m.SchemaBatch.Columns))
		for i := range m.SchemaBatch.Columns {
			cols[i] = cloneColumn(m.SchemaBatch.Columns[i])
		}
		return Message{Kind: MessageKindSchemaBatch, SchemaBatch: &SchemaBatchMessage{
			SchemaID: m.SchemaBatch.SchemaID, Count: m.SchemaBatch.Count, Columns: cols,
		}}
	case MessageKindBoundStream:
		records := make([]BoundRecord, len(m.BoundStream.Records))
		for i := range m.BoundStream.Records {
			records[i] = cloneBoundRecord(m.BoundStream.Records[i])
		}
		return Message{Kind: MessageKindBoundStream, BoundStream: &BoundStreamMessage{
			SchemaID: m.BoundStream.SchemaID, PresenceStrategy: m.BoundStream.PresenceStrategy, Records: records,
		}}
	case MessageKindControl:
		return Message{Kind: MessageKindControl, Control: cloneControl(m.Control)}
	case MessageKindExt:
		return Message{Kind: MessageKindExt, Ext: &ExtMessage{
			ExtType: m.Ext.ExtType, Payload: append([]byte(nil), m.Ext.Payload...),
		}}
	case MessageKindStatePatch:
		sp := m.StatePatch
		ops := make([]PatchOperation, len(sp.Operations))
		for i := range sp.Operations {
			ops[i] = sp.Operations[i]
			if sp.Operations[i].Value != nil {
				v := sp.Operations[i].Value.Clone()
				ops[i].Value = &v
			}
		}
		lits := make([]Value, len(sp.Literals))
		for i := range sp.Literals {
			lits[i] = sp.Literals[i].Clone()
		}
		return Message{Kind: MessageKindStatePatch, StatePatch: &StatePatchMessage{
			BaseRef: sp.BaseRef, Operations: ops, Literals: lits,
		}}
	case MessageKindTemplateBatch:
		tb := m.TemplateBatch
		cols := make([]Column, len(tb.Columns))
		for i := range tb.Columns {
			cols[i] = cloneColumn(tb.Columns[i])
		}
		return Message{Kind: MessageKindTemplateBatch, TemplateBatch: &TemplateBatchMessage{
			TemplateID: tb.TemplateID, Count: tb.Count,
			ChangedColumnMask: append([]bool(nil), tb.ChangedColumnMask...),
			Columns:           cols,
		}}
	case MessageKindControlStream:
		return Message{Kind: MessageKindControlStream, ControlStream: &ControlStreamMessage{
			Codec: m.ControlStream.Codec, Payload: append([]byte(nil), m.ControlStream.Payload...),
		}}
	case MessageKindBaseSnapshot:
		return Message{Kind: MessageKindBaseSnapshot, BaseSnapshot: &BaseSnapshotMessage{
			BaseID: m.BaseSnapshot.BaseID, SchemaOrShapeRef: m.BaseSnapshot.SchemaOrShapeRef,
			Payload: m.BaseSnapshot.Payload.Clone(),
		}}
	default:
		return Message{}
	}
}

func cloneBoundRecord(r BoundRecord) BoundRecord {
	out := BoundRecord{HasPresence: r.HasPresence}
	if r.HasPresence {
		out.Presence = append([]bool(nil), r.Presence...)
	}
	out.Fields = make([]Value, len(r.Fields))
	for i := range r.Fields {
		out.Fields[i] = r.Fields[i].Clone()
	}
	return out
}

func cloneTypedVector(tv *TypedVector) *TypedVector {
	if tv == nil {
		return nil
	}
	out := *tv
	switch tv.ElementType {
	case ElementTypeBool:
		out.Data.Bools = append([]bool(nil), tv.Data.Bools...)
	case ElementTypeI64:
		out.Data.I64s = append([]int64(nil), tv.Data.I64s...)
	case ElementTypeU64:
		out.Data.U64s = append([]uint64(nil), tv.Data.U64s...)
	case ElementTypeF64:
		out.Data.F64s = append([]float64(nil), tv.Data.F64s...)
	case ElementTypeString:
		out.Data.Strings = append([]string(nil), tv.Data.Strings...)
	case ElementTypeBinary:
		out.Data.Binary = make([][]byte, len(tv.Data.Binary))
		for i := range tv.Data.Binary {
			out.Data.Binary[i] = append([]byte(nil), tv.Data.Binary[i]...)
		}
	case ElementTypeValue:
		out.Data.Values = make([]Value, len(tv.Data.Values))
		for i := range tv.Data.Values {
			out.Data.Values[i] = tv.Data.Values[i].Clone()
		}
	}
	out.Data.Kind = tv.ElementType
	return &out
}

func cloneColumn(c Column) Column {
	out := c
	if c.HasPresence {
		out.Presence = append([]bool(nil), c.Presence...)
	}
	if c.DictionaryID != nil {
		v := *c.DictionaryID
		out.DictionaryID = &v
	}
	out.Values = cloneTypedVectorData(c.Values)
	return out
}

func cloneTypedVectorData(d TypedVectorData) TypedVectorData {
	out := d
	out.Bools = append([]bool(nil), d.Bools...)
	out.I64s = append([]int64(nil), d.I64s...)
	out.U64s = append([]uint64(nil), d.U64s...)
	out.F64s = append([]float64(nil), d.F64s...)
	out.Strings = append([]string(nil), d.Strings...)
	out.Binary = make([][]byte, len(d.Binary))
	for i := range d.Binary {
		out.Binary[i] = append([]byte(nil), d.Binary[i]...)
	}
	out.Values = make([]Value, len(d.Values))
	for i := range d.Values {
		out.Values[i] = d.Values[i].Clone()
	}
	return out
}

func cloneControl(c *ControlMessage) *ControlMessage {
	if c == nil {
		return nil
	}
	out := *c
	out.RegisterKeys = append([]string(nil), c.RegisterKeys...)
	out.RegisterStrings = append([]string(nil), c.RegisterStrings...)
	if c.RegisterShape != nil {
		rs := *c.RegisterShape
		rs.Keys = append([]KeyRef(nil), c.RegisterShape.Keys...)
		out.RegisterShape = &rs
	}
	if c.PromoteStringFieldToEnum != nil {
		p := *c.PromoteStringFieldToEnum
		p.Values = append([]string(nil), c.PromoteStringFieldToEnum.Values...)
		out.PromoteStringFieldToEnum = &p
	}
	return &out
}
