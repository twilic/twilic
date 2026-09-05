package core

import (
	"hash/fnv"
	"math"
	"math/bits"
	"sort"
	"strings"
)

const (
	tagNull      byte = 0
	tagBoolFalse byte = 1
	tagBoolTrue  byte = 2
	tagI64       byte = 3
	tagU64       byte = 4
	tagF64       byte = 5
	tagString    byte = 6
	tagBinary    byte = 7
	tagArray     byte = 8
	tagMap       byte = 9
)

type TwilicCodec struct {
	State *SessionState
}

func NewTwilicCodec() *TwilicCodec {
	return &TwilicCodec{State: newSessionState()}
}

func TwilicCodecWithOptions(options SessionOptions) *TwilicCodec {
	return &TwilicCodec{State: newSessionStateWithOptions(options)}
}

func (c *TwilicCodec) EncodeMessage(message *Message) ([]byte, error) {
	out := make([]byte, 0, 256)
	if err := c.writeMessage(message, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (c *TwilicCodec) DecodeMessage(bytes []byte) (Message, error) {
	reader := newReader(bytes)
	msg, err := c.readMessage(reader)
	if err != nil {
		return Message{}, err
	}
	if !reader.isEOF() {
		return Message{}, invalidData("trailing bytes in message")
	}
	switch msg.Kind {
	case MessageKindControl:
		// control does not update previous message body
	case MessageKindStatePatch:
		reconstructed, err := c.applyStatePatch(msg.StatePatch.BaseRef, msg.StatePatch.Operations, msg.StatePatch.Literals)
		if err != nil {
			if isUnknownReference(err) || isStatelessRetry(err) {
				return Message{}, err
			}
		} else {
			size := len(bytes)
			c.State.PreviousMessage = &reconstructed
			c.State.PreviousMessageSize = &size
		}
	case MessageKindTemplateBatch:
		if c.State.PreviousMessage == nil {
			cl := msg.Clone()
			size := len(bytes)
			c.State.PreviousMessage = &cl
			c.State.PreviousMessageSize = &size
		}
	default:
		cl := msg.Clone()
		size := len(bytes)
		c.State.PreviousMessage = &cl
		c.State.PreviousMessageSize = &size
	}
	return msg, nil
}

func (c *TwilicCodec) EncodeValue(value *Value) ([]byte, error) {
	msg := c.messageForValue(value)
	out, err := c.EncodeMessage(&msg)
	if err != nil {
		return nil, err
	}
	cl := msg.Clone()
	size := len(out)
	c.State.PreviousMessage = &cl
	c.State.PreviousMessageSize = &size
	return out, nil
}

func (c *TwilicCodec) DecodeValue(bytes []byte) (Value, error) {
	msg, err := c.DecodeMessage(bytes)
	if err != nil {
		return Value{}, err
	}
	cl := msg.Clone()
	c.State.PreviousMessage = &cl
	switch msg.Kind {
	case MessageKindScalar:
		return msg.Scalar.Clone(), nil
	case MessageKindArray:
		return NewArray(msg.Array), nil
	case MessageKindMap:
		entries, err := entriesToMap(msg.Map, c.State)
		if err != nil {
			return Value{}, err
		}
		return NewMap(entries...), nil
	case MessageKindShapedObject:
		keys, ok := c.State.ShapeTable.GetKeys(msg.ShapedObject.ShapeID)
		if !ok {
			return Value{}, c.referenceError("shape_id", msg.ShapedObject.ShapeID)
		}
		return NewMap(shapeValuesToMap(keys, msg.ShapedObject.Presence, msg.ShapedObject.HasPresence, msg.ShapedObject.Values)...), nil
	case MessageKindTypedVector:
		return typedVectorToValue(*msg.TypedVector), nil
	default:
		return Value{}, invalidData("decode_value expects scalar/array/map/vector message")
	}
}

func (c *TwilicCodec) referenceError(kind string, id uint64) error {
	if c.State.Options.UnknownReferencePolicy == UnknownReferencePolicyStatelessRetry {
		return statelessRetryRequired(kind, id)
	}
	return unknownReference(kind, id)
}

func (c *TwilicCodec) messageForValue(value *Value) Message {
	switch value.Kind {
	case ValueArray:
		if vec, ok := c.tryMakeTypedVector(value.Arr); ok {
			return Message{Kind: MessageKindTypedVector, TypedVector: &vec}
		}
		arr := make([]Value, len(value.Arr))
		for i := range value.Arr {
			arr[i] = value.Arr[i].Clone()
		}
		return Message{Kind: MessageKindArray, Array: arr}
	case ValueMap:
		keys := make([]string, len(value.Map))
		for i := range value.Map {
			keys[i] = value.Map[i].Key
		}
		_, hadObservation := c.State.EncodeShapeObservations[shapeKey(keys)]
		obs := c.observeEncodeShapeCandidate(keys)
		if shapeID, ok := c.State.ShapeTable.GetID(keys); ok && (!hadObservation || obs >= 2) {
			return c.shapedMessage(shapeID, value.Map)
		}
		return c.mapMessage(value.Map)
	default:
		sc := value.Clone()
		return Message{Kind: MessageKindScalar, Scalar: &sc}
	}
}

func (c *TwilicCodec) mapMessage(entries []MapEntry) Message {
	out := make([]MessageMapEntry, len(entries))
	for i := range entries {
		key := entries[i].Key
		var keyRef KeyRef
		if id, ok := c.State.KeyTable.GetID(key); ok {
			keyRef = KeyRefID(id)
		} else {
			c.State.KeyTable.Register(key)
			keyRef = KeyRefLiteral(key)
		}
		out[i] = MessageMapEntry{Key: keyRef, Value: entries[i].Value.Clone()}
	}
	return Message{Kind: MessageKindMap, Map: out}
}

func (c *TwilicCodec) shapedMessage(shapeID uint64, entries []MapEntry) Message {
	keys, _ := c.State.ShapeTable.GetKeys(shapeID)
	index := make(map[string]Value, len(entries))
	for i := range entries {
		index[entries[i].Key] = entries[i].Value
	}
	values := make([]Value, 0, len(keys))
	presence := make([]bool, len(keys))
	all := true
	for i, key := range keys {
		v, ok := index[key]
		if ok {
			presence[i] = true
			values = append(values, v.Clone())
		} else {
			presence[i] = false
			all = false
		}
	}
	msg := &ShapedObjectMessage{ShapeID: shapeID, Values: values}
	if !all {
		msg.HasPresence = true
		msg.Presence = presence
	}
	return Message{Kind: MessageKindShapedObject, ShapedObject: msg}
}

func (c *TwilicCodec) tryMakeTypedVector(values []Value) (TypedVector, bool) {
	if len(values) < 4 {
		return TypedVector{}, false
	}
	allBool := true
	allI64 := true
	allU64 := true
	allF64 := true
	allStr := true
	for i := range values {
		switch values[i].Kind {
		case ValueBool:
			allI64, allU64, allF64, allStr = false, false, false, false
		case ValueI64:
			allBool, allU64, allF64, allStr = false, false, false, false
		case ValueU64:
			allBool, allI64, allF64, allStr = false, false, false, false
		case ValueF64:
			allBool, allI64, allU64, allStr = false, false, false, false
		case ValueString:
			allBool, allI64, allU64, allF64 = false, false, false, false
		default:
			return TypedVector{}, false
		}
	}
	if allBool {
		bools := make([]bool, len(values))
		for i := range values {
			bools[i] = values[i].Bool
		}
		return TypedVector{
			ElementType: ElementTypeBool,
			Codec:       VectorCodecDirectBitpack,
			Data:        TypedVectorData{Kind: ElementTypeBool, Bools: bools},
		}, true
	}
	if allI64 {
		vals := make([]int64, len(values))
		for i := range values {
			vals[i] = values[i].I64
		}
		return TypedVector{
			ElementType: ElementTypeI64,
			Codec:       selectIntegerCodec(vals),
			Data:        TypedVectorData{Kind: ElementTypeI64, I64s: vals},
		}, true
	}
	if allU64 {
		vals := make([]uint64, len(values))
		for i := range values {
			vals[i] = values[i].U64
		}
		return TypedVector{
			ElementType: ElementTypeU64,
			Codec:       selectU64Codec(vals),
			Data:        TypedVectorData{Kind: ElementTypeU64, U64s: vals},
		}, true
	}
	if allF64 {
		vals := make([]float64, len(values))
		for i := range values {
			vals[i] = values[i].F64
		}
		return TypedVector{
			ElementType: ElementTypeF64,
			Codec:       selectFloatCodec(vals),
			Data:        TypedVectorData{Kind: ElementTypeF64, F64s: vals},
		}, true
	}
	if allStr {
		vals := make([]string, len(values))
		for i := range values {
			vals[i] = values[i].Str
		}
		return TypedVector{
			ElementType: ElementTypeString,
			Codec:       selectStringCodec(vals),
			Data:        TypedVectorData{Kind: ElementTypeString, Strings: vals},
		}, true
	}
	return TypedVector{}, false
}

func (c *TwilicCodec) writeMessage(message *Message, out *[]byte) error {
	switch message.Kind {
	case MessageKindScalar:
		*out = append(*out, byte(MessageKindScalar))
		c.writeValue(message.Scalar, out)
	case MessageKindArray:
		*out = append(*out, byte(MessageKindArray))
		encodeVaruint(uint64(len(message.Array)), out)
		for i := range message.Array {
			c.writeValue(&message.Array[i], out)
		}
	case MessageKindMap:
		*out = append(*out, byte(MessageKindMap))
		encodeVaruint(uint64(len(message.Map)), out)
		for i := range message.Map {
			c.writeKeyRef(message.Map[i].Key, out)
			fieldID := keyRefFieldIdentity(&message.Map[i].Key, c.State)
			c.writeValueWithField(&message.Map[i].Value, fieldID, out)
		}
	case MessageKindShapedObject:
		*out = append(*out, byte(MessageKindShapedObject))
		encodeVaruint(message.ShapedObject.ShapeID, out)
		c.writePresence(message.ShapedObject.Presence, message.ShapedObject.HasPresence, out)
		encodeVaruint(uint64(len(message.ShapedObject.Values)), out)
		keys, ok := c.State.ShapeTable.GetKeys(message.ShapedObject.ShapeID)
		if ok {
			pres := message.ShapedObject.Presence
			if !message.ShapedObject.HasPresence {
				pres = make([]bool, len(keys))
				for i := range pres {
					pres[i] = true
				}
			}
			vIdx := 0
			for i := range keys {
				if i < len(pres) && !pres[i] {
					continue
				}
				if vIdx >= len(message.ShapedObject.Values) {
					break
				}
				key := keys[i]
				c.writeValueWithField(&message.ShapedObject.Values[vIdx], &key, out)
				vIdx++
			}
			for vIdx < len(message.ShapedObject.Values) {
				c.writeValue(&message.ShapedObject.Values[vIdx], out)
				vIdx++
			}
		} else {
			for i := range message.ShapedObject.Values {
				c.writeValue(&message.ShapedObject.Values[i], out)
			}
		}
	case MessageKindSchemaObject:
		*out = append(*out, byte(MessageKindSchemaObject))
		var schemaID *uint64
		if message.SchemaObject.SchemaID != nil {
			*out = append(*out, 1)
			encodeVaruint(*message.SchemaObject.SchemaID, out)
			schemaID = message.SchemaObject.SchemaID
		} else {
			*out = append(*out, 0)
		}
		c.writePresence(message.SchemaObject.Presence, message.SchemaObject.HasPresence, out)
		encodeVaruint(uint64(len(message.SchemaObject.Fields)), out)
		var schema *Schema
		if schemaID != nil {
			if sch, ok := c.State.Schemas[*schemaID]; ok {
				schema = &sch
			}
		} else if c.State.LastSchemaID != nil {
			if sch, ok := c.State.Schemas[*c.State.LastSchemaID]; ok {
				schema = &sch
			}
		}
		if schema != nil {
			*out = append(*out, 1)
			if err := c.writeSchemaFields(schema, message.SchemaObject.Presence, message.SchemaObject.HasPresence, message.SchemaObject.Fields, out); err != nil {
				return err
			}
			if schemaID != nil {
				id := *schemaID
				c.State.LastSchemaID = &id
			}
		} else {
			*out = append(*out, 0)
			for i := range message.SchemaObject.Fields {
				c.writeValue(&message.SchemaObject.Fields[i], out)
			}
		}
	case MessageKindTypedVector:
		*out = append(*out, byte(MessageKindTypedVector))
		if err := c.writeTypedVector(message.TypedVector, out); err != nil {
			return err
		}
	case MessageKindRowBatch:
		*out = append(*out, byte(MessageKindRowBatch))
		encodeVaruint(uint64(len(message.RowBatch.Rows)), out)
		for i := range message.RowBatch.Rows {
			encodeVaruint(uint64(len(message.RowBatch.Rows[i])), out)
			for j := range message.RowBatch.Rows[i] {
				c.writeValue(&message.RowBatch.Rows[i][j], out)
			}
		}
	case MessageKindColumnBatch:
		*out = append(*out, byte(MessageKindColumnBatch))
		encodeVaruint(message.ColumnBatch.Count, out)
		encodeVaruint(uint64(len(message.ColumnBatch.Columns)), out)
		for i := range message.ColumnBatch.Columns {
			if err := c.writeColumn(&message.ColumnBatch.Columns[i], out); err != nil {
				return err
			}
		}
	case MessageKindSchemaBatch:
		*out = append(*out, byte(MessageKindSchemaBatch))
		encodeVaruint(message.SchemaBatch.SchemaID, out)
		encodeVaruint(message.SchemaBatch.Count, out)
		encodeVaruint(uint64(len(message.SchemaBatch.Columns)), out)
		for i := range message.SchemaBatch.Columns {
			if err := c.writeSchemaBatchColumn(&message.SchemaBatch.Columns[i], message.SchemaBatch.Count, out); err != nil {
				return err
			}
		}
	case MessageKindBoundStream:
		*out = append(*out, byte(MessageKindBoundStream))
		encodeVaruint(message.BoundStream.SchemaID, out)
		encodeVaruint(uint64(len(message.BoundStream.Records)), out)
		*out = append(*out, byte(message.BoundStream.PresenceStrategy))
		schema, ok := c.State.Schemas[message.BoundStream.SchemaID]
		if !ok {
			return c.referenceError("schema_id", message.BoundStream.SchemaID)
		}
		for i := range message.BoundStream.Records {
			if err := c.writeBoundRecordBody(&schema, message.BoundStream.PresenceStrategy, &message.BoundStream.Records[i], out); err != nil {
				return err
			}
		}
	case MessageKindControl:
		*out = append(*out, byte(MessageKindControl))
		return c.writeControl(message.Control, out)
	case MessageKindExt:
		*out = append(*out, byte(MessageKindExt))
		encodeVaruint(message.Ext.ExtType, out)
		encodeBytes(message.Ext.Payload, out)
	case MessageKindStatePatch:
		*out = append(*out, byte(MessageKindStatePatch))
		c.writeBaseRef(message.StatePatch.BaseRef, out)
		encodeVaruint(uint64(len(message.StatePatch.Operations)), out)
		for i := range message.StatePatch.Operations {
			op := message.StatePatch.Operations[i]
			encodeVaruint(op.FieldID, out)
			*out = append(*out, byte(op.Opcode))
			if op.Value != nil {
				*out = append(*out, 1)
				c.writeValue(op.Value, out)
			} else {
				*out = append(*out, 0)
			}
		}
		encodeVaruint(uint64(len(message.StatePatch.Literals)), out)
		for i := range message.StatePatch.Literals {
			c.writeValue(&message.StatePatch.Literals[i], out)
		}
	case MessageKindTemplateBatch:
		*out = append(*out, byte(MessageKindTemplateBatch))
		encodeVaruint(message.TemplateBatch.TemplateID, out)
		encodeVaruint(message.TemplateBatch.Count, out)
		encodeBitmap(message.TemplateBatch.ChangedColumnMask, out)
		encodeVaruint(uint64(len(message.TemplateBatch.Columns)), out)
		for i := range message.TemplateBatch.Columns {
			if err := c.writeColumn(&message.TemplateBatch.Columns[i], out); err != nil {
				return err
			}
		}
	case MessageKindControlStream:
		*out = append(*out, byte(MessageKindControlStream))
		*out = append(*out, byte(message.ControlStream.Codec))
		c.writeControlStreamPayload(message.ControlStream.Codec, message.ControlStream.Payload, out)
	case MessageKindBaseSnapshot:
		*out = append(*out, byte(MessageKindBaseSnapshot))
		encodeVaruint(message.BaseSnapshot.BaseID, out)
		encodeVaruint(message.BaseSnapshot.SchemaOrShapeRef, out)
		if err := c.writeMessage(&message.BaseSnapshot.Payload, out); err != nil {
			return err
		}
		c.State.RegisterBaseSnapshot(message.BaseSnapshot.BaseID, message.BaseSnapshot.Payload)
	default:
		return invalidData("unsupported message kind")
	}
	return nil
}

func (c *TwilicCodec) readMessage(reader *Reader) (Message, error) {
	if err := reader.enterDepth(); err != nil {
		return Message{}, err
	}
	defer reader.leaveDepth()
	kindByte, err := reader.readU8()
	if err != nil {
		return Message{}, err
	}
	kind, ok := messageKindFromByte(kindByte)
	if !ok {
		return Message{}, invalidKind(kindByte)
	}
	switch kind {
	case MessageKindScalar:
		v, err := c.readValue(reader)
		if err != nil {
			return Message{}, err
		}
		return Message{Kind: MessageKindScalar, Scalar: &v}, nil
	case MessageKindArray:
		n, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		values := make([]Value, int(n))
		for i := 0; i < int(n); i++ {
			values[i], err = c.readValue(reader)
			if err != nil {
				return Message{}, err
			}
		}
		return Message{Kind: MessageKindArray, Array: values}, nil
	case MessageKindMap:
		n, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		entries := make([]MessageMapEntry, int(n))
		for i := 0; i < int(n); i++ {
			keyRef, err := c.readKeyRef(reader)
			if err != nil {
				return Message{}, err
			}
			fieldIdentity := keyRefFieldIdentity(&keyRef, c.State)
			v, err := c.readValueWithField(reader, fieldIdentity)
			if err != nil {
				return Message{}, err
			}
			entries[i] = MessageMapEntry{Key: keyRef, Value: v}
		}
		keys := make([]string, len(entries))
		for i := range entries {
			keys[i] = keyRefString(&entries[i].Key, c.State)
		}
		c.observeDecodeShapeCandidate(keys)
		return Message{Kind: MessageKindMap, Map: entries}, nil
	case MessageKindShapedObject:
		shapeID, err := reader.readCount(65535)
		if err != nil {
			return Message{}, err
		}
		presence, hasPresence, err := c.readPresence(reader)
		if err != nil {
			return Message{}, err
		}
		n, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		values := make([]Value, 0, int(n))
		if keys, ok := c.State.ShapeTable.GetKeys(shapeID); ok {
			pres := presence
			if !hasPresence {
				pres = make([]bool, len(keys))
				for i := range pres {
					pres[i] = true
				}
			}
			readCount := 0
			for i := range keys {
				if i < len(pres) && !pres[i] {
					continue
				}
				if readCount >= int(n) {
					break
				}
				key := keys[i]
				v, err := c.readValueWithField(reader, &key)
				if err != nil {
					return Message{}, err
				}
				values = append(values, v)
				readCount++
			}
			for readCount < int(n) {
				v, err := c.readValue(reader)
				if err != nil {
					return Message{}, err
				}
				values = append(values, v)
				readCount++
			}
		} else {
			for i := 0; i < int(n); i++ {
				v, err := c.readValue(reader)
				if err != nil {
					return Message{}, err
				}
				values = append(values, v)
			}
		}
		return Message{Kind: MessageKindShapedObject, ShapedObject: &ShapedObjectMessage{
			ShapeID: shapeID, Presence: presence, HasPresence: hasPresence, Values: values,
		}}, nil
	case MessageKindSchemaObject:
		hasSchema, err := reader.readU8()
		if err != nil {
			return Message{}, err
		}
		var schemaID *uint64
		if hasSchema == 1 {
			id, err := reader.readVaruint()
			if err != nil {
				return Message{}, err
			}
			schemaID = &id
		}
		presence, hasPresence, err := c.readPresence(reader)
		if err != nil {
			return Message{}, err
		}
		n, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		mode, err := reader.readU8()
		if err != nil {
			return Message{}, err
		}
		fields := make([]Value, 0, int(n))
		if mode == 1 {
			var effectiveID uint64
			if schemaID != nil {
				effectiveID = *schemaID
			} else if c.State.LastSchemaID != nil {
				effectiveID = *c.State.LastSchemaID
			} else {
				return Message{}, invalidData("schema object requires schema id in context")
			}
			sch, ok := c.State.Schemas[effectiveID]
			if !ok {
				return Message{}, c.referenceError("schema_id", effectiveID)
			}
			fields, err = c.readSchemaFields(&sch, presence, hasPresence, int(n), reader)
			if err != nil {
				return Message{}, err
			}
			c.State.LastSchemaID = &effectiveID
		} else {
			for i := 0; i < int(n); i++ {
				v, err := c.readValue(reader)
				if err != nil {
					return Message{}, err
				}
				fields = append(fields, v)
			}
			if schemaID != nil {
				id := *schemaID
				c.State.LastSchemaID = &id
			}
		}
		return Message{Kind: MessageKindSchemaObject, SchemaObject: &SchemaObjectMessage{
			SchemaID: schemaID, Presence: presence, HasPresence: hasPresence, Fields: fields,
		}}, nil
	case MessageKindTypedVector:
		tv, err := c.readTypedVector(reader, nil, nil)
		if err != nil {
			return Message{}, err
		}
		return Message{Kind: MessageKindTypedVector, TypedVector: &tv}, nil
	case MessageKindRowBatch:
		rowCount, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		rows := make([][]Value, int(rowCount))
		for i := 0; i < int(rowCount); i++ {
			fieldCount, err := reader.readCount()
			if err != nil {
				return Message{}, err
			}
			row := make([]Value, int(fieldCount))
			for j := 0; j < int(fieldCount); j++ {
				row[j], err = c.readValue(reader)
				if err != nil {
					return Message{}, err
				}
			}
			rows[i] = row
		}
		return Message{Kind: MessageKindRowBatch, RowBatch: &RowBatchMessage{Rows: rows}}, nil
	case MessageKindColumnBatch:
		count, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		colCount, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		cols := make([]Column, int(colCount))
		for i := 0; i < int(colCount); i++ {
			cols[i], err = c.readColumn(reader)
			if err != nil {
				return Message{}, err
			}
		}
		return Message{Kind: MessageKindColumnBatch, ColumnBatch: &ColumnBatchMessage{
			Count: count, Columns: cols,
		}}, nil
	case MessageKindSchemaBatch:
		schemaID, err := reader.readVaruint()
		if err != nil {
			return Message{}, err
		}
		count, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		colCount, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		cols := make([]Column, int(colCount))
		schema, hasSchema := c.State.Schemas[schemaID]
		for i := 0; i < int(colCount); i++ {
			fieldID := uint64(i)
			if hasSchema && i < len(schema.Fields) {
				fieldID = schema.Fields[i].Number
			}
			cols[i], err = c.readSchemaBatchColumn(fieldID, count, reader)
			if err != nil {
				return Message{}, err
			}
		}
		return Message{Kind: MessageKindSchemaBatch, SchemaBatch: &SchemaBatchMessage{
			SchemaID: schemaID, Count: count, Columns: cols,
		}}, nil
	case MessageKindBoundStream:
		schemaID, err := reader.readVaruint()
		if err != nil {
			return Message{}, err
		}
		count, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		strategyByte, err := reader.readU8()
		if err != nil {
			return Message{}, err
		}
		strategy, ok := presenceStrategyFromByte(strategyByte)
		if !ok {
			return Message{}, invalidData("presence strategy")
		}
		schema, ok := c.State.Schemas[schemaID]
		if !ok {
			return Message{}, c.referenceError("schema_id", schemaID)
		}
		records := make([]BoundRecord, int(count))
		for i := 0; i < int(count); i++ {
			records[i], err = c.readBoundRecordBody(&schema, strategy, reader)
			if err != nil {
				return Message{}, err
			}
		}
		return Message{Kind: MessageKindBoundStream, BoundStream: &BoundStreamMessage{
			SchemaID: schemaID, PresenceStrategy: strategy, Records: records,
		}}, nil
	case MessageKindControl:
		ctrl, err := c.readControl(reader)
		if err != nil {
			return Message{}, err
		}
		return Message{Kind: MessageKindControl, Control: &ctrl}, nil
	case MessageKindExt:
		extType, err := reader.readVaruint()
		if err != nil {
			return Message{}, err
		}
		payload, err := reader.readBytes()
		if err != nil {
			return Message{}, err
		}
		return Message{Kind: MessageKindExt, Ext: &ExtMessage{ExtType: extType, Payload: payload}}, nil
	case MessageKindStatePatch:
		baseRef, err := c.readBaseRef(reader)
		if err != nil {
			return Message{}, err
		}
		n, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		ops := make([]PatchOperation, int(n))
		for i := 0; i < int(n); i++ {
			fieldID, err := reader.readVaruint()
			if err != nil {
				return Message{}, err
			}
			opByte, err := reader.readU8()
			if err != nil {
				return Message{}, err
			}
			opcode, ok := patchOpcodeFromByte(opByte)
			if !ok {
				return Message{}, invalidData("patch opcode")
			}
			hasValue, err := reader.readU8()
			if err != nil {
				return Message{}, err
			}
			var value *Value
			if hasValue == 1 {
				v, err := c.readValue(reader)
				if err != nil {
					return Message{}, err
				}
				value = &v
			}
			ops[i] = PatchOperation{FieldID: fieldID, Opcode: opcode, Value: value}
		}
		litN, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		lits := make([]Value, int(litN))
		for i := 0; i < int(litN); i++ {
			lits[i], err = c.readValue(reader)
			if err != nil {
				return Message{}, err
			}
		}
		return Message{Kind: MessageKindStatePatch, StatePatch: &StatePatchMessage{
			BaseRef: baseRef, Operations: ops, Literals: lits,
		}}, nil
	case MessageKindTemplateBatch:
		templateID, err := reader.readVaruint()
		if err != nil {
			return Message{}, err
		}
		count, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		mask, err := reader.readBitmap()
		if err != nil {
			return Message{}, err
		}
		colN, err := reader.readCount()
		if err != nil {
			return Message{}, err
		}
		changedCols := make([]Column, int(colN))
		for i := 0; i < int(colN); i++ {
			changedCols[i], err = c.readColumn(reader)
			if err != nil {
				return Message{}, err
			}
		}
		fullCols := changedCols
		if prev, ok := c.State.TemplateColumns[templateID]; ok {
			merged, err := mergeTemplateColumns(prev, mask, changedCols)
			if err != nil {
				return Message{}, err
			}
			fullCols = merged
		} else {
			for i := range mask {
				if !mask[i] {
					return Message{}, c.referenceError("template_id", templateID)
				}
			}
		}
		c.State.TemplateColumns[templateID] = fullCols
		c.State.Templates[templateID] = templateDescriptorFromColumns(templateID, fullCols)
		if count >= 16 {
			msg := Message{Kind: MessageKindColumnBatch, ColumnBatch: &ColumnBatchMessage{Count: count, Columns: fullCols}}
			c.State.PreviousMessage = &msg
		}
		return Message{Kind: MessageKindTemplateBatch, TemplateBatch: &TemplateBatchMessage{
			TemplateID: templateID, Count: count, ChangedColumnMask: mask, Columns: changedCols,
		}}, nil
	case MessageKindControlStream:
		codecByte, err := reader.readU8()
		if err != nil {
			return Message{}, err
		}
		codec, ok := controlStreamCodecFromByte(codecByte)
		if !ok {
			return Message{}, invalidData("control stream codec")
		}
		payload, err := c.readControlStreamPayload(codec, reader)
		if err != nil {
			return Message{}, err
		}
		return Message{Kind: MessageKindControlStream, ControlStream: &ControlStreamMessage{Codec: codec, Payload: payload}}, nil
	case MessageKindBaseSnapshot:
		baseID, err := reader.readVaruint()
		if err != nil {
			return Message{}, err
		}
		ref, err := reader.readVaruint()
		if err != nil {
			return Message{}, err
		}
		payload, err := c.readMessage(reader)
		if err != nil {
			return Message{}, err
		}
		c.State.RegisterBaseSnapshot(baseID, payload)
		return Message{Kind: MessageKindBaseSnapshot, BaseSnapshot: &BaseSnapshotMessage{
			BaseID: baseID, SchemaOrShapeRef: ref, Payload: payload,
		}}, nil
	}
	return Message{}, invalidData("unsupported message kind")
}

func (c *TwilicCodec) writeValue(value *Value, out *[]byte) {
	c.writeValueWithField(value, nil, out)
}

func (c *TwilicCodec) writeValueWithField(value *Value, fieldIdentity *string, out *[]byte) {
	switch value.Kind {
	case ValueNull:
		*out = append(*out, tagNull)
	case ValueBool:
		if value.Bool {
			*out = append(*out, tagBoolTrue)
		} else {
			*out = append(*out, tagBoolFalse)
		}
	case ValueI64:
		*out = append(*out, tagI64)
		writeSmallestU64(encodeZigzag(value.I64), out)
	case ValueU64:
		*out = append(*out, tagU64)
		writeSmallestU64(value.U64, out)
	case ValueF64:
		*out = append(*out, tagF64)
		appendF64LE(out, value.F64)
	case ValueString:
		*out = append(*out, tagString)
		if fieldIdentity != nil {
			if enumVals, ok := c.State.FieldEnums[*fieldIdentity]; ok {
				for i := range enumVals {
					if enumVals[i] == value.Str {
						*out = append(*out, byte(StringModeInlineEnum))
						encodeVaruint(uint64(i), out)
						return
					}
				}
			}
		}
		if value.Str == "" {
			*out = append(*out, byte(StringModeEmpty))
			return
		}
		if id, ok := c.State.StringTable.GetID(value.Str); ok {
			*out = append(*out, byte(StringModeRef))
			encodeVaruint(id, out)
			return
		}
		if baseID, prefixLen, ok := c.bestPrefixBase(value.Str); ok && prefixLen >= 4 && prefixLen < len(value.Str) {
			*out = append(*out, byte(StringModePrefixDelta))
			encodeVaruint(baseID, out)
			encodeVaruint(uint64(prefixLen), out)
			encodeString(value.Str[prefixLen:], out)
			c.State.StringTable.Register(value.Str)
			return
		}
		*out = append(*out, byte(StringModeLiteral))
		encodeString(value.Str, out)
		c.State.StringTable.Register(value.Str)
	case ValueBinary:
		*out = append(*out, tagBinary)
		encodeBytes(value.Bin, out)
	case ValueArray:
		*out = append(*out, tagArray)
		encodeVaruint(uint64(len(value.Arr)), out)
		for i := range value.Arr {
			c.writeValue(&value.Arr[i], out)
		}
	case ValueMap:
		*out = append(*out, tagMap)
		encodeVaruint(uint64(len(value.Map)), out)
		for i := range value.Map {
			c.writeKeyRef(KeyRefLiteral(value.Map[i].Key), out)
			key := value.Map[i].Key
			c.writeValueWithField(&value.Map[i].Value, &key, out)
		}
	}
}

func (c *TwilicCodec) readValue(reader *Reader) (Value, error) {
	return c.readValueWithField(reader, nil)
}

func (c *TwilicCodec) readValueWithField(reader *Reader, fieldIdentity *string) (Value, error) {
	if err := reader.enterDepth(); err != nil {
		return Value{}, err
	}
	defer reader.leaveDepth()
	tag, err := reader.readU8()
	if err != nil {
		return Value{}, err
	}
	switch tag {
	case tagNull:
		return NewNull(), nil
	case tagBoolFalse:
		return NewBool(false), nil
	case tagBoolTrue:
		return NewBool(true), nil
	case tagI64:
		v, err := readSmallestU64(reader)
		if err != nil {
			return Value{}, err
		}
		return NewI64(decodeZigzag(v)), nil
	case tagU64:
		v, err := readSmallestU64(reader)
		if err != nil {
			return Value{}, err
		}
		return NewU64(v), nil
	case tagF64:
		f, err := readF64LE(reader)
		if err != nil {
			return Value{}, err
		}
		return NewF64(f), nil
	case tagString:
		modeByte, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		mode, ok := stringModeFromByte(modeByte)
		if !ok {
			return Value{}, invalidData("string mode")
		}
		switch mode {
		case StringModeEmpty:
			return NewString(""), nil
		case StringModeLiteral:
			s, err := reader.readString()
			if err != nil {
				return Value{}, err
			}
			c.State.StringTable.Register(s)
			return NewString(s), nil
		case StringModeRef:
			id, err := reader.readVaruint()
			if err != nil {
				return Value{}, err
			}
			s, ok := c.State.StringTable.GetValue(id)
			if !ok {
				return Value{}, c.referenceError("string_id", id)
			}
			return NewString(s), nil
		case StringModePrefixDelta:
			baseID, err := reader.readVaruint()
			if err != nil {
				return Value{}, err
			}
			prefixLen, err := reader.readCount()
			if err != nil {
				return Value{}, err
			}
			suffix, err := reader.readString()
			if err != nil {
				return Value{}, err
			}
			base, ok := c.State.StringTable.GetValue(baseID)
			if !ok {
				return Value{}, c.referenceError("string_id", baseID)
			}
			if int(prefixLen) > len(base) {
				return Value{}, invalidData("prefix delta length")
			}
			s := base[:prefixLen] + suffix
			c.State.StringTable.Register(s)
			return NewString(s), nil
		case StringModeInlineEnum:
			if fieldIdentity == nil {
				return Value{}, invalidData("inline enum missing field identity")
			}
			enumVals, ok := c.State.FieldEnums[*fieldIdentity]
			if !ok {
				return Value{}, invalidData("inline enum unknown field")
			}
			code, err := reader.readVaruint()
			if err != nil {
				return Value{}, err
			}
			if int(code) >= len(enumVals) {
				return Value{}, invalidData("inline enum code")
			}
			return NewString(enumVals[code]), nil
		}
	case tagBinary:
		b, err := reader.readBytes()
		if err != nil {
			return Value{}, err
		}
		return NewBinary(b), nil
	case tagArray:
		n, err := reader.readCount()
		if err != nil {
			return Value{}, err
		}
		out := make([]Value, int(n))
		for i := 0; i < int(n); i++ {
			out[i], err = c.readValue(reader)
			if err != nil {
				return Value{}, err
			}
		}
		return NewArray(out), nil
	case tagMap:
		n, err := reader.readCount()
		if err != nil {
			return Value{}, err
		}
		out := make([]MapEntry, int(n))
		for i := 0; i < int(n); i++ {
			keyRef, err := c.readKeyRef(reader)
			if err != nil {
				return Value{}, err
			}
			key := keyRef.Literal
			v, err := c.readValueWithField(reader, &key)
			if err != nil {
				return Value{}, err
			}
			out[i] = Entry(keyRef.Literal, v)
		}
		return NewMap(out...), nil
	}
	return Value{}, invalidTag(tag)
}

func (c *TwilicCodec) writeSchemaFields(schema *Schema, presence []bool, hasPresence bool, fields []Value, out *[]byte) error {
	indices, err := schemaPresentFieldIndices(schema, presence, hasPresence)
	if err != nil {
		return err
	}
	for i := range indices {
		if i >= len(fields) {
			return invalidData("schema fields length mismatch")
		}
		if err := c.writeSchemaFieldValue(&schema.Fields[indices[i]], &fields[i], out); err != nil {
			return err
		}
	}
	return nil
}

func (c *TwilicCodec) readSchemaFields(schema *Schema, presence []bool, hasPresence bool, n int, reader *Reader) ([]Value, error) {
	indices, err := schemaPresentFieldIndices(schema, presence, hasPresence)
	if err != nil {
		return nil, err
	}
	if len(indices) != n {
		return nil, invalidData("schema fields length")
	}
	out := make([]Value, n)
	for i := range indices {
		v, err := c.readSchemaFieldValue(&schema.Fields[indices[i]], reader)
		if err != nil {
			return nil, err
		}
		out[i] = v
	}
	return out, nil
}

func (c *TwilicCodec) writeSchemaFieldValue(field *SchemaField, value *Value, out *[]byte) error {
	switch normalizedLogicalType(field.LogicalType) {
	case "bool":
		if value.Kind != ValueBool {
			return invalidData("schema bool type mismatch")
		}
		if value.Bool {
			*out = append(*out, 1)
		} else {
			*out = append(*out, 0)
		}
	case "u8", "u16", "u32", "u64", "uint64", "uint":
		if value.Kind != ValueU64 {
			return invalidData("schema u64 type mismatch")
		}
		if min, max, ok := fieldU64Range(field); ok && value.U64 >= min && value.U64 <= max {
			*out = append(*out, 1)
			return writeFixedBitsU64(value.U64-min, rangeBitWidthU64(min, max), out)
		}
		*out = append(*out, 0)
		writeSmallestU64(value.U64, out)
	case "i8", "i16", "i32", "i64", "int64", "int":
		if value.Kind != ValueI64 {
			return invalidData("schema i64 type mismatch")
		}
		if min, max, ok := fieldI64Range(field); ok && value.I64 >= min && value.I64 <= max {
			*out = append(*out, 1)
			return writeFixedBitsU64(uint64(value.I64)-uint64(min), rangeBitWidthI64(min, max), out)
		}
		*out = append(*out, 0)
		writeSmallestU64(encodeZigzag(value.I64), out)
	case "f64", "float64", "float":
		if value.Kind != ValueF64 {
			return invalidData("schema f64 type mismatch")
		}
		appendF64LE(out, value.F64)
	case "string":
		if value.Kind != ValueString {
			return invalidData("schema string type mismatch")
		}
		if len(field.EnumValues) > 0 {
			for i := range field.EnumValues {
				if field.EnumValues[i] == value.Str {
					*out = append(*out, 1)
					encodeVaruint(uint64(i), out)
					return nil
				}
			}
			return invalidData("schema string enum")
		}
		*out = append(*out, 0)
		encodeString(value.Str, out)
	case "binary":
		if value.Kind != ValueBinary {
			return invalidData("schema binary type mismatch")
		}
		encodeBytes(value.Bin, out)
	default:
		c.writeValue(value, out)
	}
	return nil
}

func (c *TwilicCodec) readSchemaFieldValue(field *SchemaField, reader *Reader) (Value, error) {
	switch normalizedLogicalType(field.LogicalType) {
	case "bool":
		b, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		switch b {
		case 0:
			return NewBool(false), nil
		case 1:
			return NewBool(true), nil
		default:
			return Value{}, invalidData("schema bool value")
		}
	case "u8", "u16", "u32", "u64", "uint64", "uint":
		mode, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		switch mode {
		case 0:
			v, err := readSmallestU64(reader)
			if err != nil {
				return Value{}, err
			}
			return NewU64(v), nil
		case 1:
			min, max, ok := fieldU64Range(field)
			if !ok {
				return Value{}, invalidData("schema u64 range mode")
			}
			offset, err := readFixedBitsU64(reader, rangeBitWidthU64(min, max))
			if err != nil {
				return Value{}, err
			}
			if offset > max-min {
				return Value{}, invalidData("schema u64 range overflow")
			}
			v := min + offset
			if v > max {
				return Value{}, invalidData("schema u64 range overflow")
			}
			return NewU64(v), nil
		default:
			return Value{}, invalidData("schema u64 mode")
		}
	case "i8", "i16", "i32", "i64", "int64", "int":
		mode, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		switch mode {
		case 0:
			v, err := readSmallestU64(reader)
			if err != nil {
				return Value{}, err
			}
			return NewI64(decodeZigzag(v)), nil
		case 1:
			min, max, ok := fieldI64Range(field)
			if !ok {
				return Value{}, invalidData("schema i64 range mode")
			}
			offset, err := readFixedBitsU64(reader, rangeBitWidthI64(min, max))
			if err != nil {
				return Value{}, err
			}
			if offset > i64RangeSpan(min, max) {
				return Value{}, invalidData("schema i64 range overflow")
			}
			v := int64(uint64(min) + offset)
			if v < min || v > max {
				return Value{}, invalidData("schema i64 range overflow")
			}
			return NewI64(v), nil
		default:
			return Value{}, invalidData("schema i64 mode")
		}
	case "f64", "float64", "float":
		f, err := readF64LE(reader)
		if err != nil {
			return Value{}, err
		}
		return NewF64(f), nil
	case "string":
		mode, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		switch mode {
		case 0:
			s, err := reader.readString()
			if err != nil {
				return Value{}, err
			}
			return NewString(s), nil
		case 1:
			code, err := reader.readVaruint()
			if err != nil {
				return Value{}, err
			}
			if int(code) >= len(field.EnumValues) {
				return Value{}, invalidData("schema string enum code")
			}
			return NewString(field.EnumValues[code]), nil
		default:
			return Value{}, invalidData("schema string mode")
		}
	case "binary":
		b, err := reader.readBytes()
		if err != nil {
			return Value{}, err
		}
		return NewBinary(b), nil
	default:
		return c.readValue(reader)
	}
}

func (c *TwilicCodec) writeKeyRef(keyRef KeyRef, out *[]byte) {
	if keyRef.IsID {
		*out = append(*out, 1)
		encodeVaruint(keyRef.ID, out)
		return
	}
	// Literal keys are always written on the wire as literals (Rust parity).
	// mapMessage may register keys before building KeyRefLiteral; do not re-emit as refs here.
	*out = append(*out, 0)
	encodeString(keyRef.Literal, out)
	c.State.KeyTable.Register(keyRef.Literal)
}

func (c *TwilicCodec) readKeyRef(reader *Reader) (KeyRef, error) {
	mode, err := reader.readU8()
	if err != nil {
		return KeyRef{}, err
	}
	if mode == 1 {
		id, err := reader.readVaruint()
		if err != nil {
			return KeyRef{}, err
		}
		key, ok := c.State.KeyTable.GetValue(id)
		if !ok {
			return KeyRef{}, c.referenceError("key_id", id)
		}
		return KeyRefLiteral(key), nil
	}
	if mode != 0 {
		return KeyRef{}, invalidData("key ref mode")
	}
	s, err := reader.readString()
	if err != nil {
		return KeyRef{}, err
	}
	c.State.KeyTable.Register(s)
	return KeyRefLiteral(s), nil
}

func (c *TwilicCodec) writePresence(presence []bool, hasPresence bool, out *[]byte) {
	if !hasPresence {
		*out = append(*out, 0)
		return
	}
	*out = append(*out, 1)
	encodeBitmap(presence, out)
}

func (c *TwilicCodec) readPresence(reader *Reader) ([]bool, bool, error) {
	flag, err := reader.readU8()
	if err != nil {
		return nil, false, err
	}
	if flag == 0 {
		return nil, false, nil
	}
	if flag != 1 {
		return nil, false, invalidData("presence flag")
	}
	bits, err := reader.readBitmap()
	if err != nil {
		return nil, false, err
	}
	return bits, true, nil
}

func typedVectorLen(data *TypedVectorData) int {
	switch data.Kind {
	case ElementTypeBool:
		return len(data.Bools)
	case ElementTypeI64:
		return len(data.I64s)
	case ElementTypeU64:
		return len(data.U64s)
	case ElementTypeF64:
		return len(data.F64s)
	case ElementTypeString:
		return len(data.Strings)
	case ElementTypeBinary:
		return len(data.Binary)
	case ElementTypeValue:
		return len(data.Values)
	default:
		return 0
	}
}

func (c *TwilicCodec) writeTypedVector(vector *TypedVector, out *[]byte) error {
	*out = append(*out, byte(vector.ElementType))
	encodeVaruint(uint64(typedVectorLen(&vector.Data)), out)
	*out = append(*out, byte(vector.Codec))
	switch vector.ElementType {
	case ElementTypeBool:
		encodeBitmap(vector.Data.Bools, out)
	case ElementTypeI64:
		encodeI64Vector(vector.Data.I64s, vector.Codec, out)
	case ElementTypeU64:
		encodeU64Vector(vector.Data.U64s, vector.Codec, out)
	case ElementTypeF64:
		encodeF64Vector(vector.Data.F64s, vector.Codec, out)
	case ElementTypeString:
		c.writeStringVector(vector.Data.Strings, vector.Codec, out)
	case ElementTypeBinary:
		encodeVaruint(uint64(len(vector.Data.Binary)), out)
		for i := range vector.Data.Binary {
			encodeBytes(vector.Data.Binary[i], out)
		}
	case ElementTypeValue:
		encodeVaruint(uint64(len(vector.Data.Values)), out)
		for i := range vector.Data.Values {
			c.writeValue(&vector.Data.Values[i], out)
		}
	default:
		return invalidData("unsupported element type")
	}
	return nil
}

func (c *TwilicCodec) readTypedVector(reader *Reader, forcedElement *ElementType, expectedCodec *VectorCodec) (TypedVector, error) {
	var elemType ElementType
	if forcedElement == nil {
		elemByte, err := reader.readU8()
		if err != nil {
			return TypedVector{}, err
		}
		var ok bool
		elemType, ok = elementTypeFromByte(elemByte)
		if !ok {
			return TypedVector{}, invalidData("vector element type")
		}
	} else {
		elemType = *forcedElement
	}
	expectedLen, err := reader.readCount()
	if err != nil {
		return TypedVector{}, err
	}
	codecByte, err := reader.readU8()
	if err != nil {
		return TypedVector{}, err
	}
	codec, ok := vectorCodecFromByte(codecByte)
	if !ok {
		return TypedVector{}, invalidData("vector codec")
	}
	if expectedCodec != nil && codec != *expectedCodec {
		return TypedVector{}, invalidData("column codec mismatch")
	}
	tv := TypedVector{ElementType: elemType, Codec: codec, Data: TypedVectorData{Kind: elemType}}
	switch elemType {
	case ElementTypeBool:
		values, err := reader.readBitmap()
		if err != nil {
			return TypedVector{}, err
		}
		tv.Data.Bools = values
	case ElementTypeI64:
		values, err := decodeI64Vector(reader, codec)
		if err != nil {
			return TypedVector{}, err
		}
		tv.Data.I64s = values
	case ElementTypeU64:
		values, err := decodeU64Vector(reader, codec)
		if err != nil {
			return TypedVector{}, err
		}
		tv.Data.U64s = values
	case ElementTypeF64:
		values, err := decodeF64Vector(reader, codec)
		if err != nil {
			return TypedVector{}, err
		}
		tv.Data.F64s = values
	case ElementTypeString:
		values, err := c.readStringVector(reader, codec)
		if err != nil {
			return TypedVector{}, err
		}
		tv.Data.Strings = values
	case ElementTypeBinary:
		n, err := reader.readCount()
		if err != nil {
			return TypedVector{}, err
		}
		tv.Data.Binary = make([][]byte, int(n))
		for i := 0; i < int(n); i++ {
			b, err := reader.readBytes()
			if err != nil {
				return TypedVector{}, err
			}
			tv.Data.Binary[i] = b
		}
	case ElementTypeValue:
		n, err := reader.readCount()
		if err != nil {
			return TypedVector{}, err
		}
		tv.Data.Values = make([]Value, int(n))
		for i := 0; i < int(n); i++ {
			v, err := c.readValue(reader)
			if err != nil {
				return TypedVector{}, err
			}
			tv.Data.Values[i] = v
		}
	}
	if uint64(typedVectorLen(&tv.Data)) != expectedLen {
		return TypedVector{}, invalidData("typed vector length mismatch")
	}
	return tv, nil
}

func (c *TwilicCodec) writeColumn(column *Column, out *[]byte) error {
	encodeVaruint(column.FieldID, out)
	*out = append(*out, byte(column.NullStrategy))
	switch column.NullStrategy {
	case NullStrategyPresenceBitmap, NullStrategyInvertedPresenceBitmap:
		if !column.HasPresence || column.Presence == nil {
			return invalidData("missing column presence bitmap")
		}
		encodeBitmap(column.Presence, out)
	}
	*out = append(*out, byte(column.Codec))
	if column.DictionaryID != nil {
		*out = append(*out, 1)
		encodeVaruint(*column.DictionaryID, out)
		if payload, ok := c.State.Dictionaries[*column.DictionaryID]; ok {
			if profile, ok := c.State.DictionaryProfiles[*column.DictionaryID]; ok {
				*out = append(*out, 1)
				encodeVaruint(profile.Version, out)
				encodeVaruint(profile.Hash, out)
				encodeVaruint(profile.ExpiresAt, out)
				*out = append(*out, byte(profile.Fallback))
				encodeBytes(payload, out)
			} else {
				*out = append(*out, 0)
			}
		} else {
			*out = append(*out, 0)
		}
	} else {
		*out = append(*out, 0)
	}
	var trainedBlock []byte
	if column.DictionaryID != nil && column.Values.Kind == ElementTypeString {
		if column.Codec == VectorCodecDictionary || column.Codec == VectorCodecStringRef {
			if payload, ok := c.State.Dictionaries[*column.DictionaryID]; ok {
				dictionary, err := decodeTrainedDictionaryPayload(payload)
				if err == nil {
					block, ok, err := encodeTrainedDictionaryBlock(column.Values.Strings, dictionary)
					if err != nil {
						return err
					}
					if ok {
						trainedBlock = block
					}
				}
			}
		}
	}
	if trainedBlock != nil {
		*out = append(*out, 1)
		encodeBytes(trainedBlock, out)
		return nil
	}
	*out = append(*out, 0)
	tv := TypedVector{
		ElementType: column.Values.Kind,
		Codec:       column.Codec,
		Data:        cloneTypedVectorData(column.Values),
	}
	return c.writeTypedVector(&tv, out)
}

func (c *TwilicCodec) readColumn(reader *Reader) (Column, error) {
	fieldID, err := reader.readVaruint()
	if err != nil {
		return Column{}, err
	}
	nullByte, err := reader.readU8()
	if err != nil {
		return Column{}, err
	}
	nullStrategy, ok := nullStrategyFromByte(nullByte)
	if !ok {
		return Column{}, invalidData("null strategy")
	}
	var presence []bool
	var hasPresence bool
	switch nullStrategy {
	case NullStrategyPresenceBitmap, NullStrategyInvertedPresenceBitmap:
		presence, err = reader.readBitmap()
		if err != nil {
			return Column{}, err
		}
		hasPresence = true
	}
	codecByte, err := reader.readU8()
	if err != nil {
		return Column{}, err
	}
	codec, ok := vectorCodecFromByte(codecByte)
	if !ok {
		return Column{}, invalidData("column codec")
	}
	hasDict, err := reader.readU8()
	if err != nil {
		return Column{}, err
	}
	var dictionaryID *uint64
	switch hasDict {
	case 0:
	case 1:
		id, err := reader.readVaruint()
		if err != nil {
			return Column{}, err
		}
		hasProfile, err := reader.readU8()
		if err != nil {
			return Column{}, err
		}
		switch hasProfile {
		case 0:
			if _, ok := c.State.Dictionaries[id]; !ok {
				return Column{}, c.referenceError("dict_id", id)
			}
		case 1:
			version, err := reader.readVaruint()
			if err != nil {
				return Column{}, err
			}
			hash, err := reader.readVaruint()
			if err != nil {
				return Column{}, err
			}
			expiresAt, err := reader.readVaruint()
			if err != nil {
				return Column{}, err
			}
			fallbackByte, err := reader.readU8()
			if err != nil {
				return Column{}, err
			}
			fallback, ok := dictionaryFallbackFromByte(fallbackByte)
			if !ok {
				return Column{}, invalidData("dictionary fallback")
			}
			payload, err := reader.readBytes()
			if err != nil {
				return Column{}, err
			}
			if dictionaryPayloadHash(payload) != hash {
				return Column{}, invalidData("dictionary profile hash mismatch")
			}
			c.State.Dictionaries[id] = payload
			c.State.DictionaryProfiles[id] = DictionaryProfile{
				Version: version, Hash: hash, ExpiresAt: expiresAt, Fallback: fallback,
			}
		default:
			return Column{}, invalidData("dictionary profile flag")
		}
		dictionaryID = &id
	default:
		return Column{}, invalidData("dictionary flag")
	}
	payloadMode, err := reader.readU8()
	if err != nil {
		return Column{}, err
	}
	var values TypedVectorData
	switch payloadMode {
	case 0:
		tv, err := c.readTypedVector(reader, nil, &codec)
		if err != nil {
			return Column{}, err
		}
		values = tv.Data
	case 1:
		if dictionaryID == nil {
			return Column{}, invalidData("trained dictionary block requires dict_id")
		}
		if codec != VectorCodecDictionary && codec != VectorCodecStringRef {
			return Column{}, invalidData("trained dictionary block requires string dictionary codec")
		}
		dictionaryPayload, ok := c.State.Dictionaries[*dictionaryID]
		if !ok {
			return Column{}, c.referenceError("dict_id", *dictionaryID)
		}
		dictionary, err := decodeTrainedDictionaryPayload(dictionaryPayload)
		if err != nil {
			return Column{}, err
		}
		block, err := reader.readBytes()
		if err != nil {
			return Column{}, err
		}
		strings, err := decodeTrainedDictionaryBlock(block, dictionary)
		if err != nil {
			return Column{}, err
		}
		values = TypedVectorData{Kind: ElementTypeString, Strings: strings}
	default:
		return Column{}, invalidData("column payload mode")
	}
	return Column{
		FieldID:      fieldID,
		NullStrategy: nullStrategy,
		Presence:     presence,
		HasPresence:  hasPresence,
		Codec:        codec,
		DictionaryID: dictionaryID,
		Values:       values,
	}, nil
}

func (c *TwilicCodec) writeSchemaBatchColumn(column *Column, count uint64, out *[]byte) error {
	strategy := byte(0)
	switch column.NullStrategy {
	case NullStrategyNone, NullStrategyAllPresentElided:
		strategy = 0
	case NullStrategyPresenceBitmap:
		strategy = 1
	case NullStrategyInvertedPresenceBitmap:
		strategy = 2
	default:
		return invalidData("schema batch null strategy")
	}
	*out = append(*out, strategy)
	if strategy == 1 || strategy == 2 {
		if !column.HasPresence || column.Presence == nil {
			return invalidData("missing schema batch presence")
		}
		if err := writeFixedBitmap(column.Presence, int(count), out); err != nil {
			return err
		}
	}
	*out = append(*out, byte(column.Codec))
	vector := TypedVector{
		ElementType: typedVectorDataElementType(column.Values),
		Codec:       column.Codec,
		Data:        cloneTypedVectorData(column.Values),
	}
	return c.writeTypedVector(&vector, out)
}

func (c *TwilicCodec) readSchemaBatchColumn(fieldID uint64, count uint64, reader *Reader) (Column, error) {
	strategy, err := reader.readU8()
	if err != nil {
		return Column{}, err
	}
	var nullStrategy NullStrategy
	var presence []bool
	var hasPresence bool
	switch strategy {
	case 0:
		nullStrategy = NullStrategyNone
	case 1:
		nullStrategy = NullStrategyPresenceBitmap
		presence, err = readFixedBitmap(reader, int(count))
		if err != nil {
			return Column{}, err
		}
		hasPresence = true
	case 2:
		nullStrategy = NullStrategyInvertedPresenceBitmap
		presence, err = readFixedBitmap(reader, int(count))
		if err != nil {
			return Column{}, err
		}
		hasPresence = true
	default:
		return Column{}, invalidData("schema batch null strategy")
	}
	codecByte, err := reader.readU8()
	if err != nil {
		return Column{}, err
	}
	codec, ok := vectorCodecFromByte(codecByte)
	if !ok {
		return Column{}, invalidData("codec")
	}
	tv, err := c.readTypedVector(reader, nil, &codec)
	if err != nil {
		return Column{}, err
	}
	return Column{
		FieldID:      fieldID,
		NullStrategy: nullStrategy,
		Presence:     presence,
		HasPresence:  hasPresence,
		Codec:        codec,
		Values:       tv.Data,
	}, nil
}

func (c *TwilicCodec) writeBoundRecordBody(schema *Schema, strategy PresenceStrategy, record *BoundRecord, out *[]byte) error {
	presence, err := boundRecordPresence(schema, record, strategy)
	if err != nil {
		return err
	}
	switch strategy {
	case PresenceStrategyNormal:
		if err := writeFixedBitmap(presence, len(presence), out); err != nil {
			return err
		}
	case PresenceStrategyInverted:
		inverted := make([]bool, len(presence))
		for i := range presence {
			inverted[i] = !presence[i]
		}
		if err := writeFixedBitmap(inverted, len(inverted), out); err != nil {
			return err
		}
	case PresenceStrategyAllPresent:
	default:
		return invalidData("presence strategy")
	}
	return c.writeSchemaFields(schema, presence, strategy != PresenceStrategyAllPresent, record.Fields, out)
}

func (c *TwilicCodec) readBoundRecordBody(schema *Schema, strategy PresenceStrategy, reader *Reader) (BoundRecord, error) {
	optionalTotal := schemaOptionalFieldCount(schema)
	var presence []bool
	var hasPresence bool
	var err error
	switch strategy {
	case PresenceStrategyNormal:
		presence, err = readFixedBitmap(reader, optionalTotal)
		hasPresence = true
	case PresenceStrategyInverted:
		presence, err = readFixedBitmap(reader, optionalTotal)
		if err == nil {
			for i := range presence {
				presence[i] = !presence[i]
			}
		}
		hasPresence = true
	case PresenceStrategyAllPresent:
	default:
		return BoundRecord{}, invalidData("presence strategy")
	}
	if err != nil {
		return BoundRecord{}, err
	}
	indices, err := schemaPresentFieldIndices(schema, presence, hasPresence)
	if err != nil {
		return BoundRecord{}, err
	}
	fields, err := c.readSchemaFields(schema, presence, hasPresence, len(indices), reader)
	if err != nil {
		return BoundRecord{}, err
	}
	return BoundRecord{Presence: presence, HasPresence: hasPresence, Fields: fields}, nil
}

func (c *TwilicCodec) writeControl(control *ControlMessage, out *[]byte) error {
	*out = append(*out, byte(control.Opcode))
	switch control.Opcode {
	case ControlOpcodeRegisterKeys:
		encodeVaruint(uint64(len(control.RegisterKeys)), out)
		for i := range control.RegisterKeys {
			encodeString(control.RegisterKeys[i], out)
			c.State.KeyTable.Register(control.RegisterKeys[i])
		}
	case ControlOpcodeRegisterShape:
		if control.RegisterShape == nil {
			return invalidData("register shape payload missing")
		}
		encodeVaruint(control.RegisterShape.ShapeID, out)
		encodeVaruint(uint64(len(control.RegisterShape.Keys)), out)
		keys := make([]string, 0, len(control.RegisterShape.Keys))
		for i := range control.RegisterShape.Keys {
			c.writeKeyRef(control.RegisterShape.Keys[i], out)
			keys = append(keys, control.RegisterShape.Keys[i].Literal)
		}
		c.State.ShapeTable.RegisterWithID(control.RegisterShape.ShapeID, keys)
	case ControlOpcodeRegisterStrings:
		encodeVaruint(uint64(len(control.RegisterStrings)), out)
		for i := range control.RegisterStrings {
			encodeString(control.RegisterStrings[i], out)
			c.State.StringTable.Register(control.RegisterStrings[i])
		}
	case ControlOpcodePromoteStringFieldToEnum:
		if control.PromoteStringFieldToEnum == nil {
			return invalidData("promote enum payload missing")
		}
		encodeString(control.PromoteStringFieldToEnum.FieldIdentity, out)
		encodeVaruint(uint64(len(control.PromoteStringFieldToEnum.Values)), out)
		for i := range control.PromoteStringFieldToEnum.Values {
			encodeString(control.PromoteStringFieldToEnum.Values[i], out)
		}
		c.State.FieldEnums[control.PromoteStringFieldToEnum.FieldIdentity] = append([]string(nil), control.PromoteStringFieldToEnum.Values...)
	case ControlOpcodeResetTables:
		c.State.ResetTables()
	case ControlOpcodeResetState:
		c.State.ResetState()
	default:
		return invalidData("control opcode")
	}
	return nil
}

func (c *TwilicCodec) readControl(reader *Reader) (ControlMessage, error) {
	opByte, err := reader.readU8()
	if err != nil {
		return ControlMessage{}, err
	}
	opcode, ok := controlOpcodeFromByte(opByte)
	if !ok {
		return ControlMessage{}, invalidData("control opcode")
	}
	msg := ControlMessage{Opcode: opcode}
	switch opcode {
	case ControlOpcodeRegisterKeys:
		n, err := reader.readCount()
		if err != nil {
			return ControlMessage{}, err
		}
		msg.RegisterKeys = make([]string, int(n))
		for i := 0; i < int(n); i++ {
			s, err := reader.readString()
			if err != nil {
				return ControlMessage{}, err
			}
			msg.RegisterKeys[i] = s
			c.State.KeyTable.Register(s)
		}
	case ControlOpcodeRegisterShape:
		shapeID, err := reader.readCount(65535)
		if err != nil {
			return ControlMessage{}, err
		}
		n, err := reader.readCount()
		if err != nil {
			return ControlMessage{}, err
		}
		keys := make([]KeyRef, int(n))
		keyNames := make([]string, int(n))
		for i := 0; i < int(n); i++ {
			k, err := c.readKeyRef(reader)
			if err != nil {
				return ControlMessage{}, err
			}
			keys[i] = k
			keyNames[i] = k.Literal
		}
		c.State.ShapeTable.RegisterWithID(shapeID, keyNames)
		msg.RegisterShape = &RegisterShapeControl{ShapeID: shapeID, Keys: keys}
	case ControlOpcodeRegisterStrings:
		n, err := reader.readCount()
		if err != nil {
			return ControlMessage{}, err
		}
		msg.RegisterStrings = make([]string, int(n))
		for i := 0; i < int(n); i++ {
			s, err := reader.readString()
			if err != nil {
				return ControlMessage{}, err
			}
			msg.RegisterStrings[i] = s
			c.State.StringTable.Register(s)
		}
	case ControlOpcodePromoteStringFieldToEnum:
		fieldIdentity, err := reader.readString()
		if err != nil {
			return ControlMessage{}, err
		}
		n, err := reader.readCount()
		if err != nil {
			return ControlMessage{}, err
		}
		values := make([]string, int(n))
		for i := 0; i < int(n); i++ {
			values[i], err = reader.readString()
			if err != nil {
				return ControlMessage{}, err
			}
		}
		c.State.FieldEnums[fieldIdentity] = append([]string(nil), values...)
		msg.PromoteStringFieldToEnum = &PromoteEnumControl{
			FieldIdentity: fieldIdentity,
			Values:        values,
		}
	case ControlOpcodeResetTables:
		msg.ResetTables = true
		c.State.ResetTables()
	case ControlOpcodeResetState:
		msg.ResetState = true
		c.State.ResetState()
	}
	return msg, nil
}

func (c *TwilicCodec) writeBaseRef(baseRef BaseRef, out *[]byte) {
	if baseRef.Previous {
		*out = append(*out, 0)
		return
	}
	*out = append(*out, 1)
	encodeVaruint(baseRef.BaseID, out)
}

func (c *TwilicCodec) readBaseRef(reader *Reader) (BaseRef, error) {
	mode, err := reader.readU8()
	if err != nil {
		return BaseRef{}, err
	}
	switch mode {
	case 0:
		return BaseRefPrevious(), nil
	case 1:
		id, err := reader.readVaruint()
		if err != nil {
			return BaseRef{}, err
		}
		return BaseRefID(id), nil
	default:
		return BaseRef{}, invalidData("base ref")
	}
}

func (c *TwilicCodec) writeControlStreamPayload(codec ControlStreamCodec, payload []byte, out *[]byte) {
	var encoded []byte
	switch codec {
	case ControlStreamCodecPlain:
		encoded = append([]byte(nil), payload...)
	case ControlStreamCodecRle:
		encoded = rleEncodeBytes(payload)
	case ControlStreamCodecBitpack:
		encoded = controlBitpackEncodeBytes(payload)
	case ControlStreamCodecHuffman:
		encoded = controlHuffmanEncodeBytes(payload)
	case ControlStreamCodecFse:
		encoded = controlFseEncodeBytes(payload)
	}
	encodeBytes(encoded, out)
}

func (c *TwilicCodec) readControlStreamPayload(codec ControlStreamCodec, reader *Reader) ([]byte, error) {
	encoded, err := reader.readBytes()
	if err != nil {
		return nil, err
	}
	switch codec {
	case ControlStreamCodecPlain:
		return encoded, nil
	case ControlStreamCodecRle:
		return rleDecodeBytes(encoded)
	case ControlStreamCodecBitpack:
		return controlBitpackDecodeBytes(encoded)
	case ControlStreamCodecHuffman:
		return controlHuffmanDecodeBytes(encoded)
	case ControlStreamCodecFse:
		return controlFseDecodeBytes(encoded)
	default:
		return nil, invalidData("control stream codec")
	}
}

func (c *TwilicCodec) bestPrefixBase(value string) (uint64, int, bool) {
	bestID := uint64(0)
	bestLen := 0
	for id, candidate := range c.State.StringTable.ByID {
		n := commonPrefixLen([]byte(value), []byte(candidate))
		if n > bestLen {
			bestLen = n
			bestID = uint64(id)
		}
	}
	if bestLen == 0 {
		return 0, 0, false
	}
	return bestID, bestLen, true
}

func (c *TwilicCodec) writeStringVector(values []string, codec VectorCodec, out *[]byte) {
	switch codec {
	case VectorCodecDictionary:
		dict := make(map[string]uint64)
		uniq := make([]string, 0)
		refs := make([]uint64, len(values))
		for i := range values {
			if id, ok := dict[values[i]]; ok {
				refs[i] = id
			} else {
				id := uint64(len(uniq))
				dict[values[i]] = id
				uniq = append(uniq, values[i])
				refs[i] = id
			}
		}
		encodeVaruint(uint64(len(uniq)), out)
		for i := range uniq {
			encodeString(uniq[i], out)
		}
		encodeU64Vector(refs, VectorCodecDirectBitpack, out)
	case VectorCodecStringRef:
		encodeVaruint(uint64(len(values)), out)
		for i := range values {
			if id, ok := c.State.StringTable.GetID(values[i]); ok {
				encodeVaruint(id, out)
			} else {
				id := c.State.StringTable.Register(values[i])
				encodeVaruint(id, out)
			}
		}
	case VectorCodecPrefixDelta:
		encodeVaruint(uint64(len(values)), out)
		prev := ""
		for i := range values {
			prefix := commonPrefixLen([]byte(prev), []byte(values[i]))
			encodeVaruint(uint64(prefix), out)
			encodeString(values[i][prefix:], out)
			prev = values[i]
		}
	default:
		encodeVaruint(uint64(len(values)), out)
		for i := range values {
			encodeString(values[i], out)
		}
	}
}

func (c *TwilicCodec) readStringVector(reader *Reader, codec VectorCodec) ([]string, error) {
	switch codec {
	case VectorCodecDictionary:
		dictN, err := reader.readCount()
		if err != nil {
			return nil, err
		}
		dict := make([]string, int(dictN))
		for i := 0; i < int(dictN); i++ {
			s, err := reader.readString()
			if err != nil {
				return nil, err
			}
			dict[i] = s
		}
		refs, err := decodeU64Vector(reader, VectorCodecDirectBitpack)
		if err != nil {
			return nil, err
		}
		out := make([]string, len(refs))
		for i := range refs {
			if int(refs[i]) >= len(dict) {
				return nil, invalidData("dictionary reference")
			}
			out[i] = dict[refs[i]]
		}
		return out, nil
	case VectorCodecStringRef:
		n, err := reader.readCount()
		if err != nil {
			return nil, err
		}
		out := make([]string, int(n))
		for i := 0; i < int(n); i++ {
			id, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			s, ok := c.State.StringTable.GetValue(id)
			if !ok {
				return nil, c.referenceError("string_id", id)
			}
			out[i] = s
		}
		return out, nil
	case VectorCodecPrefixDelta:
		n, err := reader.readCount()
		if err != nil {
			return nil, err
		}
		out := make([]string, int(n))
		prev := ""
		for i := 0; i < int(n); i++ {
			prefix, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			suffix, err := reader.readString()
			if err != nil {
				return nil, err
			}
			if int(prefix) > len(prev) {
				return nil, invalidData("prefix delta in string vector")
			}
			out[i] = prev[:prefix] + suffix
			prev = out[i]
		}
		return out, nil
	default:
		n, err := reader.readCount()
		if err != nil {
			return nil, err
		}
		out := make([]string, int(n))
		for i := 0; i < int(n); i++ {
			out[i], err = reader.readString()
			if err != nil {
				return nil, err
			}
		}
		return out, nil
	}
}

func (c *TwilicCodec) applyStatePatch(baseRef BaseRef, operations []PatchOperation, literals []Value) (Message, error) {
	var base *Message
	if baseRef.Previous {
		if c.State.PreviousMessage == nil {
			return Message{}, c.referenceError("previous", 0)
		}
		b := c.State.PreviousMessage.Clone()
		base = &b
	} else {
		b, ok := c.State.GetBaseSnapshot(baseRef.BaseID)
		if !ok {
			return Message{}, c.referenceError("base_id", baseRef.BaseID)
		}
		base = b
	}
	_ = literals
	fields := messageFields(base)
	for i := range operations {
		op := operations[i]
		idx := int(op.FieldID)
		switch op.Opcode {
		case PatchOpcodeKeep:
		case PatchOpcodeReplaceScalar, PatchOpcodeReplaceVector, PatchOpcodeInsertField, PatchOpcodeStringRef, PatchOpcodePrefixDelta:
			if op.Value == nil {
				return Message{}, invalidData("patch operation missing value")
			}
			if idx < len(fields) {
				fields[idx] = op.Value.Clone()
			} else if idx == len(fields) {
				fields = append(fields, op.Value.Clone())
			} else {
				return Message{}, invalidData("patch field index out of range")
			}
		case PatchOpcodeDeleteField:
			if idx < 0 || idx >= len(fields) {
				return Message{}, invalidData("delete field index out of range")
			}
			fields = append(fields[:idx], fields[idx+1:]...)
		case PatchOpcodeAppendVector:
			if op.Value == nil || idx < 0 || idx >= len(fields) {
				return Message{}, invalidData("append vector patch invalid")
			}
			if fields[idx].Kind != ValueArray || op.Value.Kind != ValueArray {
				return Message{}, invalidData("append vector requires arrays")
			}
			fields[idx].Arr = append(fields[idx].Arr, op.Value.Arr...)
		case PatchOpcodeTruncateVector:
			if op.Value == nil || idx < 0 || idx >= len(fields) {
				return Message{}, invalidData("truncate vector patch invalid")
			}
			if fields[idx].Kind != ValueArray || op.Value.Kind != ValueU64 {
				return Message{}, invalidData("truncate vector requires array and u64")
			}
			n := int(op.Value.U64)
			if n < 0 || n > len(fields[idx].Arr) {
				return Message{}, invalidData("truncate length")
			}
			fields[idx].Arr = append([]Value(nil), fields[idx].Arr[:n]...)
		}
	}
	return rebuildMessageLike(base, fields)
}

func (c *TwilicCodec) observeDecodeShapeCandidate(keys []string) {
	if _, ok := c.State.ShapeTable.GetID(keys); ok {
		return
	}
	observed := c.State.ShapeTable.Observe(keys)
	if shouldRegisterShape(keys, observed) {
		c.State.ShapeTable.Register(keys)
	}
}

func (c *TwilicCodec) observeEncodeShapeCandidate(keys []string) uint64 {
	sk := shapeKey(keys)
	c.State.EncodeShapeObservations[sk]++
	count := c.State.EncodeShapeObservations[sk]
	if shouldRegisterShape(keys, count) {
		c.State.ShapeTable.Register(keys)
	}
	return count
}

type SessionEncoder struct {
	Codec *TwilicCodec
}

func NewSessionEncoder(options SessionOptions) *SessionEncoder {
	return &SessionEncoder{Codec: TwilicCodecWithOptions(options)}
}

func (e *SessionEncoder) Encode(value *Value) ([]byte, error) {
	msg := e.Codec.messageForValue(value)
	if e.Codec.State.Options.EnableStatePatch && e.Codec.State.PreviousMessage != nil && supportsStatePatch(e.Codec.State.PreviousMessage, &msg) {
		baseRef := BaseRefPrevious()
		ops, _ := diffMessage(e.Codec.State.PreviousMessage, &msg)
		patchMsg := Message{Kind: MessageKindStatePatch, StatePatch: &StatePatchMessage{
			BaseRef: baseRef, Operations: ops,
		}}
		patchSize := encodedSize(&patchMsg)
		fullSize := encodedSize(&msg)
		if patchSize < fullSize {
			bytes, err := e.Codec.EncodeMessage(&patchMsg)
			if err == nil {
				return bytes, nil
			}
		}
	}
	return e.Codec.EncodeMessage(&msg)
}

func (e *SessionEncoder) EncodeWithSchema(schema *Schema, value *Value) ([]byte, error) {
	e.registerSchema(schema)
	if value.Kind != ValueMap {
		return nil, invalidData("encode_with_schema expects map value")
	}
	presence := make([]bool, 0)
	fields := make([]Value, 0, len(schema.Fields))
	hasPresence := false
	for i := range schema.Fields {
		if v := lookupMapField(value, schema.Fields[i].Name); v != nil {
			if !schema.Fields[i].Required {
				presence = append(presence, true)
			}
			fields = append(fields, v.Clone())
		} else if schema.Fields[i].Required {
			if schema.Fields[i].DefaultValue != nil {
				fields = append(fields, schema.Fields[i].DefaultValue.Clone())
			} else {
				return nil, invalidData("missing required schema field")
			}
		} else {
			presence = append(presence, false)
			hasPresence = true
		}
	}
	msg := Message{
		Kind: MessageKindSchemaObject,
		SchemaObject: &SchemaObjectMessage{
			SchemaID:    &schema.SchemaID,
			Presence:    presence,
			HasPresence: hasPresence,
			Fields:      fields,
		},
	}
	return e.Codec.EncodeMessage(&msg)
}

func (e *SessionEncoder) EncodeBoundStream(schema *Schema, values []Value) ([]byte, error) {
	e.registerSchema(schema)
	records := make([]BoundRecord, 0, len(values))
	anyAbsent := false
	for i := range values {
		record, err := boundRecordFromValue(schema, &values[i])
		if err != nil {
			return nil, err
		}
		if record.HasPresence {
			anyAbsent = true
		}
		records = append(records, record)
	}
	strategy := PresenceStrategyAllPresent
	if anyAbsent {
		strategy = PresenceStrategyNormal
	}
	msg := Message{Kind: MessageKindBoundStream, BoundStream: &BoundStreamMessage{
		SchemaID: schema.SchemaID, PresenceStrategy: strategy, Records: records,
	}}
	bytes, err := e.Codec.EncodeMessage(&msg)
	if err != nil {
		return nil, err
	}
	e.Codec.State.PreviousMessage = &msg
	size := len(bytes)
	e.Codec.State.PreviousMessageSize = &size
	e.recordFullMessageAsBase()
	return bytes, nil
}

func (e *SessionEncoder) EncodeBatchWithSchema(schema *Schema, values []Value) ([]byte, error) {
	e.registerSchema(schema)
	columns, err := schemaColumnsFromValues(schema, values)
	if err != nil {
		return nil, err
	}
	msg := Message{Kind: MessageKindSchemaBatch, SchemaBatch: &SchemaBatchMessage{
		SchemaID: schema.SchemaID, Count: uint64(len(values)), Columns: columns,
	}}
	bytes, err := e.Codec.EncodeMessage(&msg)
	if err != nil {
		return nil, err
	}
	e.Codec.State.PreviousMessage = &msg
	size := len(bytes)
	e.Codec.State.PreviousMessageSize = &size
	e.recordFullMessageAsBase()
	return bytes, nil
}

func (e *SessionEncoder) EncodeBatch(values []Value) ([]byte, error) {
	if len(values) == 0 {
		msg := Message{Kind: MessageKindRowBatch, RowBatch: &RowBatchMessage{Rows: [][]Value{}}}
		return e.Codec.EncodeMessage(&msg)
	}
	var msg Message
	if len(values) >= 16 {
		cols := columnsFromMapValues(values)
		if cols == nil {
			cols = rowsToColumns(rowsFromValues(values))
		}
		if e.Codec.State.Options.EnableTrainedDictionary {
			applyDictionaryReferences(e.Codec.State, &cols)
		}
		msg = Message{Kind: MessageKindColumnBatch, ColumnBatch: &ColumnBatchMessage{
			Count: uint64(len(values)), Columns: cols,
		}}
	} else {
		msg = Message{Kind: MessageKindRowBatch, RowBatch: &RowBatchMessage{Rows: rowsFromValues(values)}}
	}
	bytes, err := e.Codec.EncodeMessage(&msg)
	if err != nil {
		return nil, err
	}
	e.Codec.State.PreviousMessage = &msg
	size := len(bytes)
	e.Codec.State.PreviousMessageSize = &size
	e.recordFullMessageAsBase()
	return bytes, nil
}

func (e *SessionEncoder) recordFullMessageAsBase() {
	if e.Codec.State.Options.MaxBaseSnapshots == 0 {
		return
	}
	if e.Codec.State.PreviousMessage == nil {
		return
	}
	baseID := e.Codec.State.AllocateBaseID()
	e.Codec.State.RegisterBaseSnapshot(baseID, *e.Codec.State.PreviousMessage)
}

func (e *SessionEncoder) EncodePatch(value *Value) ([]byte, error) {
	msg := e.Codec.messageForValue(value)
	if e.Codec.State.PreviousMessage == nil || !supportsStatePatch(e.Codec.State.PreviousMessage, &msg) {
		return e.Codec.EncodeMessage(&msg)
	}
	ops, _ := diffMessage(e.Codec.State.PreviousMessage, &msg)
	patchMsg := Message{Kind: MessageKindStatePatch, StatePatch: &StatePatchMessage{
		BaseRef:    BaseRefPrevious(),
		Operations: ops,
	}}
	if encodedSize(&patchMsg) >= encodedSize(&msg) {
		return e.Codec.EncodeMessage(&msg)
	}
	return e.Codec.EncodeMessage(&patchMsg)
}

func (e *SessionEncoder) EncodeMicroBatch(values []Value) ([]byte, error) {
	if len(values) == 0 {
		return e.EncodeBatch(values)
	}
	if !e.Codec.State.Options.EnableTemplateBatch || !hasUniformMicroBatchShape(values) {
		return e.EncodeBatch(values)
	}
	columns := columnsFromMapValues(values)
	if columns == nil {
		columns = rowsToColumns(rowsFromValues(values))
	}
	if e.Codec.State.Options.EnableTrainedDictionary {
		applyDictionaryReferences(e.Codec.State, &columns)
	}
	templateID, ok := findTemplateID(e.Codec.State.Templates, columns)
	if !ok {
		templateID = e.Codec.State.AllocateTemplateID()
		e.Codec.State.Templates[templateID] = templateDescriptorFromColumns(templateID, columns)
		e.Codec.State.TemplateColumns[templateID] = columns
		mask := make([]bool, len(columns))
		for i := range mask {
			mask[i] = true
		}
		msg := Message{Kind: MessageKindTemplateBatch, TemplateBatch: &TemplateBatchMessage{
			TemplateID: templateID, Count: uint64(len(values)), ChangedColumnMask: mask, Columns: columns,
		}}
		return e.Codec.EncodeMessage(&msg)
	}
	mask, changedCols := diffTemplateColumns(e.Codec.State.TemplateColumns[templateID], columns)
	e.Codec.State.TemplateColumns[templateID] = columns
	msg := Message{Kind: MessageKindTemplateBatch, TemplateBatch: &TemplateBatchMessage{
		TemplateID: templateID, Count: uint64(len(values)), ChangedColumnMask: mask, Columns: changedCols,
	}}
	return e.Codec.EncodeMessage(&msg)
}

func (e *SessionEncoder) Reset() {
	e.Codec.State.ResetState()
}

func (e *SessionEncoder) DecodeMessage(bytes []byte) (Message, error) {
	return e.Codec.DecodeMessage(bytes)
}

func (e *SessionEncoder) registerSchema(schema *Schema) {
	e.Codec.State.Schemas[schema.SchemaID] = *schema
	e.Codec.State.LastSchemaID = &schema.SchemaID
	for i := range schema.Fields {
		if len(schema.Fields[i].EnumValues) > 0 {
			e.Codec.State.FieldEnums[schema.Fields[i].Name] = append([]string(nil), schema.Fields[i].EnumValues...)
		}
	}
}

func lookupMapField(value *Value, key string) *Value {
	if value.Kind != ValueMap {
		return nil
	}
	for i := range value.Map {
		if value.Map[i].Key == key {
			v := value.Map[i].Value.Clone()
			return &v
		}
	}
	return nil
}

func schemaOptionalFieldCount(schema *Schema) int {
	count := 0
	for i := range schema.Fields {
		if !schema.Fields[i].Required {
			count++
		}
	}
	return count
}

func boundRecordFromValue(schema *Schema, value *Value) (BoundRecord, error) {
	if value.Kind != ValueMap {
		return BoundRecord{}, invalidData("bound stream expects map value")
	}
	fields := make([]Value, 0, len(schema.Fields))
	presence := make([]bool, 0, schemaOptionalFieldCount(schema))
	hasAbsent := false
	for i := range schema.Fields {
		field := &schema.Fields[i]
		fieldValue := lookupMapField(value, field.Name)
		if field.Required {
			if fieldValue != nil {
				fields = append(fields, fieldValue.Clone())
			} else if field.DefaultValue != nil {
				fields = append(fields, field.DefaultValue.Clone())
			} else {
				return BoundRecord{}, invalidData("missing required schema field")
			}
			continue
		}
		if fieldValue != nil {
			presence = append(presence, true)
			fields = append(fields, fieldValue.Clone())
		} else {
			presence = append(presence, false)
			hasAbsent = true
		}
	}
	return BoundRecord{Presence: presence, HasPresence: hasAbsent, Fields: fields}, nil
}

func schemaColumnsFromValues(schema *Schema, values []Value) ([]Column, error) {
	columns := make([]Column, 0, len(schema.Fields))
	for i := range schema.Fields {
		field := &schema.Fields[i]
		columnValues := make([]Value, 0, len(values))
		presence := make([]bool, 0, len(values))
		hasAbsent := false
		for rowIdx := range values {
			value := &values[rowIdx]
			if value.Kind != ValueMap {
				return nil, invalidData("schema batch expects map values")
			}
			fieldValue := lookupMapField(value, field.Name)
			if fieldValue != nil {
				presence = append(presence, true)
				columnValues = append(columnValues, fieldValue.Clone())
			} else if field.Required {
				if field.DefaultValue != nil {
					presence = append(presence, true)
					columnValues = append(columnValues, field.DefaultValue.Clone())
				} else {
					return nil, invalidData("missing required schema field")
				}
			} else {
				presence = append(presence, false)
				hasAbsent = true
			}
		}
		nullStrategy := NullStrategyNone
		var columnPresence []bool
		var hasPresence bool
		if hasAbsent {
			nullStrategy = NullStrategyPresenceBitmap
			columnPresence = presence
			hasPresence = true
		}
		codec, tvd := inferColumnCodecAndValues(columnValues)
		columns = append(columns, Column{
			FieldID:      field.Number,
			NullStrategy: nullStrategy,
			Presence:     columnPresence,
			HasPresence:  hasPresence,
			Codec:        codec,
			Values:       tvd,
		})
	}
	return columns, nil
}

func boundRecordPresence(schema *Schema, record *BoundRecord, strategy PresenceStrategy) ([]bool, error) {
	optionalTotal := schemaOptionalFieldCount(schema)
	if record.HasPresence {
		if len(record.Presence) != optionalTotal {
			return nil, invalidData("schema optional presence length")
		}
		return append([]bool(nil), record.Presence...), nil
	}
	switch strategy {
	case PresenceStrategyNormal, PresenceStrategyInverted, PresenceStrategyAllPresent:
		presence := make([]bool, optionalTotal)
		for i := range presence {
			presence[i] = true
		}
		return presence, nil
	default:
		return nil, invalidData("presence strategy")
	}
}

func writeFixedBitmap(bits []bool, bitCount int, out *[]byte) error {
	if len(bits) != bitCount {
		return invalidData("fixed bitmap length")
	}
	var current byte
	for i, bit := range bits {
		if bit {
			current |= 1 << (i % 8)
		}
		if i%8 == 7 {
			*out = append(*out, current)
			current = 0
		}
	}
	if bitCount%8 != 0 {
		*out = append(*out, current)
	}
	return nil
}

func readFixedBitmap(reader *Reader, bitCount int) ([]bool, error) {
	byteCount := (bitCount + 7) / 8
	bytes, err := reader.readExact(byteCount)
	if err != nil {
		return nil, err
	}
	bits := make([]bool, bitCount)
	for i := 0; i < bitCount; i++ {
		bits[i] = ((bytes[i/8] >> (i % 8)) & 1) == 1
	}
	if bitCount%8 != 0 {
		unusedMask := byte(0xFF << (bitCount % 8))
		if bytes[len(bytes)-1]&unusedMask != 0 {
			return nil, invalidData("fixed bitmap padding")
		}
	}
	return bits, nil
}

func fieldU64Range(field *SchemaField) (uint64, uint64, bool) {
	if field.Min == nil || field.Max == nil {
		return 0, 0, false
	}
	min := *field.Min
	max := *field.Max
	if min < 0 || max < min {
		return 0, 0, false
	}
	return uint64(min), uint64(max), true
}

func fieldI64Range(field *SchemaField) (int64, int64, bool) {
	if field.Min == nil || field.Max == nil {
		return 0, 0, false
	}
	min := *field.Min
	max := *field.Max
	if max < min {
		return 0, 0, false
	}
	return min, max, true
}

func rangeBitWidthU64(min, max uint64) uint8 {
	span := max - min
	if span == 0 {
		return 0
	}
	return uint8(bits.Len64(span))
}

func rangeBitWidthI64(min, max int64) uint8 {
	span := i64RangeSpan(min, max)
	if span == 0 {
		return 0
	}
	return uint8(bits.Len64(span))
}

func i64RangeSpan(min, max int64) uint64 {
	if min < 0 && max >= 0 {
		return uint64(max) + uint64(-(min + 1)) + 1
	}
	return uint64(max - min)
}

func writeFixedBitsU64(value uint64, bitCount uint8, out *[]byte) error {
	if bitCount > 64 {
		return invalidData("fixed bit width")
	}
	if bitCount == 0 {
		if value != 0 {
			return invalidData("fixed bit width value overflow")
		}
		return nil
	}
	if bitCount < 64 && value>>bitCount != 0 {
		return invalidData("fixed bit width value overflow")
	}
	byteLen := (int(bitCount) + 7) / 8
	for i := 0; i < byteLen; i++ {
		*out = append(*out, byte(value>>(i*8)))
	}
	return nil
}

func readFixedBitsU64(reader *Reader, bitCount uint8) (uint64, error) {
	if bitCount > 64 {
		return 0, invalidData("fixed bit width")
	}
	if bitCount == 0 {
		return 0, nil
	}
	byteLen := (int(bitCount) + 7) / 8
	var value uint64
	for i := 0; i < byteLen; i++ {
		b, err := reader.readU8()
		if err != nil {
			return 0, err
		}
		value |= uint64(b) << (i * 8)
	}
	if bitCount < 64 {
		mask := (uint64(1) << bitCount) - 1
		if value&^mask != 0 {
			return 0, invalidData("fixed bit width trailing bits")
		}
	}
	return value, nil
}

func schemaPresentFieldIndices(schema *Schema, presence []bool, hasPresence bool) ([]int, error) {
	out := make([]int, 0, len(schema.Fields))
	optionalCount := 0
	for i := range schema.Fields {
		if schema.Fields[i].Required {
			out = append(out, i)
			continue
		}
		present := true
		if hasPresence {
			if optionalCount >= len(presence) {
				return nil, invalidData("schema optional presence length")
			}
			present = presence[optionalCount]
		}
		optionalCount++
		if present {
			out = append(out, i)
		}
	}
	if hasPresence && optionalCount != len(presence) {
		return nil, invalidData("schema optional presence length")
	}
	return out, nil
}

func normalizedLogicalType(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}

func rowsFromValues(values []Value) [][]Value {
	rows := make([][]Value, len(values))
	for i := range values {
		if values[i].Kind == ValueArray {
			row := make([]Value, len(values[i].Arr))
			for j := range values[i].Arr {
				row[j] = values[i].Arr[j].Clone()
			}
			rows[i] = row
		} else {
			rows[i] = []Value{values[i].Clone()}
		}
	}
	return rows
}

func columnNullStrategy(values []Value, presentBits []bool) (NullStrategy, []bool, bool) {
	nullCount := 0
	for i := range values {
		if values[i].Kind == ValueNull {
			nullCount++
		}
	}
	optionalCount := len(values)
	if nullCount == 0 {
		return NullStrategyAllPresentElided, nil, false
	}
	if nullCount <= optionalCount/4 {
		inverted := make([]bool, len(presentBits))
		for i := range presentBits {
			inverted[i] = !presentBits[i]
		}
		return NullStrategyInvertedPresenceBitmap, inverted, true
	}
	return NullStrategyPresenceBitmap, append([]bool(nil), presentBits...), true
}

func stripNulls(values []Value) []Value {
	out := make([]Value, 0, len(values))
	for i := range values {
		if values[i].Kind != ValueNull {
			out = append(out, values[i])
		}
	}
	return out
}

func columnsFromMapValues(values []Value) []Column {
	if len(values) == 0 {
		return nil
	}
	for i := range values {
		if values[i].Kind != ValueMap {
			return nil
		}
	}
	keyOrder := make([]string, 0)
	keyIndex := make(map[string]int)
	columnValues := make([][]Value, 0)
	columnPresence := make([][]bool, 0)
	for rowIdx := range values {
		present := make([]bool, len(keyOrder))
		for i := range values[rowIdx].Map {
			key := values[rowIdx].Map[i].Key
			entryValue := values[rowIdx].Map[i].Value.Clone()
			colIdx, ok := keyIndex[key]
			if !ok {
				colIdx = len(keyOrder)
				keyOrder = append(keyOrder, key)
				keyIndex[key] = colIdx
				columnValues = append(columnValues, make([]Value, rowIdx))
				columnPresence = append(columnPresence, make([]bool, rowIdx))
				present = append(present, false)
			}
			columnValues[colIdx] = append(columnValues[colIdx], entryValue)
			columnPresence[colIdx] = append(columnPresence[colIdx], true)
			present[colIdx] = true
		}
		for colIdx := range keyOrder {
			if present[colIdx] {
				continue
			}
			columnValues[colIdx] = append(columnValues[colIdx], NewNull())
			columnPresence[colIdx] = append(columnPresence[colIdx], false)
		}
	}
	columns := make([]Column, len(keyOrder))
	for fieldID := range keyOrder {
		colValues := columnValues[fieldID]
		presentBits := columnPresence[fieldID]
		nullStrategy, presence, hasPresence := columnNullStrategy(colValues, presentBits)
		codec, tvd := inferColumnCodecAndValues(stripNulls(colValues))
		columns[fieldID] = Column{
			FieldID:      uint64(fieldID),
			NullStrategy: nullStrategy,
			Presence:     presence,
			HasPresence:  hasPresence,
			Codec:        codec,
			Values:       tvd,
		}
	}
	return columns
}

func hasUniformMicroBatchShape(values []Value) bool {
	if len(values) == 0 {
		return false
	}
	if values[0].Kind != ValueMap {
		return false
	}
	keys := make([]string, len(values[0].Map))
	for i := range values[0].Map {
		keys[i] = values[0].Map[i].Key
	}
	for i := 1; i < len(values); i++ {
		if values[i].Kind != ValueMap || len(values[i].Map) != len(keys) {
			return false
		}
		for j := range keys {
			if values[i].Map[j].Key != keys[j] {
				return false
			}
		}
	}
	return true
}

func shouldRegisterShape(keys []string, observedCount uint64) bool {
	return len(keys) > 0 && observedCount >= 2
}

func supportsStatePatch(base *Message, current *Message) bool {
	return base != nil && current != nil && base.Kind == current.Kind &&
		(base.Kind == MessageKindMap || base.Kind == MessageKindSchemaObject || base.Kind == MessageKindShapedObject || base.Kind == MessageKindArray)
}

func encodedSize(message *Message) int {
	// lightweight estimate used for strategy choice
	return estimateMessageSize(message)
}

func typedVectorToValue(vector TypedVector) Value {
	switch vector.ElementType {
	case ElementTypeBool:
		out := make([]Value, len(vector.Data.Bools))
		for i := range out {
			out[i] = NewBool(vector.Data.Bools[i])
		}
		return NewArray(out)
	case ElementTypeI64:
		out := make([]Value, len(vector.Data.I64s))
		for i := range out {
			out[i] = NewI64(vector.Data.I64s[i])
		}
		return NewArray(out)
	case ElementTypeU64:
		out := make([]Value, len(vector.Data.U64s))
		for i := range out {
			out[i] = NewU64(vector.Data.U64s[i])
		}
		return NewArray(out)
	case ElementTypeF64:
		out := make([]Value, len(vector.Data.F64s))
		for i := range out {
			out[i] = NewF64(vector.Data.F64s[i])
		}
		return NewArray(out)
	case ElementTypeString:
		out := make([]Value, len(vector.Data.Strings))
		for i := range out {
			out[i] = NewString(vector.Data.Strings[i])
		}
		return NewArray(out)
	default:
		return NewArray(nil)
	}
}

func entriesToMap(entries []MessageMapEntry, state *SessionState) ([]MapEntry, error) {
	out := make([]MapEntry, len(entries))
	for i := range entries {
		key := keyRefString(&entries[i].Key, state)
		out[i] = MapEntry{Key: key, Value: entries[i].Value.Clone()}
		if _, ok := state.KeyTable.GetID(key); !ok {
			state.KeyTable.Register(key)
		}
	}
	return out, nil
}

func keyRefString(key *KeyRef, state *SessionState) string {
	if key.IsID {
		if s, ok := state.KeyTable.GetValue(key.ID); ok {
			return s
		}
		return ""
	}
	return key.Literal
}

func keyRefFieldIdentity(key *KeyRef, state *SessionState) *string {
	s := keyRefString(key, state)
	if s == "" {
		return nil
	}
	return &s
}

func shapeValuesToMap(keys []string, presence []bool, hasPresence bool, values []Value) []MapEntry {
	out := make([]MapEntry, 0, len(keys))
	idx := 0
	for i := range keys {
		if hasPresence && i < len(presence) && !presence[i] {
			continue
		}
		if idx >= len(values) {
			break
		}
		out = append(out, Entry(keys[i], values[idx].Clone()))
		idx++
	}
	return out
}

func rowsToColumns(rows [][]Value) []Column {
	if len(rows) == 0 {
		return nil
	}
	width := 0
	for i := range rows {
		if len(rows[i]) > width {
			width = len(rows[i])
		}
	}
	columnValues := make([][]Value, width)
	columnPresence := make([][]bool, width)
	for col := 0; col < width; col++ {
		columnValues[col] = make([]Value, 0, len(rows))
		columnPresence[col] = make([]bool, 0, len(rows))
	}
	for row := range rows {
		for col := 0; col < width; col++ {
			var value Value
			if col < len(rows[row]) {
				value = rows[row][col].Clone()
			} else {
				value = NewNull()
			}
			columnValues[col] = append(columnValues[col], value)
			columnPresence[col] = append(columnPresence[col], value.Kind != ValueNull)
		}
	}
	cols := make([]Column, width)
	for col := 0; col < width; col++ {
		nullStrategy, presence, hasPresence := columnNullStrategy(columnValues[col], columnPresence[col])
		codec, tvd := inferColumnCodecAndValues(stripNulls(columnValues[col]))
		cols[col] = Column{
			FieldID:      uint64(col),
			NullStrategy: nullStrategy,
			Presence:     presence,
			HasPresence:  hasPresence,
			Codec:        codec,
			Values:       tvd,
		}
	}
	return cols
}

func inferColumnCodecAndValues(values []Value) (VectorCodec, TypedVectorData) {
	if len(values) == 0 {
		return VectorCodecPlain, TypedVectorData{Kind: ElementTypeValue, Values: nil}
	}
	allI64 := true
	allU64 := true
	allF64 := true
	allBool := true
	allString := true
	for i := range values {
		switch values[i].Kind {
		case ValueI64:
			allU64, allF64, allBool, allString = false, false, false, false
		case ValueU64:
			allI64, allF64, allBool, allString = false, false, false, false
		case ValueF64:
			allI64, allU64, allBool, allString = false, false, false, false
		case ValueBool:
			allI64, allU64, allF64, allString = false, false, false, false
		case ValueString:
			allI64, allU64, allF64, allBool = false, false, false, false
		default:
			allI64, allU64, allF64, allBool, allString = false, false, false, false, false
		}
	}
	if allI64 {
		data := make([]int64, len(values))
		for i := range values {
			data[i] = values[i].I64
		}
		return selectIntegerCodec(data), TypedVectorData{Kind: ElementTypeI64, I64s: data}
	}
	if allU64 {
		data := make([]uint64, len(values))
		for i := range values {
			data[i] = values[i].U64
		}
		return selectU64Codec(data), TypedVectorData{Kind: ElementTypeU64, U64s: data}
	}
	if allF64 {
		data := make([]float64, len(values))
		for i := range values {
			data[i] = values[i].F64
		}
		return selectFloatCodec(data), TypedVectorData{Kind: ElementTypeF64, F64s: data}
	}
	if allBool {
		data := make([]bool, len(values))
		for i := range values {
			data[i] = values[i].Bool
		}
		return VectorCodecDirectBitpack, TypedVectorData{Kind: ElementTypeBool, Bools: data}
	}
	if allString {
		data := make([]string, len(values))
		for i := range values {
			data[i] = values[i].Str
		}
		return selectStringCodec(data), TypedVectorData{Kind: ElementTypeString, Strings: data}
	}
	data := make([]Value, len(values))
	for i := range values {
		data[i] = values[i].Clone()
	}
	return VectorCodecPlain, TypedVectorData{Kind: ElementTypeValue, Values: data}
}

func typedVectorDataElementType(data TypedVectorData) ElementType {
	switch data.Kind {
	case ElementTypeBool, ElementTypeI64, ElementTypeU64, ElementTypeF64, ElementTypeString, ElementTypeBinary, ElementTypeValue:
		return data.Kind
	}
	switch {
	case data.Bools != nil:
		return ElementTypeBool
	case data.I64s != nil:
		return ElementTypeI64
	case data.U64s != nil:
		return ElementTypeU64
	case data.F64s != nil:
		return ElementTypeF64
	case data.Strings != nil:
		return ElementTypeString
	case data.Binary != nil:
		return ElementTypeBinary
	default:
		return ElementTypeValue
	}
}

func selectIntegerCodec(values []int64) VectorCodec {
	if len(values) < 4 {
		return VectorCodecPlain
	}
	deltaVals := deltas(values)
	dd := deltas(deltaVals)
	nonZeroDD := 0
	for i := 1; i < len(dd); i++ {
		if dd[i] != 0 {
			nonZeroDD++
		}
	}
	nonZeroRatio := 0.0
	if len(dd) > 1 {
		nonZeroRatio = float64(nonZeroDD) / float64(len(dd)-1)
	}
	deltaMin, deltaMax := deltaVals[0], deltaVals[0]
	for i := range deltaVals {
		if deltaVals[i] < deltaMin {
			deltaMin = deltaVals[i]
		}
		if deltaVals[i] > deltaMax {
			deltaMax = deltaVals[i]
		}
	}
	deltaRangeBits := bitWidthSigned(deltaMin, deltaMax)
	if len(values) >= 8 && (nonZeroRatio <= 0.25 || deltaRangeBits <= 2) {
		return VectorCodecDeltaDeltaBitpack
	}
	repeatedRatio, avgRun := runStats(values)
	if repeatedRatio >= 0.5 && avgRun >= 3.0 {
		return VectorCodecRle
	}
	plainBits := int32(64)
	min, max := values[0], values[0]
	for i := range values {
		if values[i] < min {
			min = values[i]
		}
		if values[i] > max {
			max = values[i]
		}
	}
	rangeBits := int32(bitWidthSigned(min, max))
	if rangeBits <= plainBits-4 {
		return VectorCodecForBitpack
	}
	monotonic := true
	for i := 1; i < len(values); i++ {
		if values[i] < values[i-1] {
			monotonic = false
			break
		}
	}
	if len(values) >= 8 && monotonic && int32(deltaRangeBits) <= rangeBits-3 {
		return VectorCodecDeltaForBitpack
	}
	maxAbsDeltaBits := int32(1)
	for i := range deltaVals {
		w := int32(bitWidthU64(uint64(abs64(deltaVals[i]))))
		if w > maxAbsDeltaBits {
			maxAbsDeltaBits = w
		}
	}
	if maxAbsDeltaBits <= plainBits-3 {
		return VectorCodecDeltaBitpack
	}
	maxBitWidth := uint8(1)
	for i := range values {
		w := bitWidthU64(uint64(abs64(values[i])))
		if w > maxBitWidth {
			maxBitWidth = w
		}
	}
	if len(values) >= 8 && maxBitWidth <= 16 && !monotonic {
		return VectorCodecSimple8b
	}
	if maxBitWidth < 64 {
		return VectorCodecDirectBitpack
	}
	return VectorCodecPlain
}

func selectU64Codec(values []uint64) VectorCodec {
	allSigned := true
	signed := make([]int64, len(values))
	for i, v := range values {
		if v > math.MaxInt64 {
			allSigned = false
			break
		}
		signed[i] = int64(v)
	}
	if allSigned {
		switch selectIntegerCodec(signed) {
		case VectorCodecRle, VectorCodecForBitpack, VectorCodecSimple8b, VectorCodecDirectBitpack, VectorCodecPlain:
			return selectIntegerCodec(signed)
		default:
			return VectorCodecDirectBitpack
		}
	}
	if len(values) < 4 {
		return VectorCodecDirectBitpack
	}
	repeatedRatio, avgRun := runStatsU64(values)
	if repeatedRatio >= 0.5 && avgRun >= 3.0 {
		return VectorCodecRle
	}
	min, max := values[0], values[0]
	for i := range values {
		if values[i] < min {
			min = values[i]
		}
		if values[i] > max {
			max = values[i]
		}
	}
	rangeBits := int32(bitWidthU64(max - min))
	if rangeBits <= 60 {
		return VectorCodecForBitpack
	}
	maxWidth := uint8(1)
	for i := range values {
		w := bitWidthU64(values[i])
		if w > maxWidth {
			maxWidth = w
		}
	}
	if len(values) >= 8 && maxWidth <= 16 {
		return VectorCodecSimple8b
	}
	if maxWidth < 64 {
		return VectorCodecDirectBitpack
	}
	return VectorCodecPlain
}

func deltas(values []int64) []int64 {
	out := make([]int64, len(values))
	for i, value := range values {
		if i == 0 {
			out[i] = value
		} else {
			out[i] = value - values[i-1]
		}
	}
	return out
}

func runStats(values []int64) (float64, float64) {
	if len(values) == 0 {
		return 0, 0
	}
	runLen := 1
	runs := []int{}
	for i := 1; i < len(values); i++ {
		if values[i] == values[i-1] {
			runLen++
		} else {
			runs = append(runs, runLen)
			runLen = 1
		}
	}
	runs = append(runs, runLen)
	repeatedItems := 0
	for _, r := range runs {
		if r > 1 {
			repeatedItems += r
		}
	}
	repeatedRatio := float64(repeatedItems) / float64(len(values))
	avgRun := 0.0
	for _, r := range runs {
		avgRun += float64(r)
	}
	avgRun /= float64(len(runs))
	return repeatedRatio, avgRun
}

func runStatsU64(values []uint64) (float64, float64) {
	if len(values) == 0 {
		return 0, 0
	}
	runLen := 1
	runs := []int{}
	for i := 1; i < len(values); i++ {
		if values[i] == values[i-1] {
			runLen++
		} else {
			runs = append(runs, runLen)
			runLen = 1
		}
	}
	runs = append(runs, runLen)
	repeatedItems := 0
	for _, r := range runs {
		if r > 1 {
			repeatedItems += r
		}
	}
	repeatedRatio := float64(repeatedItems) / float64(len(values))
	avgRun := 0.0
	for _, r := range runs {
		avgRun += float64(r)
	}
	avgRun /= float64(len(runs))
	return repeatedRatio, avgRun
}

func bitWidthSigned(min, max int64) uint8 {
	rangeVal := uint64(max - min)
	if min > max {
		rangeVal = uint64(min - max)
	}
	return bitWidthU64(rangeVal)
}

func bitWidthU64(v uint64) uint8 {
	if v == 0 {
		return 1
	}
	return uint8(bits.Len64(v))
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

func selectFloatCodec(values []float64) VectorCodec {
	if len(values) < 4 {
		return VectorCodecPlain
	}
	prev := math.Float64bits(values[0])
	changes := 0
	for i := 1; i < len(values); i++ {
		cur := math.Float64bits(values[i])
		if cur != prev {
			changes++
		}
		prev = cur
	}
	if changes*2 <= len(values) {
		return VectorCodecXorFloat
	}
	return VectorCodecPlain
}

func selectStringCodec(values []string) VectorCodec {
	if len(values) == 0 {
		return VectorCodecPlain
	}
	uniq := map[string]struct{}{}
	for i := range values {
		uniq[values[i]] = struct{}{}
	}
	if len(uniq)*2 <= len(values) {
		return VectorCodecDictionary
	}
	prefixGain := 0
	prev := ""
	for i := range values {
		prefixGain += commonPrefixLen([]byte(prev), []byte(values[i]))
		prev = values[i]
	}
	if prefixGain > len(values)*2 {
		return VectorCodecPrefixDelta
	}
	return VectorCodecPlain
}

func writeSmallestU64(value uint64, out *[]byte) {
	switch {
	case value <= 0xFF:
		*out = append(*out, 1, byte(value))
	case value <= 0xFFFF:
		*out = append(*out, 2, byte(value), byte(value>>8))
	case value <= 0xFFFFFFFF:
		*out = append(*out, 4, byte(value), byte(value>>8), byte(value>>16), byte(value>>24))
	default:
		*out = append(*out, 8)
		appendU64LE(out, value)
	}
}

func readSmallestU64(reader *Reader) (uint64, error) {
	size, err := reader.readU8()
	if err != nil {
		return 0, err
	}
	switch size {
	case 1:
		b, err := reader.readU8()
		return uint64(b), err
	case 2:
		b, err := reader.readExact(2)
		if err != nil {
			return 0, err
		}
		v := uint64(b[0]) | uint64(b[1])<<8
		if v <= 0xFF {
			return 0, invalidData("non-canonical integer encoding")
		}
		return v, nil
	case 4:
		b, err := reader.readExact(4)
		if err != nil {
			return 0, err
		}
		v := uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24
		if v <= 0xFFFF {
			return 0, invalidData("non-canonical integer encoding")
		}
		return v, nil
	case 8:
		v, err := readU64LE(reader)
		if err != nil {
			return 0, err
		}
		if v <= 0xFFFFFFFF {
			return 0, invalidData("non-canonical integer encoding")
		}
		return v, nil
	default:
		return 0, invalidData("smallest u64 size")
	}
}

func rleEncodeBytes(input []byte) []byte {
	if len(input) == 0 {
		return nil
	}
	out := make([]byte, 0, len(input))
	for i := 0; i < len(input); {
		j := i + 1
		for j < len(input) && input[j] == input[i] && j-i < 255 {
			j++
		}
		out = append(out, byte(j-i), input[i])
		i = j
	}
	return out
}

func rleDecodeBytes(input []byte) ([]byte, error) {
	out := make([]byte, 0)
	for i := 0; i < len(input); {
		if i+1 >= len(input) {
			return nil, invalidData("rle payload")
		}
		run := int(input[i])
		b := input[i+1]
		for j := 0; j < run; j++ {
			out = append(out, b)
		}
		i += 2
	}
	return out, nil
}

func controlBitpackEncodeBytes(input []byte) []byte {
	return append([]byte(nil), input...)
}

func controlBitpackDecodeBytes(input []byte) ([]byte, error) {
	return append([]byte(nil), input...), nil
}

func controlHuffmanEncodeBytes(input []byte) []byte {
	return append([]byte(nil), input...)
}

func controlHuffmanDecodeBytes(input []byte) ([]byte, error) {
	return append([]byte(nil), input...), nil
}

func controlFseEncodeBytes(input []byte) []byte {
	return append([]byte(nil), input...)
}

func controlFseDecodeBytes(input []byte) ([]byte, error) {
	return append([]byte(nil), input...), nil
}

func commonPrefixLen(a []byte, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	i := 0
	for i < n && a[i] == b[i] {
		i++
	}
	return i
}

func templateDescriptorFromColumns(templateID uint64, columns []Column) TemplateDescriptor {
	d := TemplateDescriptor{TemplateID: templateID}
	for i := range columns {
		d.FieldIDs = append(d.FieldIDs, columns[i].FieldID)
		d.NullStrategies = append(d.NullStrategies, columns[i].NullStrategy)
		d.Codecs = append(d.Codecs, columns[i].Codec)
	}
	return d
}

func findTemplateID(templates map[uint64]TemplateDescriptor, columns []Column) (uint64, bool) {
	ids := make([]int, 0, len(templates))
	for id := range templates {
		ids = append(ids, int(id))
	}
	sort.Ints(ids)
	for _, raw := range ids {
		id := uint64(raw)
		t := templates[id]
		if len(t.FieldIDs) != len(columns) {
			continue
		}
		ok := true
		for i := range columns {
			if t.FieldIDs[i] != columns[i].FieldID || t.NullStrategies[i] != columns[i].NullStrategy {
				ok = false
				break
			}
		}
		if ok {
			return id, true
		}
	}
	return 0, false
}

func diffTemplateColumns(previous []Column, current []Column) ([]bool, []Column) {
	mask := make([]bool, len(current))
	changed := make([]Column, 0, len(current))
	for i := range current {
		if i >= len(previous) || estimateColumnSize(previous[i]) != estimateColumnSize(current[i]) {
			mask[i] = true
			changed = append(changed, current[i])
		}
	}
	return mask, changed
}

func mergeTemplateColumns(previous []Column, changedMask []bool, changed []Column) ([]Column, error) {
	out := make([]Column, len(changedMask))
	idx := 0
	for i := range changedMask {
		if changedMask[i] {
			if idx >= len(changed) {
				return nil, invalidData("template changed column count mismatch")
			}
			out[i] = changed[idx]
			idx++
		} else {
			if i >= len(previous) {
				return nil, invalidData("template reference out of range")
			}
			out[i] = previous[i]
		}
	}
	return out, nil
}

func diffMessage(prev *Message, current *Message) ([]PatchOperation, int) {
	a := messageFields(prev)
	b := messageFields(current)
	n := len(a)
	if len(b) > n {
		n = len(b)
	}
	ops := make([]PatchOperation, 0, n)
	for i := 0; i < n; i++ {
		if i < len(a) && i < len(b) {
			if Equal(a[i], b[i]) {
				ops = append(ops, PatchOperation{FieldID: uint64(i), Opcode: PatchOpcodeKeep})
			} else {
				v := b[i].Clone()
				ops = append(ops, PatchOperation{FieldID: uint64(i), Opcode: PatchOpcodeReplaceScalar, Value: &v})
			}
		} else if i < len(b) {
			v := b[i].Clone()
			ops = append(ops, PatchOperation{FieldID: uint64(i), Opcode: PatchOpcodeInsertField, Value: &v})
		} else {
			ops = append(ops, PatchOperation{FieldID: uint64(i), Opcode: PatchOpcodeDeleteField})
		}
	}
	return ops, 0
}

func messageFields(message *Message) []Value {
	switch message.Kind {
	case MessageKindArray:
		out := make([]Value, len(message.Array))
		for i := range message.Array {
			out[i] = message.Array[i].Clone()
		}
		return out
	case MessageKindMap:
		out := make([]Value, len(message.Map))
		for i := range message.Map {
			out[i] = message.Map[i].Value.Clone()
		}
		return out
	case MessageKindShapedObject:
		out := make([]Value, len(message.ShapedObject.Values))
		for i := range message.ShapedObject.Values {
			out[i] = message.ShapedObject.Values[i].Clone()
		}
		return out
	case MessageKindSchemaObject:
		out := make([]Value, len(message.SchemaObject.Fields))
		for i := range message.SchemaObject.Fields {
			out[i] = message.SchemaObject.Fields[i].Clone()
		}
		return out
	default:
		return nil
	}
}

func rebuildMessageLike(base *Message, fields []Value) (Message, error) {
	switch base.Kind {
	case MessageKindArray:
		return Message{Kind: MessageKindArray, Array: fields}, nil
	case MessageKindMap:
		entries := make([]MessageMapEntry, len(fields))
		for i := range fields {
			if i >= len(base.Map) {
				return Message{}, invalidData("patch map shape mismatch")
			}
			entries[i] = MessageMapEntry{Key: base.Map[i].Key, Value: fields[i]}
		}
		return Message{Kind: MessageKindMap, Map: entries}, nil
	case MessageKindShapedObject:
		return Message{Kind: MessageKindShapedObject, ShapedObject: &ShapedObjectMessage{
			ShapeID:     base.ShapedObject.ShapeID,
			Presence:    append([]bool(nil), base.ShapedObject.Presence...),
			HasPresence: base.ShapedObject.HasPresence,
			Values:      fields,
		}}, nil
	case MessageKindSchemaObject:
		return Message{Kind: MessageKindSchemaObject, SchemaObject: &SchemaObjectMessage{
			SchemaID:    base.SchemaObject.SchemaID,
			Presence:    append([]bool(nil), base.SchemaObject.Presence...),
			HasPresence: base.SchemaObject.HasPresence,
			Fields:      fields,
		}}, nil
	default:
		return Message{}, invalidData("state patch reconstruction unsupported for this message kind")
	}
}

func estimateMessageSize(message *Message) int {
	switch message.Kind {
	case MessageKindScalar:
		return 1 + estimateValueSize(message.Scalar)
	case MessageKindArray:
		sum := 1 + varuintSize(uint64(len(message.Array)))
		for i := range message.Array {
			sum += estimateValueSize(&message.Array[i])
		}
		return sum
	case MessageKindMap:
		sum := 1 + varuintSize(uint64(len(message.Map)))
		for i := range message.Map {
			sum += encodedKeyRefSize(&message.Map[i].Key) + estimateValueSize(&message.Map[i].Value)
		}
		return sum
	case MessageKindStatePatch:
		sum := 1 + 2 + varuintSize(uint64(len(message.StatePatch.Operations)))
		for i := range message.StatePatch.Operations {
			sum += varuintSize(message.StatePatch.Operations[i].FieldID) + 2
			if message.StatePatch.Operations[i].Value != nil {
				sum += estimateValueSize(message.StatePatch.Operations[i].Value)
			}
		}
		return sum
	default:
		return 16
	}
}

func estimateColumnSize(column Column) int {
	size := varuintSize(column.FieldID) + 4
	switch column.Values.Kind {
	case ElementTypeBool:
		size += len(column.Values.Bools)/8 + 2
	case ElementTypeI64:
		size += len(column.Values.I64s) * 4
	case ElementTypeU64:
		size += len(column.Values.U64s) * 4
	case ElementTypeF64:
		size += len(column.Values.F64s) * 8
	case ElementTypeString:
		for i := range column.Values.Strings {
			size += encodedStringSize(column.Values.Strings[i])
		}
	}
	return size
}

func estimateValueSize(value *Value) int {
	switch value.Kind {
	case ValueNull, ValueBool:
		return 1
	case ValueI64:
		return 2 + smallestU64Size(encodeZigzag(value.I64))
	case ValueU64:
		return 2 + smallestU64Size(value.U64)
	case ValueF64:
		return 9
	case ValueString:
		return 2 + encodedStringSize(value.Str)
	case ValueBinary:
		return 1 + encodedBytesSize(len(value.Bin))
	case ValueArray:
		sum := 1 + varuintSize(uint64(len(value.Arr)))
		for i := range value.Arr {
			sum += estimateValueSize(&value.Arr[i])
		}
		return sum
	case ValueMap:
		sum := 1 + varuintSize(uint64(len(value.Map)))
		for i := range value.Map {
			sum += encodedStringSize(value.Map[i].Key) + estimateValueSize(&value.Map[i].Value)
		}
		return sum
	default:
		return 1
	}
}

func encodedBytesSize(length int) int {
	return varuintSize(uint64(length)) + length
}

func encodedStringSize(value string) int {
	return encodedBytesSize(len(value))
}

func encodedKeyRefSize(key *KeyRef) int {
	if key.IsID {
		return 1 + varuintSize(key.ID)
	}
	return encodedStringSize(key.Literal)
}

func varuintSize(value uint64) int {
	sz := 1
	for value >= 0x80 {
		value >>= 7
		sz++
	}
	return sz
}

func smallestU64Size(value uint64) int {
	switch {
	case value <= 0xFF:
		return 1
	case value <= 0xFFFF:
		return 2
	case value <= 0xFFFFFFFF:
		return 4
	default:
		return 8
	}
}

func dictionaryPayloadHash(payload []byte) uint64 {
	h := fnv.New64a()
	_, _ = h.Write(payload)
	return h.Sum64()
}

func strPtr(s string) *string { return &s }
