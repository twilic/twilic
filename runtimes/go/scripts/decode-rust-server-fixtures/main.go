package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	twilic "github.com/twilic/twilic-go"
)

func main() {
	if err := run(os.Stdin); err != nil {
		fmt.Fprintf(os.Stderr, "decode fixtures: %v\n", err)
		os.Exit(1)
	}
}

func run(input io.Reader) error {
	codecStream := twilic.NewTwilicCodec()
	sessionStream := twilic.NewTwilicCodec()

	scanner := bufio.NewScanner(input)
	decoded := 0
	for lineNo := 0; scanner.Scan(); lineNo++ {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		stream, label, hex, err := parseFrameLine(line)
		if err != nil {
			return fmt.Errorf("line %d: %w", lineNo+1, err)
		}
		bytes, err := decodeHex(hex)
		if err != nil {
			return fmt.Errorf("line %d (%s): %w", lineNo+1, label, err)
		}
		var decoder *twilic.TwilicCodec
		switch stream {
		case "codec":
			decoder = codecStream
		case "session":
			decoder = sessionStream
		default:
			return fmt.Errorf("line %d: unknown stream %q", lineNo+1, stream)
		}
		if err := assertDecoded(stream, label, decoder, bytes); err != nil {
			return fmt.Errorf("line %d (%s): %w", lineNo+1, label, err)
		}
		decoded++
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if decoded == 0 {
		return fmt.Errorf("no fixture frames found")
	}
	fmt.Printf("Go client decode and value checks passed for %d Rust frames\n", decoded)
	return nil
}

func assertDecoded(stream, label string, codec *twilic.TwilicCodec, frame []byte) error {
	switch stream {
	case "codec":
		return assertCodec(label, codec, frame)
	case "session":
		return assertSession(label, codec, frame)
	default:
		return fmt.Errorf("unknown stream %q", stream)
	}
}

func assertCodec(label string, codec *twilic.TwilicCodec, frame []byte) error {
	switch label {
	case "base_snapshot":
		msg, err := codec.DecodeMessage(frame)
		if err != nil {
			return err
		}
		if msg.Kind != twilic.MessageKindBaseSnapshot || msg.BaseSnapshot == nil {
			return fmt.Errorf("expected base snapshot")
		}
		if msg.BaseSnapshot.BaseID != 77 {
			return fmt.Errorf("base_id mismatch")
		}
		payload := msg.BaseSnapshot.Payload
		if payload.Kind != twilic.MessageKindScalar || payload.Scalar == nil || payload.Scalar.Kind != twilic.ValueI64 || payload.Scalar.I64 != 42 {
			return fmt.Errorf("payload mismatch")
		}
		return nil
	case "control_stream_bitpack", "control_stream_huffman", "control_stream_fse":
		msg, err := codec.DecodeMessage(frame)
		if err != nil {
			return err
		}
		if msg.Kind != twilic.MessageKindControlStream || msg.ControlStream == nil {
			return fmt.Errorf("expected control stream")
		}
		if len(msg.ControlStream.Payload) == 0 {
			return fmt.Errorf("control payload empty")
		}
		return nil
	}

	want, ok := codecValue(label)
	if !ok {
		return fmt.Errorf("no expectation for %q", label)
	}
	got, err := codec.DecodeValue(frame)
	if err != nil {
		return err
	}
	if !twilic.Equal(got, want) {
		return fmt.Errorf("decoded value mismatch")
	}
	return nil
}

func assertSession(label string, codec *twilic.TwilicCodec, frame []byte) error {
	switch label {
	case "session_base_array":
		got, err := codec.DecodeValue(frame)
		if err != nil {
			return err
		}
		want := twilic.NewArray(makeI64Array(100, 0))
		if !twilic.Equal(got, want) {
			return fmt.Errorf("session_base_array value mismatch")
		}
		return nil
	}

	msg, err := codec.DecodeMessage(frame)
	if err != nil {
		return err
	}
	switch label {
	case "session_patch_one_change":
		if msg.Kind != twilic.MessageKindStatePatch || msg.StatePatch == nil {
			return fmt.Errorf("expected state patch from Rust encoder")
		}
		return nil
	case "session_patch_many_changes":
		if msg.Kind != twilic.MessageKindStatePatch && msg.Kind != twilic.MessageKindTypedVector && msg.Kind != twilic.MessageKindArray {
			return fmt.Errorf("expected patch or array message")
		}
		return nil
	default:
		if strings.HasPrefix(label, "session_patch_iter_") {
			if msg.Kind != twilic.MessageKindStatePatch && msg.Kind != twilic.MessageKindTypedVector && msg.Kind != twilic.MessageKindArray {
				return fmt.Errorf("expected patch or array message")
			}
			return nil
		}
		if label == "session_micro_batch_first" || label == "session_micro_batch_second" {
			if msg.Kind != twilic.MessageKindTemplateBatch || msg.TemplateBatch == nil || msg.TemplateBatch.Count != 4 {
				return fmt.Errorf("expected template batch with 4 rows")
			}
			return nil
		}
		return fmt.Errorf("no session expectation for %q", label)
	}
}

func makeI64Array(length int, start int64) []twilic.Value {
	out := make([]twilic.Value, length)
	for i := range out {
		out[i] = twilic.NewI64(start + int64(i))
	}
	return out
}

func codecValue(label string) (twilic.Value, bool) {
	switch label {
	case "scalar_string":
		return twilic.NewString("alpha"), true
	default:
		if strings.HasPrefix(label, "map_two_fields_") {
			return twilic.NewMap(twilic.Entry("id", twilic.NewU64(1)), twilic.Entry("name", twilic.NewString("alice"))), true
		}
		if strings.HasPrefix(label, "map_three_fields_") {
			return twilic.NewMap(
				twilic.Entry("id", twilic.NewU64(1)),
				twilic.Entry("name", twilic.NewString("alice")),
				twilic.Entry("role", twilic.NewString("admin")),
			), true
		}
		if strings.HasPrefix(label, "bulk_map_") {
			var idx int
			if _, err := fmt.Sscanf(label, "bulk_map_%d", &idx); err != nil {
				return twilic.Value{}, false
			}
			return twilic.NewMap(
				twilic.Entry("id", twilic.NewU64(uint64(10+idx))),
				twilic.Entry("name", twilic.NewString(fmt.Sprintf("user-%d", idx))),
			), true
		}
		return twilic.Value{}, false
	}
}

func controlPayload(label string) ([]byte, bool) {
	switch label {
	case "control_stream_bitpack":
		out := make([]byte, 512)
		for i := range out {
			out[i] = byte(i % 2)
		}
		return out, true
	case "control_stream_huffman":
		out := make([]byte, 512)
		for i := range out {
			out[i] = 7
		}
		return out, true
	case "control_stream_fse":
		out := make([]byte, 512)
		for i := range out {
			out[i] = byte(i % 4)
		}
		return out, true
	default:
		return nil, false
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

func parseFrameLine(line string) (stream, label, hex string, err error) {
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

func decodeHex(hex string) ([]byte, error) {
	if len(hex)%2 != 0 {
		return nil, fmt.Errorf("invalid hex length")
	}
	out := make([]byte, len(hex)/2)
	for i := 0; i < len(out); i++ {
		hi, err := hexNibble(hex[i*2])
		if err != nil {
			return nil, err
		}
		lo, err := hexNibble(hex[i*2+1])
		if err != nil {
			return nil, err
		}
		out[i] = (hi << 4) | lo
	}
	return out, nil
}

func hexNibble(ch byte) (byte, error) {
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
