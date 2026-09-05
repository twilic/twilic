package core

import (
	"math"
	"math/bits"
)

func encodeI64Vector(values []int64, codec VectorCodec, out *[]byte) {
	switch codec {
	case VectorCodecRle:
		encodeI64Rle(values, out)
	case VectorCodecDirectBitpack:
		encodeI64DirectBitpack(values, out)
	case VectorCodecDeltaBitpack:
		deltas := delta(values)
		encodeI64DirectBitpack(deltas, out)
	case VectorCodecForBitpack:
		if len(values) == 0 {
			encodeVaruint(0, out)
			return
		}
		minValue := values[0]
		for _, v := range values[1:] {
			if v < minValue {
				minValue = v
			}
		}
		encodeVaruint(encodeZigzag(minValue), out)
		shifted := make([]int64, len(values))
		for i, v := range values {
			shifted[i] = v - minValue
		}
		encodeI64DirectBitpack(shifted, out)
	case VectorCodecDeltaForBitpack:
		deltas := delta(values)
		if len(deltas) == 0 {
			encodeVaruint(0, out)
			return
		}
		minValue := deltas[0]
		for _, v := range deltas[1:] {
			if v < minValue {
				minValue = v
			}
		}
		encodeVaruint(encodeZigzag(minValue), out)
		shifted := make([]int64, len(deltas))
		for i, v := range deltas {
			shifted[i] = v - minValue
		}
		encodeI64DirectBitpack(shifted, out)
	case VectorCodecDeltaDeltaBitpack:
		encodeI64DeltaDelta(values, out)
	case VectorCodecPatchedFor:
		encodeI64PatchedFor(values, out)
	case VectorCodecSimple8b:
		encodeI64Simple8b(values, out)
	case VectorCodecPlain, VectorCodecDictionary, VectorCodecStringRef, VectorCodecPrefixDelta, VectorCodecXorFloat:
		encodeI64Plain(values, out)
	}
}

func decodeI64Vector(reader *Reader, codec VectorCodec) ([]int64, error) {
	switch codec {
	case VectorCodecRle:
		return decodeI64Rle(reader)
	case VectorCodecDirectBitpack:
		return decodeI64DirectBitpack(reader)
	case VectorCodecDeltaBitpack:
		values, err := decodeI64DirectBitpack(reader)
		if err != nil {
			return nil, err
		}
		return undelta(values)
	case VectorCodecForBitpack:
		encodedMin, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		minValue := decodeZigzag(encodedMin)
		if reader.isEOF() {
			return []int64{}, nil
		}
		shifted, err := decodeI64DirectBitpack(reader)
		if err != nil {
			return nil, err
		}
		out := make([]int64, len(shifted))
		for i, v := range shifted {
			out[i] = v + minValue
		}
		return out, nil
	case VectorCodecDeltaForBitpack:
		encodedMin, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		minValue := decodeZigzag(encodedMin)
		if reader.isEOF() {
			return []int64{}, nil
		}
		shifted, err := decodeI64DirectBitpack(reader)
		if err != nil {
			return nil, err
		}
		deltas := make([]int64, len(shifted))
		for i, v := range shifted {
			deltas[i] = v + minValue
		}
		return undelta(deltas)
	case VectorCodecDeltaDeltaBitpack:
		return decodeI64DeltaDelta(reader)
	case VectorCodecPatchedFor:
		return decodeI64PatchedFor(reader)
	case VectorCodecSimple8b:
		return decodeI64Simple8b(reader)
	case VectorCodecPlain, VectorCodecDictionary, VectorCodecStringRef, VectorCodecPrefixDelta, VectorCodecXorFloat:
		return decodeI64Plain(reader)
	default:
		return nil, invalidData("unsupported vector codec")
	}
}

func encodeU64Vector(values []uint64, codec VectorCodec, out *[]byte) {
	switch codec {
	case VectorCodecRle:
		encodeU64Rle(values, out)
	case VectorCodecDirectBitpack:
		encodeU64DirectBitpack(values, out)
	case VectorCodecForBitpack:
		if len(values) == 0 {
			encodeVaruint(0, out)
			return
		}
		minValue := values[0]
		for _, v := range values[1:] {
			if v < minValue {
				minValue = v
			}
		}
		encodeVaruint(minValue, out)
		shifted := make([]uint64, len(values))
		for i, v := range values {
			shifted[i] = v - minValue
		}
		encodeU64DirectBitpack(shifted, out)
	case VectorCodecPlain:
		encodeU64Plain(values, out)
	case VectorCodecSimple8b:
		encodeU64Simple8b(values, out)
	case VectorCodecDictionary, VectorCodecStringRef, VectorCodecPrefixDelta, VectorCodecXorFloat,
		VectorCodecDeltaBitpack, VectorCodecDeltaForBitpack, VectorCodecDeltaDeltaBitpack, VectorCodecPatchedFor:
		encodeU64Plain(values, out)
	}
}

func decodeU64Vector(reader *Reader, codec VectorCodec) ([]uint64, error) {
	switch codec {
	case VectorCodecRle:
		return decodeU64Rle(reader)
	case VectorCodecDirectBitpack:
		return decodeU64DirectBitpack(reader)
	case VectorCodecForBitpack:
		minValue, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		if reader.isEOF() {
			return []uint64{}, nil
		}
		shifted, err := decodeU64DirectBitpack(reader)
		if err != nil {
			return nil, err
		}
		out := make([]uint64, 0, len(shifted))
		for _, v := range shifted {
			sum, ok := checkedAddU64(v, minValue)
			if !ok {
				return nil, invalidData("u64 FOR overflow")
			}
			out = append(out, sum)
		}
		return out, nil
	case VectorCodecPlain:
		return decodeU64Plain(reader)
	case VectorCodecSimple8b:
		return decodeU64Simple8b(reader)
	case VectorCodecDictionary, VectorCodecStringRef, VectorCodecPrefixDelta, VectorCodecXorFloat,
		VectorCodecDeltaBitpack, VectorCodecDeltaForBitpack, VectorCodecDeltaDeltaBitpack, VectorCodecPatchedFor:
		return decodeU64Plain(reader)
	default:
		return nil, invalidData("unsupported vector codec")
	}
}

func encodeF64Vector(values []float64, codec VectorCodec, out *[]byte) {
	if codec == VectorCodecXorFloat {
		encodeXorFloat(values, out)
		return
	}
	encodeVaruint(uint64(len(values)), out)
	for _, v := range values {
		appendF64LE(out, v)
	}
}

func decodeF64Vector(reader *Reader, codec VectorCodec) ([]float64, error) {
	if codec == VectorCodecXorFloat {
		return decodeXorFloat(reader)
	}
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	out := make([]float64, 0, int(length))
	for i := 0; i < int(length); i++ {
		v, err := readF64LE(reader)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func encodeU64Plain(values []uint64, out *[]byte) {
	encodeVaruint(uint64(len(values)), out)
	for _, value := range values {
		encodeVaruint(value, out)
	}
}

func decodeU64Plain(reader *Reader) ([]uint64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	out := make([]uint64, 0, int(length))
	for i := 0; i < int(length); i++ {
		v, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func encodeU64Rle(values []uint64, out *[]byte) {
	type run struct {
		value uint64
		count uint64
	}
	runs := make([]run, 0)
	for _, value := range values {
		if n := len(runs); n > 0 && runs[n-1].value == value {
			runs[n-1].count++
			continue
		}
		runs = append(runs, run{value: value, count: 1})
	}
	encodeVaruint(uint64(len(runs)), out)
	for _, r := range runs {
		encodeVaruint(r.value, out)
		encodeVaruint(r.count, out)
	}
}

func decodeU64Rle(reader *Reader) ([]uint64, error) {
	runsLen, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	out := make([]uint64, 0)
	for i := 0; i < int(runsLen); i++ {
		value, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		count, err := reader.readCount()
		if err != nil {
			return nil, err
		}
		for j := 0; j < int(count); j++ {
			out = append(out, value)
		}
	}
	return out, nil
}

func encodeU64DirectBitpack(values []uint64, out *[]byte) {
	encodeVaruint(uint64(len(values)), out)
	if len(values) == 0 {
		*out = append(*out, 0)
		return
	}
	width := uint8(1)
	for _, v := range values {
		bw := bitWidth(v)
		if bw > width {
			width = bw
		}
	}
	*out = append(*out, width)
	packU64Values(values, width, out)
}

func decodeU64DirectBitpack(reader *Reader) ([]uint64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	width, err := reader.readU8()
	if err != nil {
		return nil, err
	}
	if length == 0 {
		return []uint64{}, nil
	}
	if width == 0 || width > 64 {
		return nil, invalidData("bitpack width")
	}
	return unpackU64Values(reader, int(length), width)
}

func encodeI64Plain(values []int64, out *[]byte) {
	encodeVaruint(uint64(len(values)), out)
	for _, value := range values {
		encodeVaruint(encodeZigzag(value), out)
	}
}

func decodeI64Plain(reader *Reader) ([]int64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	out := make([]int64, 0, int(length))
	for i := 0; i < int(length); i++ {
		v, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		out = append(out, decodeZigzag(v))
	}
	return out, nil
}

func encodeI64Simple8b(values []int64, out *[]byte) {
	encoded := make([]uint64, len(values))
	for i, v := range values {
		encoded[i] = encodeZigzag(v)
	}
	encodeU64Simple8bInner(encoded, out)
}

func decodeI64Simple8b(reader *Reader) ([]int64, error) {
	encoded, err := decodeU64Simple8bInner(reader)
	if err != nil {
		return nil, err
	}
	out := make([]int64, len(encoded))
	for i, v := range encoded {
		out[i] = decodeZigzag(v)
	}
	return out, nil
}

func encodeU64Simple8b(values []uint64, out *[]byte) {
	encodeU64Simple8bInner(values, out)
}

func decodeU64Simple8b(reader *Reader) ([]uint64, error) {
	return decodeU64Simple8bInner(reader)
}

var simple8bSlots = [...]struct {
	count int
	width uint8
}{
	{60, 1},
	{30, 2},
	{20, 3},
	{15, 4},
	{12, 5},
	{10, 6},
	{8, 7},
	{7, 8},
	{6, 10},
	{5, 12},
	{4, 15},
	{3, 20},
	{2, 30},
	{1, 60},
}

func encodeU64Simple8bInner(values []uint64, out *[]byte) {
	encodeVaruint(uint64(len(values)), out)
	if len(values) == 0 {
		return
	}
	maxValue := uint64(0)
	for _, v := range values {
		if v > maxValue {
			maxValue = v
		}
	}
	if maxValue > ((uint64(1) << 60) - 1) {
		*out = append(*out, 0)
		for _, value := range values {
			encodeVaruint(value, out)
		}
		return
	}

	*out = append(*out, 1)
	idx := 0
	for idx < len(values) {
		zeroRun := 0
		for idx+zeroRun < len(values) && values[idx+zeroRun] == 0 && zeroRun < 240 {
			zeroRun++
		}
		if zeroRun >= 120 {
			take := 120
			if zeroRun >= 240 {
				take = 240
			}
			word := uint64(1) << 60
			if take == 240 {
				word = 0
			}
			appendU64LE(out, word)
			idx += take
			continue
		}

		packed := false
		for selectorIdx, slot := range simple8bSlots {
			if idx+slot.count > len(values) {
				continue
			}
			maxEncodable := uint64(0)
			if slot.width == 64 {
				maxEncodable = ^uint64(0)
			} else {
				maxEncodable = (uint64(1) << slot.width) - 1
			}
			allFit := true
			for _, value := range values[idx : idx+slot.count] {
				if value > maxEncodable {
					allFit = false
					break
				}
			}
			if !allFit {
				continue
			}
			selector := uint64(selectorIdx + 2)
			payload := uint64(0)
			shift := uint(0)
			for _, value := range values[idx : idx+slot.count] {
				payload |= value << shift
				shift += uint(slot.width)
			}
			word := (selector << 60) | payload
			appendU64LE(out, word)
			idx += slot.count
			packed = true
			break
		}
		if !packed {
			selector := uint64(15)
			word := (selector << 60) | (values[idx] & ((uint64(1) << 60) - 1))
			appendU64LE(out, word)
			idx++
		}
	}
}

func decodeU64Simple8bInner(reader *Reader) ([]uint64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	if length == 0 {
		return []uint64{}, nil
	}
	mode, err := reader.readU8()
	if err != nil {
		return nil, err
	}
	if mode == 0 {
		out := make([]uint64, 0, int(length))
		for i := 0; i < int(length); i++ {
			v, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	}
	if mode != 1 {
		return nil, invalidData("simple8b mode")
	}

	out := make([]uint64, 0, int(length))
	for len(out) < int(length) {
		packed, err := readU64LE(reader)
		if err != nil {
			return nil, err
		}
		selector := int(packed >> 60)
		payload := packed & ((uint64(1) << 60) - 1)
		switch {
		case selector == 0 || selector == 1:
			count := 240
			if selector == 1 {
				count = 120
			}
			remain := int(length) - len(out)
			limit := count
			if remain < limit {
				limit = remain
			}
			for i := 0; i < limit; i++ {
				out = append(out, 0)
			}
		case selector >= 2 && selector <= 15:
			count := 1
			width := uint8(60)
			if selector != 15 {
				slot := simple8bSlots[selector-2]
				count = slot.count
				width = slot.width
			}
			mask := uint64(0)
			if width == 64 {
				mask = ^uint64(0)
			} else {
				mask = (uint64(1) << width) - 1
			}
			shift := uint(0)
			remain := int(length) - len(out)
			limit := count
			if remain < limit {
				limit = remain
			}
			for i := 0; i < limit; i++ {
				out = append(out, (payload>>shift)&mask)
				shift += uint(width)
			}
		default:
			return nil, invalidData("simple8b selector")
		}
	}
	return out, nil
}

func delta(values []int64) []int64 {
	out := make([]int64, 0, len(values))
	prev := int64(0)
	for i, value := range values {
		if i == 0 {
			out = append(out, value)
		} else {
			out = append(out, value-prev)
		}
		prev = value
	}
	return out
}

func undelta(values []int64) ([]int64, error) {
	out := make([]int64, 0, len(values))
	prev := int64(0)
	for i, value := range values {
		if i == 0 {
			out = append(out, value)
			prev = value
			continue
		}
		next, ok := checkedAddI64(prev, value)
		if !ok {
			return nil, invalidData("delta overflow")
		}
		out = append(out, next)
		prev = next
	}
	return out, nil
}

func encodeI64Rle(values []int64, out *[]byte) {
	type run struct {
		value int64
		count uint64
	}
	runs := make([]run, 0)
	for _, value := range values {
		if n := len(runs); n > 0 && runs[n-1].value == value {
			runs[n-1].count++
			continue
		}
		runs = append(runs, run{value: value, count: 1})
	}
	encodeVaruint(uint64(len(runs)), out)
	for _, r := range runs {
		encodeVaruint(encodeZigzag(r.value), out)
		encodeVaruint(r.count, out)
	}
}

func decodeI64Rle(reader *Reader) ([]int64, error) {
	runsLen, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	out := make([]int64, 0)
	for i := 0; i < int(runsLen); i++ {
		valueEncoded, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		value := decodeZigzag(valueEncoded)
		count, err := reader.readCount()
		if err != nil {
			return nil, err
		}
		for j := 0; j < int(count); j++ {
			out = append(out, value)
		}
	}
	return out, nil
}

func encodeI64PatchedFor(values []int64, out *[]byte) {
	if len(values) == 0 {
		encodeVaruint(0, out)
		return
	}
	base := values[0]
	for _, v := range values[1:] {
		if v < base {
			base = v
		}
	}
	shifted := make([]int64, len(values))
	for i, v := range values {
		shifted[i] = v - base
	}
	encodeVaruint(uint64(len(shifted)), out)
	encodeVaruint(encodeZigzag(base), out)

	maxValue := int64(0)
	for _, value := range shifted {
		if value > maxValue {
			maxValue = value
		}
	}
	bw := bitWidth(uint64(maxValue))
	baseWidth := uint8(0)
	if bw > 2 {
		baseWidth = bw - 2
	}
	*out = append(*out, baseWidth)

	type patch struct {
		pos   uint64
		value int64
	}
	patchPositions := make([]patch, 0)
	mainValues := make([]int64, 0, len(shifted))
	for idx, value := range shifted {
		if bitWidth(uint64(value)) > baseWidth {
			patchPositions = append(patchPositions, patch{pos: uint64(idx), value: value})
			main := int64(0)
			if baseWidth > 0 {
				mask := int64((uint64(1) << baseWidth) - 1)
				main = value & mask
				if main < 0 {
					main = 0
				}
			}
			mainValues = append(mainValues, main)
		} else {
			mainValues = append(mainValues, value)
		}
	}
	for _, value := range mainValues {
		encodeVaruint(uint64(value), out)
	}
	encodeVaruint(uint64(len(patchPositions)), out)
	for _, p := range patchPositions {
		encodeVaruint(p.pos, out)
		encodeVaruint(uint64(p.value), out)
	}
}

func decodeI64PatchedFor(reader *Reader) ([]int64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	if length == 0 {
		return []int64{}, nil
	}
	baseEncoded, err := reader.readVaruint()
	if err != nil {
		return nil, err
	}
	base := decodeZigzag(baseEncoded)
	if _, err := reader.readU8(); err != nil {
		return nil, err
	}
	values := make([]int64, 0, int(length))
	for i := 0; i < int(length); i++ {
		v, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		values = append(values, int64(v))
	}
	patchCount, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	for i := 0; i < int(patchCount); i++ {
		pos, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		patch, err := reader.readVaruint()
		if err != nil {
			return nil, err
		}
		if int(pos) < len(values) {
			values[int(pos)] = int64(patch)
		}
	}
	out := make([]int64, len(values))
	for i, v := range values {
		out[i] = v + base
	}
	return out, nil
}

func encodeXorFloat(values []float64, out *[]byte) {
	encodeVaruint(uint64(len(values)), out)
	if len(values) == 0 {
		return
	}
	appendU64LE(out, math.Float64bits(values[0]))
	prev := math.Float64bits(values[0])
	for _, value := range values[1:] {
		bitsValue := math.Float64bits(value)
		x := prev ^ bitsValue
		if x == 0 {
			*out = append(*out, 0)
		} else {
			*out = append(*out, 1)
			leading := uint64(bits.LeadingZeros64(x))
			trailing := uint64(bits.TrailingZeros64(x))
			width := uint64(64) - (leading + trailing)
			encodeVaruint(leading, out)
			encodeVaruint(trailing, out)
			encodeVaruint(width, out)
			payload := x
			if width != 64 {
				payload = (x >> trailing) & ((uint64(1) << width) - 1)
			}
			encodeVaruint(payload, out)
		}
		prev = bitsValue
	}
}

func decodeXorFloat(reader *Reader) ([]float64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	if length == 0 {
		return []float64{}, nil
	}
	firstBits, err := readU64LE(reader)
	if err != nil {
		return nil, err
	}
	out := make([]float64, 0, int(length))
	out = append(out, math.Float64frombits(firstBits))
	prev := firstBits
	for i := 1; i < int(length); i++ {
		flag, err := reader.readU8()
		if err != nil {
			return nil, err
		}
		bitsValue := prev
		if flag != 0 {
			leading, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			trailing, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			width, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			payload, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			if leading+trailing+width > 64 {
				return nil, invalidData("xor-float bit widths")
			}
			x := payload
			if width != 64 {
				x = payload << trailing
			}
			bitsValue = prev ^ x
		}
		out = append(out, math.Float64frombits(bitsValue))
		prev = bitsValue
	}
	return out, nil
}

func encodeI64DirectBitpack(values []int64, out *[]byte) {
	encodeVaruint(uint64(len(values)), out)
	if len(values) == 0 {
		*out = append(*out, 0)
		return
	}
	encoded := make([]uint64, len(values))
	width := uint8(1)
	for i, v := range values {
		enc := encodeZigzag(v)
		encoded[i] = enc
		bw := bitWidth(enc)
		if bw > width {
			width = bw
		}
	}
	*out = append(*out, width)
	packU64Values(encoded, width, out)
}

func decodeI64DirectBitpack(reader *Reader) ([]int64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	width, err := reader.readU8()
	if err != nil {
		return nil, err
	}
	if length == 0 {
		return []int64{}, nil
	}
	if width == 0 || width > 64 {
		return nil, invalidData("bitpack width")
	}
	encoded, err := unpackU64Values(reader, int(length), width)
	if err != nil {
		return nil, err
	}
	out := make([]int64, len(encoded))
	for i, v := range encoded {
		out[i] = decodeZigzag(v)
	}
	return out, nil
}

func encodeI64DeltaDelta(values []int64, out *[]byte) {
	encodeVaruint(uint64(len(values)), out)
	if len(values) == 0 {
		return
	}
	encodeVaruint(encodeZigzag(values[0]), out)
	if len(values) == 1 {
		return
	}
	d1 := values[1] - values[0]
	encodeVaruint(encodeZigzag(d1), out)
	dd := make([]int64, 0, len(values)-2)
	prevDelta := d1
	for i := 1; i < len(values)-1; i++ {
		d := values[i+1] - values[i]
		dd = append(dd, d-prevDelta)
		prevDelta = d
	}
	encodeI64DirectBitpack(dd, out)
}

func decodeI64DeltaDelta(reader *Reader) ([]int64, error) {
	length, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	if length == 0 {
		return []int64{}, nil
	}
	firstEncoded, err := reader.readVaruint()
	if err != nil {
		return nil, err
	}
	first := decodeZigzag(firstEncoded)
	if length == 1 {
		return []int64{first}, nil
	}
	firstDeltaEncoded, err := reader.readVaruint()
	if err != nil {
		return nil, err
	}
	firstDelta := decodeZigzag(firstDeltaEncoded)
	dd, err := decodeI64DirectBitpack(reader)
	if err != nil {
		return nil, err
	}
	if len(dd) != int(length)-2 {
		return nil, invalidData("delta-delta length")
	}
	out := make([]int64, 0, int(length))
	out = append(out, first)
	prev := first
	second, ok := checkedAddI64(prev, firstDelta)
	if !ok {
		return nil, invalidData("delta-delta overflow")
	}
	out = append(out, second)
	prev = second
	prevDelta := firstDelta
	for _, ddv := range dd {
		d, ok := checkedAddI64(prevDelta, ddv)
		if !ok {
			return nil, invalidData("delta-delta overflow")
		}
		next, ok := checkedAddI64(prev, d)
		if !ok {
			return nil, invalidData("delta-delta overflow")
		}
		out = append(out, next)
		prev = next
		prevDelta = d
	}
	return out, nil
}

func packU64Values(values []uint64, width uint8, out *[]byte) {
	totalBits := len(values) * int(width)
	byteLen := (totalBits + 7) / 8
	bytes := make([]byte, byteLen)
	bitPos := 0
	for _, value := range values {
		written := 0
		for written < int(width) {
			byteIdx := bitPos / 8
			bitOff := bitPos % 8
			room := 8 - bitOff
			take := int(width) - written
			if take > room {
				take = room
			}
			mask := uint64((1 << take) - 1)
			part := (value >> uint(written)) & mask
			bytes[byteIdx] |= byte(part << uint(bitOff))
			bitPos += take
			written += take
		}
	}
	*out = append(*out, bytes...)
}

func unpackU64Values(reader *Reader, length int, width uint8) ([]uint64, error) {
	totalBits := length * int(width)
	byteLen := (totalBits + 7) / 8
	bytes, err := reader.readExact(byteLen)
	if err != nil {
		return nil, err
	}
	out := make([]uint64, 0, length)
	bitPos := 0
	for i := 0; i < length; i++ {
		value := uint64(0)
		written := 0
		for written < int(width) {
			byteIdx := bitPos / 8
			if byteIdx >= len(bytes) {
				return nil, invalidData("bitpack underflow")
			}
			bitOff := bitPos % 8
			room := 8 - bitOff
			take := int(width) - written
			if take > room {
				take = room
			}
			mask := byte((1 << take) - 1)
			part := (bytes[byteIdx] >> uint(bitOff)) & mask
			value |= uint64(part) << uint(written)
			bitPos += take
			written += take
		}
		out = append(out, value)
	}
	return out, nil
}

func bitWidth(v uint64) uint8 {
	if v == 0 {
		return 1
	}
	return uint8(64 - bits.LeadingZeros64(v))
}

func checkedAddU64(a, b uint64) (uint64, bool) {
	sum := a + b
	return sum, sum >= a
}

func checkedAddI64(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
