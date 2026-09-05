package core

import (
	"fmt"
	"strings"
)

func interopExpectCodecValue(label string) (Value, bool) {
	switch label {
	case "scalar_string":
		return NewString("alpha"), true
	default:
		if strings.HasPrefix(label, "map_two_fields_") {
			return interopIDNameMap(1, "alice"), true
		}
		if strings.HasPrefix(label, "map_three_fields_") {
			return interopIDNameRoleMap(1, "alice", "admin"), true
		}
		if strings.HasPrefix(label, "bulk_map_") {
			var idx int
			if _, err := fmt.Sscanf(label, "bulk_map_%d", &idx); err != nil {
				return Value{}, false
			}
			return interopIDNameMap(uint64(10+idx), fmt.Sprintf("user-%d", idx)), true
		}
		return Value{}, false
	}
}

func interopExpectControlStreamCodec(label string) (ControlStreamCodec, bool) {
	switch label {
	case "control_stream_bitpack":
		return ControlStreamCodecBitpack, true
	case "control_stream_huffman":
		return ControlStreamCodecHuffman, true
	case "control_stream_fse":
		return ControlStreamCodecFse, true
	default:
		return 0, false
	}
}

func interopExpectControlPayload(label string) ([]byte, bool) {
	switch label {
	case "control_stream_bitpack":
		return interopBitpackControlPayload(), true
	case "control_stream_huffman":
		return interopHuffmanControlPayload(), true
	case "control_stream_fse":
		return interopFSEControlPayload(), true
	default:
		return nil, false
	}
}

func assertInteropCodecDecode(codec *TwilicCodec, label string, frame []byte) error {
	switch label {
	case "base_snapshot":
		msg, err := codec.DecodeMessage(frame)
		if err != nil {
			return err
		}
		if msg.Kind != MessageKindBaseSnapshot || msg.BaseSnapshot == nil {
			return fmt.Errorf("expected base snapshot message")
		}
		if msg.BaseSnapshot.BaseID != 77 {
			return fmt.Errorf("base_id: got %d want 77", msg.BaseSnapshot.BaseID)
		}
		payload := msg.BaseSnapshot.Payload
		if payload.Kind != MessageKindScalar || payload.Scalar == nil || payload.Scalar.Kind != ValueI64 || payload.Scalar.I64 != 42 {
			return fmt.Errorf("base snapshot payload mismatch")
		}
		return nil
	}

	if _, ok := interopExpectControlPayload(label); ok {
		msg, err := codec.DecodeMessage(frame)
		if err != nil {
			return err
		}
		if msg.Kind != MessageKindControlStream || msg.ControlStream == nil {
			return fmt.Errorf("expected control stream message")
		}
		if len(msg.ControlStream.Payload) == 0 {
			return fmt.Errorf("control stream payload empty for %s", label)
		}
		wantCodec, ok := interopExpectControlStreamCodec(label)
		if ok && msg.ControlStream.Codec != wantCodec {
			return fmt.Errorf("control stream codec mismatch for %s", label)
		}
		return nil
	}

	expected, ok := interopExpectCodecValue(label)
	if !ok {
		return fmt.Errorf("no codec expectation for label %q", label)
	}
	got, err := codec.DecodeValue(frame)
	if err != nil {
		return err
	}
	if !Equal(got, expected) {
		return fmt.Errorf("decoded value mismatch for %s", label)
	}
	return nil
}

func assertInteropSessionDecode(codec *TwilicCodec, label string, frame []byte) error {
	switch label {
	case "session_base_array":
		got, err := codec.DecodeValue(frame)
		if err != nil {
			return err
		}
		want := NewArray(interopMakeI64Array(100, 0))
		if !Equal(got, want) {
			return fmt.Errorf("session_base_array value mismatch")
		}
		return nil
	case "session_patch_one_change":
		msg, err := codec.DecodeMessage(frame)
		if err != nil {
			return err
		}
		wantArr := interopMakeI64Array(100, 0)
		wantArr[0] = NewI64(10_000)
		want := NewArray(wantArr)
		switch msg.Kind {
		case MessageKindStatePatch:
			return nil
		case MessageKindTypedVector:
			if msg.TypedVector == nil {
				return fmt.Errorf("session_patch_one_change: missing typed vector")
			}
			got := typedVectorToValue(*msg.TypedVector)
			if !Equal(got, want) {
				return fmt.Errorf("session_patch_one_change typed vector mismatch")
			}
			return nil
		case MessageKindArray:
			got := NewArray(msg.Array)
			if !Equal(got, want) {
				return fmt.Errorf("session_patch_one_change array mismatch")
			}
			return nil
		default:
			return fmt.Errorf("session_patch_one_change: unexpected kind %v", msg.Kind)
		}
	case "session_patch_many_changes", "session_micro_batch_first", "session_micro_batch_second":
		msg, err := codec.DecodeMessage(frame)
		if err != nil {
			return err
		}
		switch label {
		case "session_patch_many_changes":
			if msg.Kind != MessageKindStatePatch && msg.Kind != MessageKindTypedVector && msg.Kind != MessageKindArray {
				return fmt.Errorf("expected patch or array message, got %v", msg.Kind)
			}
		case "session_micro_batch_first", "session_micro_batch_second":
			if msg.Kind != MessageKindTemplateBatch || msg.TemplateBatch == nil {
				return fmt.Errorf("expected template batch message, got %v", msg.Kind)
			}
			if msg.TemplateBatch.Count != 4 {
				return fmt.Errorf("expected 4 rows, got %d", msg.TemplateBatch.Count)
			}
		}
		return nil
	default:
		if strings.HasPrefix(label, "session_patch_iter_") {
			msg, err := codec.DecodeMessage(frame)
			if err != nil {
				return err
			}
			if msg.Kind != MessageKindStatePatch && msg.Kind != MessageKindTypedVector && msg.Kind != MessageKindArray {
				return fmt.Errorf("%s: expected patch or array message, got %v", label, msg.Kind)
			}
			return nil
		}
		return fmt.Errorf("no session expectation for label %q", label)
	}
}
