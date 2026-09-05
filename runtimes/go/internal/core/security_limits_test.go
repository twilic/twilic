package core

import (
	"bytes"
	"testing"
)

func TestSecurityDecodeDepth(t *testing.T) {
	data := append(bytes.Repeat([]byte{0xa1}, 70), 0xc0)
	if _, err := Decode(data); err == nil {
		t.Fatal("missing depth rejection")
	}
	if _, err := Decode([]byte{0xa0}); err != nil {
		t.Fatal(err)
	}
}

func TestSecurityReaderBudgets(t *testing.T) {
	r := newReader([]byte{0})
	if err := r.claimOutput(100); err != nil {
		t.Fatal(err)
	}
	if err := r.claimOutput(100); err == nil {
		t.Fatal("missing cumulative budget")
	}
	if _, err := newReader([]byte{0}).readExact(-1); err == nil {
		t.Fatal("negative length accepted")
	}
	var data []byte
	for _, n := range []uint64{1, 0, 100000} {
		encodeVaruint(n, &data)
	}
	if _, err := decodeU64Rle(newReader(data)); err == nil {
		t.Fatal("RLE expansion accepted")
	}
}
