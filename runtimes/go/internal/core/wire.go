package core

import (
	"encoding/binary"
	"math"
	"unicode/utf8"
)

func encodeVaruint(value uint64, out *[]byte) {
	if value < 0x80 {
		*out = append(*out, byte(value))
		return
	}
	for {
		b := byte(value & 0x7F)
		value >>= 7
		if value != 0 {
			b |= 0x80
		}
		*out = append(*out, b)
		if value == 0 {
			break
		}
	}
}

func encodeZigzag(value int64) uint64 {
	return uint64((value << 1) ^ (value >> 63))
}

func decodeZigzag(value uint64) int64 {
	return int64((value >> 1) ^ uint64(-(int64(value & 1))))
}

func encodeBytes(bytes []byte, out *[]byte) {
	encodeVaruint(uint64(len(bytes)), out)
	*out = append(*out, bytes...)
}

func encodeString(value string, out *[]byte) {
	encodeBytes([]byte(value), out)
}

func encodeBitmap(bits []bool, out *[]byte) {
	encodeVaruint(uint64(len(bits)), out)
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
	if len(bits)%8 != 0 {
		*out = append(*out, current)
	}
}

type Reader struct {
	input  []byte
	offset int
	depth  int
	budget uint64
}

func newReader(input []byte) *Reader {
	return &Reader{input: input, budget: uint64(min(len(input), 1024)) * 1024}
}

func (r *Reader) claimOutput(count uint64) error {
	if count > 1<<20 {
		return invalidData("decode count limit exceeded")
	}
	if count > r.budget/8 {
		return invalidData("decode output ratio exceeded")
	}
	r.budget -= count * 8
	return nil
}

func (r *Reader) readCount(maximum ...uint64) (uint64, error) {
	n, err := r.readVaruint()
	if err != nil {
		return 0, err
	}
	max := uint64(1 << 20)
	if len(maximum) > 0 {
		max = maximum[0]
	}
	if n > max {
		return 0, invalidData("decode count limit exceeded")
	}
	if err := r.claimOutput(n); err != nil {
		return 0, err
	}
	return n, nil
}

func (r *Reader) enterDepth() error {
	if r.depth >= 64 {
		return invalidData("decode depth limit exceeded")
	}
	r.depth++
	return nil
}
func (r *Reader) leaveDepth() { r.depth-- }

func (r *Reader) position() int {
	return r.offset
}

func (r *Reader) isEOF() bool {
	return r.offset >= len(r.input)
}

func (r *Reader) readU8() (byte, error) {
	if r.offset >= len(r.input) {
		return 0, unexpectedEOF()
	}
	b := r.input[r.offset]
	r.offset++
	return b, nil
}

func (r *Reader) readExact(n int) ([]byte, error) {
	end := r.offset + n
	if n < 0 || n > len(r.input)-r.offset {
		return nil, unexpectedEOF()
	}
	slice := r.input[r.offset:end]
	r.offset = end
	return slice, nil
}

func (r *Reader) readVaruint() (uint64, error) {
	start := r.offset
	var shift uint32
	var result uint64
	for {
		if shift >= 64 {
			return 0, invalidData("varuint too large")
		}
		b, err := r.readU8()
		if err != nil {
			return 0, err
		}
		if shift == 63 && (b&0x7E) != 0 {
			return 0, invalidData("varuint too large")
		}
		result |= uint64(b&0x7F) << shift
		if b&0x80 == 0 {
			if r.offset-start != varuintEncodedLen(result) {
				return 0, invalidData("varuint overlong")
			}
			return result, nil
		}
		shift += 7
	}
}

func varuintEncodedLen(value uint64) int {
	if value == 0 {
		return 1
	}
	length := 0
	for value > 0 {
		length++
		value >>= 7
	}
	return length
}

func (r *Reader) readI64Zigzag() (int64, error) {
	encoded, err := r.readVaruint()
	if err != nil {
		return 0, err
	}
	return decodeZigzag(encoded), nil
}

func (r *Reader) readBytes() ([]byte, error) {
	n, err := r.readVaruint()
	if err != nil {
		return nil, err
	}
	if n > uint64(len(r.input)-r.offset) {
		return nil, unexpectedEOF()
	}
	return r.readExact(int(n))
}

func (r *Reader) readString() (string, error) {
	n, err := r.readVaruint()
	if err != nil {
		return "", err
	}
	if n > uint64(len(r.input)-r.offset) {
		return "", unexpectedEOF()
	}
	bytes, err := r.readExact(int(n))
	if err != nil {
		return "", err
	}
	if !utf8.Valid(bytes) {
		return "", utf8Error()
	}
	return string(bytes), nil
}

func (r *Reader) readBitmap() ([]bool, error) {
	bitCount, err := r.readCount()
	if err != nil {
		return nil, err
	}
	byteCount := int((bitCount + 7) / 8)
	bytes, err := r.readExact(byteCount)
	if err != nil {
		return nil, err
	}
	bits := make([]bool, bitCount)
	for i := 0; i < int(bitCount); i++ {
		bits[i] = ((bytes[i/8] >> (i % 8)) & 1) == 1
	}
	return bits, nil
}

func readU64LE(r *Reader) (uint64, error) {
	b, err := r.readExact(8)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(b), nil
}

func readF64LE(r *Reader) (float64, error) {
	u, err := readU64LE(r)
	if err != nil {
		return 0, err
	}
	return math.Float64frombits(u), nil
}

func appendU64LE(out *[]byte, v uint64) {
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], v)
	*out = append(*out, buf[:]...)
}

func appendF64LE(out *[]byte, v float64) {
	appendU64LE(out, math.Float64bits(v))
}
