package core

import (
	"fmt"
	"io"
	"strings"
)

// InteropFrame is one line from the cross-language fixture stream (stream|label|hex).
type InteropFrame struct {
	Stream string
	Label  string
	Hex    string
	Bytes  []byte
}

func interopIDNameMap(id uint64, name string) Value {
	return NewMap(
		Entry("id", NewU64(id)),
		Entry("name", NewString(name)),
	)
}

func interopIDNameRoleMap(id uint64, name, role string) Value {
	return NewMap(
		Entry("id", NewU64(id)),
		Entry("name", NewString(name)),
		Entry("role", NewString(role)),
	)
}

func interopMakeI64Array(length int, start int64) []Value {
	out := make([]Value, length)
	for i := range out {
		out[i] = NewI64(start + int64(i))
	}
	return out
}

func interopMakeUserRows(names []string) []Value {
	rows := make([]Value, len(names))
	for i, name := range names {
		rows[i] = NewMap(
			Entry("id", NewU64(uint64(i+1))),
			Entry("name", NewString(name)),
		)
	}
	return rows
}

func interopBitpackControlPayload() []byte {
	out := make([]byte, 512)
	for i := range out {
		out[i] = byte(i % 2)
	}
	return out
}

func interopHuffmanControlPayload() []byte {
	out := make([]byte, 512)
	for i := range out {
		out[i] = 7
	}
	return out
}

// ResetEncodeShapeObservation clears encode-side shape promotion counters for the given field names.
func ResetEncodeShapeObservation(codec *TwilicCodec, keys []string) {
	delete(codec.State.EncodeShapeObservations, shapeKey(keys))
}

func interopFSEControlPayload() []byte {
	out := make([]byte, 512)
	for i := range out {
		out[i] = byte(i % 4)
	}
	return out
}

// EmitInteropFixtures writes the same fixture stream as scripts/emit-rust-client-fixtures.
func EmitInteropFixtures(w io.Writer) error {
	codec := NewTwilicCodec()

	alpha := NewString("alpha")
	if err := emitInteropValue(w, "codec", "scalar_string", codec, &alpha); err != nil {
		return err
	}

	mapTwo := interopIDNameMap(1, "alice")
	if err := emitInteropValue(w, "codec", "map_two_fields_first", codec, &mapTwo); err != nil {
		return err
	}
	ResetEncodeShapeObservation(codec, []string{"id", "name"})
	if err := emitInteropValue(w, "codec", "map_two_fields_second", codec, &mapTwo); err != nil {
		return err
	}

	mapThree := interopIDNameRoleMap(1, "alice", "admin")
	if err := emitInteropValue(w, "codec", "map_three_fields_first", codec, &mapThree); err != nil {
		return err
	}
	ResetEncodeShapeObservation(codec, []string{"id", "name", "role"})
	if err := emitInteropValue(w, "codec", "map_three_fields_second", codec, &mapThree); err != nil {
		return err
	}

	for i := 0; i < 8; i++ {
		dynamic := interopIDNameMap(uint64(10+i), fmt.Sprintf("user-%d", i))
		label := fmt.Sprintf("bulk_map_%d", i)
		if err := emitInteropValue(w, "codec", label, codec, &dynamic); err != nil {
			return err
		}
	}

	scalar := NewI64(42)
	baseSnapshot := Message{
		Kind: MessageKindBaseSnapshot,
		BaseSnapshot: &BaseSnapshotMessage{
			BaseID:           77,
			SchemaOrShapeRef: 0,
			Payload:          Message{Kind: MessageKindScalar, Scalar: &scalar},
		},
	}
	if err := emitInteropMessage(w, "codec", "base_snapshot", codec, &baseSnapshot); err != nil {
		return err
	}

	enc := NewSessionEncoder(DefaultSessionOptions())
	baseArray := NewArray(interopMakeI64Array(100, 0))
	baseBytes, err := enc.Encode(&baseArray)
	if err != nil {
		return err
	}
	if err := emitInteropFrame(w, "session", "session_base_array", baseBytes); err != nil {
		return err
	}

	oneChangeArr := interopMakeI64Array(100, 0)
	oneChangeArr[0] = NewI64(10_000)
	oneChange := NewArray(oneChangeArr)
	onePatch, err := enc.EncodePatch(&oneChange)
	if err != nil {
		return err
	}
	if err := emitInteropFrame(w, "session", "session_patch_one_change", onePatch); err != nil {
		return err
	}

	for step := 0; step < 4; step++ {
		iterArr := interopMakeI64Array(100, 0)
		iterArr[step] = NewI64(int64(20_000 + step))
		iterative := NewArray(iterArr)
		bytes, err := enc.EncodePatch(&iterative)
		if err != nil {
			return err
		}
		label := fmt.Sprintf("session_patch_iter_%d", step)
		if err := emitInteropFrame(w, "session", label, bytes); err != nil {
			return err
		}
	}

	manyArr := interopMakeI64Array(100, 0)
	for idx := 0; idx < 12; idx++ {
		manyArr[idx] = NewI64(int64(10_000 + idx))
	}
	manyChange := NewArray(manyArr)
	manyPatch, err := enc.EncodePatch(&manyChange)
	if err != nil {
		return err
	}
	if err := emitInteropFrame(w, "session", "session_patch_many_changes", manyPatch); err != nil {
		return err
	}

	rows1 := interopMakeUserRows([]string{"a", "b", "c", "d"})
	microFirst, err := enc.EncodeMicroBatch(rows1)
	if err != nil {
		return err
	}
	if err := emitInteropFrame(w, "session", "session_micro_batch_first", microFirst); err != nil {
		return err
	}

	rows2 := interopMakeUserRows([]string{"aa", "bb", "cc", "dd"})
	microSecond, err := enc.EncodeMicroBatch(rows2)
	if err != nil {
		return err
	}
	return emitInteropFrame(w, "session", "session_micro_batch_second", microSecond)
}

func emitInteropValue(w io.Writer, stream, label string, codec *TwilicCodec, value *Value) error {
	bytes, err := codec.EncodeValue(value)
	if err != nil {
		return err
	}
	return emitInteropFrame(w, stream, label, bytes)
}

func emitInteropMessage(w io.Writer, stream, label string, codec *TwilicCodec, message *Message) error {
	bytes, err := codec.EncodeMessage(message)
	if err != nil {
		return err
	}
	return emitInteropFrame(w, stream, label, bytes)
}

func emitInteropControlStream(w io.Writer, stream, label string, codec *TwilicCodec, streamCodec ControlStreamCodec, payload []byte) error {
	msg := Message{
		Kind: MessageKindControlStream,
		ControlStream: &ControlStreamMessage{
			Codec:   streamCodec,
			Payload: append([]byte(nil), payload...),
		},
	}
	return emitInteropMessage(w, stream, label, codec, &msg)
}

func emitInteropFrame(w io.Writer, stream, label string, bytes []byte) error {
	if _, err := fmt.Fprintf(w, "%s|%s|", stream, label); err != nil {
		return err
	}
	const hex = "0123456789abcdef"
	for _, b := range bytes {
		if _, err := fmt.Fprintf(w, "%c%c", hex[b>>4], hex[b&0x0f]); err != nil {
			return err
		}
	}
	_, err := fmt.Fprintln(w)
	return err
}

func ParseInteropFrames(input string) ([]InteropFrame, error) {
	var frames []InteropFrame
	for lineNo, rawLine := range strings.Split(input, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}
		stream, label, hex, err := parseInteropFrameLine(line)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNo+1, err)
		}
		bytes, err := decodeInteropHex(hex)
		if err != nil {
			return nil, fmt.Errorf("line %d (%s): %w", lineNo+1, label, err)
		}
		frames = append(frames, InteropFrame{
			Stream: stream,
			Label:  label,
			Hex:    hex,
			Bytes:  bytes,
		})
	}
	if len(frames) == 0 {
		return nil, fmt.Errorf("no fixture frames found")
	}
	return frames, nil
}

func parseInteropFrameLine(line string) (stream, label, hex string, err error) {
	first := strings.IndexByte(line, '|')
	if first <= 0 {
		return "", "", "", fmt.Errorf("invalid frame")
	}
	rest := line[first+1:]
	second := strings.IndexByte(rest, '|')
	if second <= 0 {
		return "", "", "", fmt.Errorf("invalid frame")
	}
	return line[:first], rest[:second], rest[second+1:], nil
}

func decodeInteropHex(hex string) ([]byte, error) {
	if len(hex)%2 != 0 {
		return nil, fmt.Errorf("invalid hex length")
	}
	out := make([]byte, len(hex)/2)
	for i := 0; i < len(out); i++ {
		hi, err := interopHexNibble(hex[i*2])
		if err != nil {
			return nil, err
		}
		lo, err := interopHexNibble(hex[i*2+1])
		if err != nil {
			return nil, err
		}
		out[i] = (hi << 4) | lo
	}
	return out, nil
}

func interopHexNibble(ch byte) (byte, error) {
	switch {
	case ch >= '0' && ch <= '9':
		return ch - '0', nil
	case ch >= 'a' && ch <= 'f':
		return ch - 'a' + 10, nil
	case ch >= 'A' && ch <= 'F':
		return ch - 'A' + 10, nil
	default:
		return 0, fmt.Errorf("invalid hex")
	}
}
