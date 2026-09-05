package core

import (
	"hash/fnv"
	"math/bits"
	"sort"
)

func decodeTrainedDictionaryPayload(payload []byte) ([]string, error) {
	reader := newReader(payload)
	n, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	values := make([]string, 0, int(n))
	for i := uint64(0); i < n; i++ {
		s, err := reader.readString()
		if err != nil {
			return nil, err
		}
		values = append(values, s)
	}
	if !reader.isEOF() {
		return nil, invalidData("trained dictionary payload trailing bytes")
	}
	return values, nil
}

func encodeTrainedDictionaryBlock(values []string, dictionary []string) ([]byte, bool, error) {
	if len(values) == 0 {
		var out []byte
		out = append(out, 0)
		encodeVaruint(0, &out)
		return out, true, nil
	}
	byValue := make(map[string]uint64, len(dictionary))
	for idx, value := range dictionary {
		byValue[value] = uint64(idx)
	}
	ids := make([]uint64, 0, len(values))
	for _, value := range values {
		id, ok := byValue[value]
		if !ok {
			return nil, false, nil
		}
		ids = append(ids, id)
	}
	var raw []byte
	raw = append(raw, 0)
	encodeVaruint(uint64(len(ids)), &raw)
	for _, id := range ids {
		encodeVaruint(id, &raw)
	}
	maxID := uint64(0)
	for _, id := range ids {
		if id > maxID {
			maxID = id
		}
	}
	bitWidth := byte(0)
	if maxID > 0 {
		bitWidth = byte(64 - bits.LeadingZeros64(maxID))
	}
	var packed []byte
	if err := packFixedWidthU64(ids, bitWidth, &packed); err != nil {
		return nil, false, err
	}
	var bitpacked []byte
	bitpacked = append(bitpacked, 1)
	encodeVaruint(uint64(len(ids)), &bitpacked)
	bitpacked = append(bitpacked, bitWidth)
	bitpacked = append(bitpacked, packed...)
	if len(bitpacked) < len(raw) {
		return bitpacked, true, nil
	}
	return raw, true, nil
}

func decodeTrainedDictionaryBlock(block []byte, dictionary []string) ([]string, error) {
	reader := newReader(block)
	mode, err := reader.readU8()
	if err != nil {
		return nil, err
	}
	n, err := reader.readCount()
	if err != nil {
		return nil, err
	}
	var ids []uint64
	switch mode {
	case 0:
		ids = make([]uint64, 0, int(n))
		for i := uint64(0); i < n; i++ {
			id, err := reader.readVaruint()
			if err != nil {
				return nil, err
			}
			ids = append(ids, id)
		}
	case 1:
		bitWidth, err := reader.readU8()
		if err != nil {
			return nil, err
		}
		remaining := len(block) - reader.position()
		packed, err := reader.readExact(remaining)
		if err != nil {
			return nil, err
		}
		ids, err = unpackFixedWidthU64(packed, int(n), bitWidth)
		if err != nil {
			return nil, err
		}
	default:
		return nil, invalidData("trained dictionary block mode")
	}
	if !reader.isEOF() {
		return nil, invalidData("trained dictionary block trailing bytes")
	}
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if int(id) >= len(dictionary) {
			return nil, invalidData("trained dictionary block id")
		}
		out = append(out, dictionary[id])
	}
	return out, nil
}

func packFixedWidthU64(values []uint64, width byte, out *[]byte) error {
	if width > 64 {
		return invalidData("fixed-width u64 bit width")
	}
	if width == 0 {
		for _, value := range values {
			if value != 0 {
				return invalidData("fixed-width u64 value overflow")
			}
		}
		return nil
	}
	var acc wideU128
	var accBits uint32
	for _, value := range values {
		if width < 64 && value>>width != 0 {
			return invalidData("fixed-width u64 value overflow")
		}
		acc = acc.or(wideFromU64(value).shl(accBits))
		accBits += uint32(width)
		for accBits >= 8 {
			*out = append(*out, byte(acc.lo&0xFF))
			acc = acc.shr(8)
			accBits -= 8
		}
	}
	if accBits > 0 {
		*out = append(*out, byte(acc.lo&0xFF))
	}
	return nil
}

func unpackFixedWidthU64(bytes []byte, count int, width byte) ([]uint64, error) {
	if width > 64 {
		return nil, invalidData("fixed-width u64 bit width")
	}
	if width == 0 {
		for _, b := range bytes {
			if b != 0 {
				return nil, invalidData("fixed-width u64 trailing bytes")
			}
		}
		out := make([]uint64, count)
		return out, nil
	}
	out := make([]uint64, 0, count)
	var acc wideU128
	var accBits uint32
	idx := 0
	mask := wideMask(width)
	for range count {
		for accBits < uint32(width) {
			if idx >= len(bytes) {
				return nil, invalidData("fixed-width u64 underflow")
			}
			acc = acc.or(wideFromU64(uint64(bytes[idx])).shl(accBits))
			idx++
			accBits += 8
		}
		out = append(out, acc.and(mask).lo)
		acc = acc.shr(uint32(width))
		accBits -= uint32(width)
	}
	if !acc.isZero() {
		return nil, invalidData("fixed-width u64 trailing bytes")
	}
	for ; idx < len(bytes); idx++ {
		if bytes[idx] != 0 {
			return nil, invalidData("fixed-width u64 trailing bytes")
		}
	}
	return out, nil
}

type wideU128 struct {
	lo, hi uint64
}

func wideFromU64(v uint64) wideU128 { return wideU128{lo: v} }

func wideMask(width byte) wideU128 {
	if width == 64 {
		return wideU128{lo: ^uint64(0), hi: ^uint64(0)}
	}
	if width == 0 {
		return wideU128{}
	}
	if width <= 64 {
		return wideU128{lo: (uint64(1) << width) - 1}
	}
	lo := ^uint64(0)
	hi := (uint64(1) << (width - 64)) - 1
	return wideU128{lo: lo, hi: hi}
}

func (w wideU128) isZero() bool { return w.lo == 0 && w.hi == 0 }

func (w wideU128) and(m wideU128) wideU128 { return wideU128{lo: w.lo & m.lo, hi: w.hi & m.hi} }

func (a wideU128) or(b wideU128) wideU128 {
	return wideU128{lo: a.lo | b.lo, hi: a.hi | b.hi}
}

func (w wideU128) shl(n uint32) wideU128 {
	if n == 0 {
		return w
	}
	if n >= 128 {
		return wideU128{}
	}
	if n < 64 {
		hi := (w.hi << n) | (w.lo >> (64 - n))
		lo := w.lo << n
		return wideU128{lo: lo, hi: hi}
	}
	n -= 64
	return wideU128{lo: 0, hi: w.lo << n}
}

func (w wideU128) shr(n uint32) wideU128 {
	if n == 0 {
		return w
	}
	if n >= 128 {
		return wideU128{}
	}
	if n < 64 {
		lo := (w.lo >> n) | (w.hi << (64 - n))
		hi := w.hi >> n
		return wideU128{lo: lo, hi: hi}
	}
	n -= 64
	return wideU128{lo: w.hi >> n, hi: 0}
}

func applyDictionaryReferences(state *SessionState, columns *[]Column) {
	for i := range *columns {
		column := &(*columns)[i]
		if column.Values.Kind != ElementTypeString {
			continue
		}
		values := column.Values.Strings
		if len(values) < 16 {
			continue
		}
		unique := make(map[string]struct{})
		for _, v := range values {
			unique[v] = struct{}{}
		}
		if float64(len(unique))/float64(len(values)) > 0.5 {
			continue
		}
		if column.Codec != VectorCodecDictionary && column.Codec != VectorCodecStringRef {
			continue
		}
		dictID := state.AllocateDictionaryID()
		var payload []byte
		keys := make([]string, 0, len(unique))
		for k := range unique {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		encodeVaruint(uint64(len(keys)), &payload)
		for _, item := range keys {
			encodeString(item, &payload)
		}
		profile := DictionaryProfile{
			Version:   1,
			Hash:      dictionaryPayloadHash(payload),
			ExpiresAt: 0,
			Fallback:  DictionaryFallbackFailFast,
		}
		if state.Options.UnknownReferencePolicy == UnknownReferencePolicyStatelessRetry {
			profile.Fallback = DictionaryFallbackStatelessRetry
		}
		state.Dictionaries[dictID] = payload
		state.DictionaryProfiles[dictID] = profile
		column.DictionaryID = &dictID
	}
}

func fnv1a64(payload []byte) uint64 {
	h := fnv.New64a()
	_, _ = h.Write(payload)
	return h.Sum64()
}
