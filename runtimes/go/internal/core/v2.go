package core

const (
	nullTag     = 0xC0
	falseTag    = 0xC1
	trueTag     = 0xC2
	f64Tag      = 0xC3
	u8Tag       = 0xC4
	u16Tag      = 0xC5
	u32Tag      = 0xC6
	u64Tag      = 0xC7
	i8Tag       = 0xC8
	i16Tag      = 0xC9
	i32Tag      = 0xCA
	i64Tag      = 0xCB
	bin8Tag     = 0xCC
	bin16Tag    = 0xCD
	bin32Tag    = 0xCE
	str8Tag     = 0xCF
	str16Tag    = 0xD0
	str32Tag    = 0xD1
	array16Tag  = 0xD2
	array32Tag  = 0xD3
	map16Tag    = 0xD4
	map32Tag    = 0xD5
	shapeDefTag = 0xD6
	keyRefTag   = 0xD8
	strRefTag   = 0xD9
)

type v2EncodeState struct {
	keyIDs      map[string]uint64
	strIDs      map[string]uint64
	shapeIDs    map[string]uint64
	nextKeyID   uint64
	nextStrID   uint64
	nextShapeID uint64
}

type v2DecodeState struct {
	keys    []string
	strings []string
	shapes  [][]string
}

func encodeV2(value Value) ([]byte, error) {
	out := make([]byte, 0, 256)
	state := &v2EncodeState{
		keyIDs:   make(map[string]uint64),
		strIDs:   make(map[string]uint64),
		shapeIDs: make(map[string]uint64),
	}
	if err := encodeV2Value(value, &out, state); err != nil {
		return nil, err
	}
	return out, nil
}

func decodeV2(bytes []byte) (Value, error) {
	reader := newReader(bytes)
	state := &v2DecodeState{}
	value, err := decodeV2Value(reader, state)
	if err != nil {
		return Value{}, err
	}
	if !reader.isEOF() {
		return Value{}, invalidData("trailing bytes in v2 decode")
	}
	return value, nil
}

func encodeV2Value(value Value, out *[]byte, state *v2EncodeState) error {
	switch value.Kind {
	case ValueNull:
		*out = append(*out, nullTag)
	case ValueBool:
		if value.Bool {
			*out = append(*out, trueTag)
		} else {
			*out = append(*out, falseTag)
		}
	case ValueI64:
		encodeV2I64(value.I64, out)
	case ValueU64:
		encodeV2U64(value.U64, out)
	case ValueF64:
		*out = append(*out, f64Tag)
		appendF64LE(out, value.F64)
	case ValueString:
		if id, ok := state.strIDs[value.Str]; ok {
			*out = append(*out, strRefTag)
			encodeVaruint(id, out)
		} else {
			encodeV2StringLiteral(value.Str, out)
			state.strIDs[value.Str] = state.nextStrID
			state.nextStrID++
		}
	case ValueBinary:
		encodeV2Binary(value.Bin, out)
	case ValueArray:
		return encodeV2Array(value.Arr, out, state)
	case ValueMap:
		return encodeV2Map(value.Map, out, state)
	default:
		return invalidData("unsupported value kind")
	}
	return nil
}

func encodeV2Array(values []Value, out *[]byte, state *v2EncodeState) error {
	if shapeKeys := detectShapeKeys(values); shapeKeys != nil {
		sk := shapeKey(shapeKeys)
		shapeID, ok := state.shapeIDs[sk]
		if !ok {
			shapeID = state.nextShapeID
			state.nextShapeID++
			state.shapeIDs[sk] = shapeID
		}
		writeV2ArrayHeader(len(values), out)
		*out = append(*out, shapeDefTag)
		encodeVaruint(shapeID, out)
		encodeVaruint(uint64(len(shapeKeys)), out)
		for _, key := range shapeKeys {
			encodeV2Key(key, out, state)
		}
		for _, value := range values {
			if value.Kind != ValueMap {
				return invalidData("shape array row must be map")
			}
			for _, field := range value.Map {
				if err := encodeV2Value(field.Value, out, state); err != nil {
					return err
				}
			}
		}
		return nil
	}
	writeV2ArrayHeader(len(values), out)
	for _, value := range values {
		if err := encodeV2Value(value, out, state); err != nil {
			return err
		}
	}
	return nil
}

func encodeV2Map(entries []MapEntry, out *[]byte, state *v2EncodeState) error {
	writeV2MapHeader(len(entries), out)
	for _, entry := range entries {
		encodeV2Key(entry.Key, out, state)
		if err := encodeV2Value(entry.Value, out, state); err != nil {
			return err
		}
	}
	return nil
}

func encodeV2Key(key string, out *[]byte, state *v2EncodeState) {
	if id, ok := state.keyIDs[key]; ok {
		*out = append(*out, keyRefTag)
		encodeVaruint(id, out)
		return
	}
	encodeV2StringLiteral(key, out)
	state.keyIDs[key] = state.nextKeyID
	state.nextKeyID++
}

func encodeV2StringLiteral(value string, out *[]byte) {
	bytes := []byte(value)
	if len(bytes) <= 31 {
		*out = append(*out, 0x80|byte(len(bytes)))
	} else if len(bytes) <= 0xFF {
		*out = append(*out, str8Tag, byte(len(bytes)))
	} else if len(bytes) <= 0xFFFF {
		*out = append(*out, str16Tag)
		*out = append(*out, byte(len(bytes)), byte(len(bytes)>>8))
	} else {
		*out = append(*out, str32Tag)
		*out = append(*out, byte(len(bytes)), byte(len(bytes)>>8), byte(len(bytes)>>16), byte(len(bytes)>>24))
	}
	*out = append(*out, bytes...)
}

func encodeV2Binary(value []byte, out *[]byte) {
	if len(value) <= 0xFF {
		*out = append(*out, bin8Tag, byte(len(value)))
	} else if len(value) <= 0xFFFF {
		*out = append(*out, bin16Tag, byte(len(value)), byte(len(value)>>8))
	} else {
		*out = append(*out, bin32Tag)
		*out = append(*out, byte(len(value)), byte(len(value)>>8), byte(len(value)>>16), byte(len(value)>>24))
	}
	*out = append(*out, value...)
}

func encodeV2U64(value uint64, out *[]byte) {
	if value <= 127 {
		*out = append(*out, byte(value))
	} else if value <= 0xFF {
		*out = append(*out, u8Tag, byte(value))
	} else if value <= 0xFFFF {
		*out = append(*out, u16Tag, byte(value), byte(value>>8))
	} else if value <= 0xFFFFFFFF {
		*out = append(*out, u32Tag, byte(value), byte(value>>8), byte(value>>16), byte(value>>24))
	} else {
		*out = append(*out, u64Tag)
		appendU64LE(out, value)
	}
}

func encodeV2I64(value int64, out *[]byte) {
	if value >= -32 && value <= -1 {
		*out = append(*out, byte(int8(value)))
	} else if value >= 0 && value <= 127 {
		*out = append(*out, byte(value))
	} else if value >= -128 && value <= 127 {
		*out = append(*out, i8Tag, byte(int8(value)))
	} else if value >= -32768 && value <= 32767 {
		*out = append(*out, i16Tag, byte(value), byte(uint16(value)>>8))
	} else if value >= -2147483648 && value <= 2147483647 {
		*out = append(*out, i32Tag, byte(value), byte(value>>8), byte(value>>16), byte(value>>24))
	} else {
		*out = append(*out, i64Tag)
		appendU64LE(out, uint64(value))
	}
}

func writeV2ArrayHeader(length int, out *[]byte) {
	if length <= 15 {
		*out = append(*out, 0xA0|byte(length))
	} else if length <= 0xFFFF {
		*out = append(*out, array16Tag, byte(length), byte(length>>8))
	} else {
		*out = append(*out, array32Tag, byte(length), byte(length>>8), byte(length>>16), byte(length>>24))
	}
}

func writeV2MapHeader(length int, out *[]byte) {
	if length <= 15 {
		*out = append(*out, 0xB0|byte(length))
	} else if length <= 0xFFFF {
		*out = append(*out, map16Tag, byte(length), byte(length>>8))
	} else {
		*out = append(*out, map32Tag, byte(length), byte(length>>8), byte(length>>16), byte(length>>24))
	}
}

func detectShapeKeys(values []Value) []string {
	if len(values) < 2 {
		return nil
	}
	if values[0].Kind != ValueMap || len(values[0].Map) == 0 {
		return nil
	}
	keys := make([]string, len(values[0].Map))
	for i, e := range values[0].Map {
		keys[i] = e.Key
	}
	for _, value := range values[1:] {
		if value.Kind != ValueMap || len(value.Map) != len(keys) {
			return nil
		}
		for i, e := range value.Map {
			if e.Key != keys[i] {
				return nil
			}
		}
	}
	return keys
}

func decodeV2Value(reader *Reader, state *v2DecodeState) (Value, error) {
	tag, err := reader.readU8()
	if err != nil {
		return Value{}, err
	}
	return decodeV2ValueFromTag(reader, state, tag)
}

func decodeV2ValueFromTag(reader *Reader, state *v2DecodeState, tag byte) (Value, error) {
	switch {
	case tag <= 0x7F:
		return NewU64(uint64(tag)), nil
	case tag >= 0x80 && tag <= 0x9F:
		length := int(tag & 0x1F)
		bytes, err := reader.readExact(length)
		if err != nil {
			return Value{}, err
		}
		s := string(bytes)
		state.strings = append(state.strings, s)
		return NewString(s), nil
	case tag >= 0xA0 && tag <= 0xAF:
		return decodeV2ArrayBody(reader, state, int(tag&0x0F))
	case tag >= 0xB0 && tag <= 0xBF:
		return decodeV2MapBody(reader, state, int(tag&0x0F))
	case tag >= 0xE0:
		return NewI64(int64(int8(tag))), nil
	case tag == nullTag:
		return NewNull(), nil
	case tag == falseTag:
		return NewBool(false), nil
	case tag == trueTag:
		return NewBool(true), nil
	case tag == f64Tag:
		f, err := readF64LE(reader)
		return NewF64(f), err
	case tag == u8Tag:
		b, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		if b <= 127 {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewU64(uint64(b)), nil
	case tag == u16Tag:
		b, err := reader.readExact(2)
		if err != nil {
			return Value{}, err
		}
		v := uint64(b[0]) | uint64(b[1])<<8
		if v <= 0xFF {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewU64(v), nil
	case tag == u32Tag:
		b, err := reader.readExact(4)
		if err != nil {
			return Value{}, err
		}
		v := uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24
		if v <= 0xFFFF {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewU64(v), nil
	case tag == u64Tag:
		u, err := readU64LE(reader)
		if err != nil {
			return Value{}, err
		}
		if u <= 0xFFFFFFFF {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewU64(u), nil
	case tag == i8Tag:
		b, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		v := int64(int8(b))
		if v >= -32 && v <= 127 {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewI64(v), nil
	case tag == i16Tag:
		b, err := reader.readExact(2)
		if err != nil {
			return Value{}, err
		}
		v := int64(int16(uint16(b[0]) | uint16(b[1])<<8))
		if v >= -128 && v <= 127 {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewI64(v), nil
	case tag == i32Tag:
		b, err := reader.readExact(4)
		if err != nil {
			return Value{}, err
		}
		v := int64(int32(uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24))
		if v >= -32768 && v <= 32767 {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewI64(v), nil
	case tag == i64Tag:
		b, err := reader.readExact(8)
		if err != nil {
			return Value{}, err
		}
		v := int64(uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24 | uint64(b[4])<<32 | uint64(b[5])<<40 | uint64(b[6])<<48 | uint64(b[7])<<56)
		if v >= -2147483648 && v <= 2147483647 {
			return Value{}, invalidData("non-canonical integer encoding")
		}
		return NewI64(v), nil
	case tag == bin8Tag:
		n, err := reader.readU8()
		if err != nil {
			return Value{}, err
		}
		b, err := reader.readExact(int(n))
		return NewBinary(b), err
	case tag == bin16Tag:
		b, err := reader.readExact(2)
		if err != nil {
			return Value{}, err
		}
		n := int(b[0]) | int(b[1])<<8
		data, err := reader.readExact(n)
		return NewBinary(data), err
	case tag == bin32Tag:
		b, err := reader.readExact(4)
		if err != nil {
			return Value{}, err
		}
		n := int(b[0]) | int(b[1])<<8 | int(b[2])<<16 | int(b[3])<<24
		data, err := reader.readExact(n)
		return NewBinary(data), err
	case tag == str8Tag, tag == str16Tag, tag == str32Tag:
		return decodeV2StringTag(reader, state, tag)
	case tag == array16Tag:
		b, err := reader.readExact(2)
		if err != nil {
			return Value{}, err
		}
		n := int(b[0]) | int(b[1])<<8
		return decodeV2ArrayBody(reader, state, n)
	case tag == array32Tag:
		b, err := reader.readExact(4)
		if err != nil {
			return Value{}, err
		}
		n := int(b[0]) | int(b[1])<<8 | int(b[2])<<16 | int(b[3])<<24
		return decodeV2ArrayBody(reader, state, n)
	case tag == map16Tag:
		b, err := reader.readExact(2)
		if err != nil {
			return Value{}, err
		}
		n := int(b[0]) | int(b[1])<<8
		return decodeV2MapBody(reader, state, n)
	case tag == map32Tag:
		b, err := reader.readExact(4)
		if err != nil {
			return Value{}, err
		}
		n := int(b[0]) | int(b[1])<<8 | int(b[2])<<16 | int(b[3])<<24
		return decodeV2MapBody(reader, state, n)
	case tag == strRefTag:
		id, err := reader.readVaruint()
		if err != nil {
			return Value{}, err
		}
		if int(id) >= len(state.strings) {
			return Value{}, invalidData("unknown str_ref id")
		}
		return NewString(state.strings[id]), nil
	default:
		return Value{}, invalidTag(tag)
	}
}

func decodeV2StringTag(reader *Reader, state *v2DecodeState, tag byte) (Value, error) {
	var length int
	var err error
	switch tag {
	case str8Tag:
		b, e := reader.readU8()
		if e != nil {
			return Value{}, e
		}
		length = int(b)
	case str16Tag:
		b, e := reader.readExact(2)
		if e != nil {
			return Value{}, e
		}
		length = int(b[0]) | int(b[1])<<8
	case str32Tag:
		b, e := reader.readExact(4)
		if e != nil {
			return Value{}, e
		}
		length = int(b[0]) | int(b[1])<<8 | int(b[2])<<16 | int(b[3])<<24
	default:
		return Value{}, invalidData("invalid string tag")
	}
	bytes, err := reader.readExact(length)
	if err != nil {
		return Value{}, err
	}
	s := string(bytes)
	state.strings = append(state.strings, s)
	return NewString(s), nil
}

func decodeV2ArrayBody(reader *Reader, state *v2DecodeState, length int) (Value, error) {
	if length < 0 {
		return Value{}, invalidData("decode count limit exceeded")
	}
	if err := reader.claimOutput(uint64(length)); err != nil {
		return Value{}, err
	}
	if err := reader.enterDepth(); err != nil {
		return Value{}, err
	}
	defer reader.leaveDepth()
	if length == 0 {
		return NewArray(nil), nil
	}
	firstTag, err := reader.readU8()
	if err != nil {
		return Value{}, err
	}
	if firstTag == shapeDefTag {
		shapeID, err := reader.readCount(65535)
		if err != nil {
			return Value{}, err
		}
		keyCount, err := reader.readCount(256)
		if err != nil {
			return Value{}, err
		}
		keys := make([]string, keyCount)
		for i := 0; i < int(keyCount); i++ {
			keys[i], err = decodeV2Key(reader, state)
			if err != nil {
				return Value{}, err
			}
		}
		for int(shapeID) >= len(state.shapes) {
			state.shapes = append(state.shapes, nil)
		}
		state.shapes[shapeID] = keys
		values := make([]Value, length)
		for i := 0; i < length; i++ {
			if err := reader.claimOutput(uint64(len(keys))); err != nil {
				return Value{}, err
			}
			row := make([]MapEntry, len(keys))
			for j, key := range keys {
				v, err := decodeV2Value(reader, state)
				if err != nil {
					return Value{}, err
				}
				row[j] = Entry(key, v)
			}
			values[i] = NewMap(row...)
		}
		return NewArray(values), nil
	}
	values := make([]Value, length)
	v, err := decodeV2ValueFromTag(reader, state, firstTag)
	if err != nil {
		return Value{}, err
	}
	values[0] = v
	for i := 1; i < length; i++ {
		values[i], err = decodeV2Value(reader, state)
		if err != nil {
			return Value{}, err
		}
	}
	return NewArray(values), nil
}

func decodeV2MapBody(reader *Reader, state *v2DecodeState, length int) (Value, error) {
	if length < 0 {
		return Value{}, invalidData("decode count limit exceeded")
	}
	if err := reader.claimOutput(uint64(length)); err != nil {
		return Value{}, err
	}
	if err := reader.enterDepth(); err != nil {
		return Value{}, err
	}
	defer reader.leaveDepth()
	entries := make([]MapEntry, length)
	for i := 0; i < length; i++ {
		key, err := decodeV2Key(reader, state)
		if err != nil {
			return Value{}, err
		}
		value, err := decodeV2Value(reader, state)
		if err != nil {
			return Value{}, err
		}
		entries[i] = Entry(key, value)
	}
	return NewMap(entries...), nil
}

func decodeV2Key(reader *Reader, state *v2DecodeState) (string, error) {
	tag, err := reader.readU8()
	if err != nil {
		return "", err
	}
	if tag == keyRefTag {
		id, err := reader.readVaruint()
		if err != nil {
			return "", err
		}
		if int(id) >= len(state.keys) {
			return "", invalidData("unknown key_ref id")
		}
		return state.keys[id], nil
	}
	if tag >= 0x80 && tag <= 0x9F {
		length := int(tag & 0x1F)
		bytes, err := reader.readExact(length)
		if err != nil {
			return "", err
		}
		key := string(bytes)
		state.keys = append(state.keys, key)
		return key, nil
	}
	if tag == str8Tag || tag == str16Tag || tag == str32Tag {
		v, err := decodeV2ValueFromTag(reader, state, tag)
		if err != nil {
			return "", err
		}
		if v.Kind != ValueString {
			return "", invalidData("expected string key")
		}
		state.keys = append(state.keys, v.Str)
		return v.Str, nil
	}
	return "", invalidData("map key must be key_ref or string")
}
