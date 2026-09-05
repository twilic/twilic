package core

import "testing"

func TestCodecSpecVectors_Simple8bI64RoundtripSmallValues(t *testing.T) {
	values := []int64{1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5}
	var out []byte
	encodeI64Vector(values, VectorCodecSimple8b, &out)
	reader := newReader(out)
	decoded, err := decodeI64Vector(reader, VectorCodecSimple8b)
	if err != nil {
		t.Fatalf("decode simple8b i64: %v", err)
	}
	if len(decoded) != len(values) {
		t.Fatalf("decoded length mismatch")
	}
	for i := range decoded {
		if decoded[i] != values[i] {
			t.Fatalf("decoded[%d]=%d expected %d", i, decoded[i], values[i])
		}
	}
}

func TestCodecSpecVectors_Simple8bU64RoundtripWithLongZeroRuns(t *testing.T) {
	values := make([]uint64, 130)
	values = append(values, 1, 2, 3, 4, 5)
	values = append(values, make([]uint64, 250)...)

	var out []byte
	encodeU64Vector(values, VectorCodecSimple8b, &out)
	reader := newReader(out)
	decoded, err := decodeU64Vector(reader, VectorCodecSimple8b)
	if err != nil {
		t.Fatalf("decode simple8b u64: %v", err)
	}
	if len(decoded) != len(values) {
		t.Fatalf("decoded length mismatch")
	}
	for i := range decoded {
		if decoded[i] != values[i] {
			t.Fatalf("decoded[%d]=%d expected %d", i, decoded[i], values[i])
		}
	}
}

func TestCodecSpecVectors_Simple8bU64FallsBackForLargeValues(t *testing.T) {
	values := []uint64{1 << 61, (1 << 61) + 7, (1 << 61) + 99}
	var out []byte
	encodeU64Vector(values, VectorCodecSimple8b, &out)
	reader := newReader(out)
	decoded, err := decodeU64Vector(reader, VectorCodecSimple8b)
	if err != nil {
		t.Fatalf("decode fallback simple8b: %v", err)
	}
	for i := range values {
		if decoded[i] != values[i] {
			t.Fatalf("decoded[%d]=%d expected %d", i, decoded[i], values[i])
		}
	}
}

func TestCodecSpecVectors_ForU64OverflowIsRejected(t *testing.T) {
	var bytes []byte
	encodeVaruint(^uint64(0), &bytes)
	encodeVaruint(1, &bytes)
	bytes = append(bytes, 1, 0x01)

	reader := newReader(bytes)
	_, err := decodeU64Vector(reader, VectorCodecForBitpack)
	te := requireTwilicErrorKind(t, err, ErrInvalidData)
	if te.Msg != "u64 FOR overflow" {
		t.Fatalf("unexpected message %q", te.Msg)
	}
}

func TestCodecSpecVectors_DirectBitpackInvalidWidthIsRejected(t *testing.T) {
	var bytes []byte
	encodeVaruint(1, &bytes)
	bytes = append(bytes, 0)
	reader := newReader(bytes)
	_, err := decodeI64Vector(reader, VectorCodecDirectBitpack)
	te := requireTwilicErrorKind(t, err, ErrInvalidData)
	if te.Msg != "bitpack width" {
		t.Fatalf("unexpected message %q", te.Msg)
	}
}

func TestCodecSpecVectors_XorFloatRoundtripSmoothSeries(t *testing.T) {
	values := []float64{1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5}
	var out []byte
	encodeF64Vector(values, VectorCodecXorFloat, &out)
	reader := newReader(out)
	decoded, err := decodeF64Vector(reader, VectorCodecXorFloat)
	if err != nil {
		t.Fatalf("decode xor float: %v", err)
	}
	for i := range values {
		if decoded[i] != values[i] {
			t.Fatalf("decoded[%d]=%v expected %v", i, decoded[i], values[i])
		}
	}
}
