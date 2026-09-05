package main

import (
	"fmt"
	"os"

	twilic "github.com/twilic/twilic-go"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "emit fixtures: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	codec := twilic.NewTwilicCodec()

	alpha := twilic.NewString("alpha")
	if err := emitEncodedValue(os.Stdout, "codec", "scalar_string", codec, &alpha); err != nil {
		return err
	}

	mapSmall := twilic.NewMap(
		twilic.Entry("id", twilic.NewU64(1)),
		twilic.Entry("name", twilic.NewString("alice")),
	)
	if err := emitEncodedValue(os.Stdout, "codec", "map_two_fields_first", codec, &mapSmall); err != nil {
		return err
	}
	twilic.ResetEncodeShapeObservation(codec, []string{"id", "name"})
	if err := emitEncodedValue(os.Stdout, "codec", "map_two_fields_second", codec, &mapSmall); err != nil {
		return err
	}

	mapShape := twilic.NewMap(
		twilic.Entry("id", twilic.NewU64(1)),
		twilic.Entry("name", twilic.NewString("alice")),
		twilic.Entry("role", twilic.NewString("admin")),
	)
	if err := emitEncodedValue(os.Stdout, "codec", "map_three_fields_first", codec, &mapShape); err != nil {
		return err
	}
	twilic.ResetEncodeShapeObservation(codec, []string{"id", "name", "role"})
	if err := emitEncodedValue(os.Stdout, "codec", "map_three_fields_second", codec, &mapShape); err != nil {
		return err
	}

	for i := 0; i < 8; i++ {
		dynamic := twilic.NewMap(
			twilic.Entry("id", twilic.NewU64(uint64(10+i))),
			twilic.Entry("name", twilic.NewString(fmt.Sprintf("user-%d", i))),
		)
		label := fmt.Sprintf("bulk_map_%d", i)
		if err := emitEncodedValue(os.Stdout, "codec", label, codec, &dynamic); err != nil {
			return err
		}
	}

	scalar := twilic.NewI64(42)
	baseSnapshot := twilic.Message{
		Kind: twilic.MessageKindBaseSnapshot,
		BaseSnapshot: &twilic.BaseSnapshotMessage{
			BaseID:           77,
			SchemaOrShapeRef: 0,
			Payload:          twilic.Message{Kind: twilic.MessageKindScalar, Scalar: &scalar},
		},
	}
	if err := emitEncodedMessage(os.Stdout, "codec", "base_snapshot", codec, &baseSnapshot); err != nil {
		return err
	}

	enc := twilic.NewSessionEncoder(twilic.DefaultSessionOptions())

	baseArray := twilic.NewArray(makeI64Array(100, 0))
	baseBytes, err := enc.Encode(&baseArray)
	if err != nil {
		return err
	}
	if err := emitFrame(os.Stdout, "session", "session_base_array", baseBytes); err != nil {
		return err
	}

	oneChangeArr := makeI64Array(100, 0)
	oneChangeArr[0] = twilic.NewI64(10_000)
	oneChange := twilic.NewArray(oneChangeArr)
	onePatch, err := enc.EncodePatch(&oneChange)
	if err != nil {
		return err
	}
	if err := emitFrame(os.Stdout, "session", "session_patch_one_change", onePatch); err != nil {
		return err
	}

	for step := 0; step < 4; step++ {
		iterArr := makeI64Array(100, 0)
		iterArr[step] = twilic.NewI64(int64(20_000 + step))
		iterative := twilic.NewArray(iterArr)
		bytes, err := enc.EncodePatch(&iterative)
		if err != nil {
			return err
		}
		label := fmt.Sprintf("session_patch_iter_%d", step)
		if err := emitFrame(os.Stdout, "session", label, bytes); err != nil {
			return err
		}
	}

	manyArr := makeI64Array(100, 0)
	for idx := 0; idx < 12; idx++ {
		manyArr[idx] = twilic.NewI64(int64(10_000 + idx))
	}
	manyChange := twilic.NewArray(manyArr)
	manyPatch, err := enc.EncodePatch(&manyChange)
	if err != nil {
		return err
	}
	if err := emitFrame(os.Stdout, "session", "session_patch_many_changes", manyPatch); err != nil {
		return err
	}

	rows1 := makeUserRows([]string{"a", "b", "c", "d"})
	microFirst, err := enc.EncodeMicroBatch(rows1)
	if err != nil {
		return err
	}
	if err := emitFrame(os.Stdout, "session", "session_micro_batch_first", microFirst); err != nil {
		return err
	}

	rows2 := makeUserRows([]string{"aa", "bb", "cc", "dd"})
	microSecond, err := enc.EncodeMicroBatch(rows2)
	if err != nil {
		return err
	}
	return emitFrame(os.Stdout, "session", "session_micro_batch_second", microSecond)
}

func emitEncodedValue(w interface{ Write([]byte) (int, error) }, stream, label string, codec *twilic.TwilicCodec, value *twilic.Value) error {
	bytes, err := codec.EncodeValue(value)
	if err != nil {
		return err
	}
	return emitFrame(w, stream, label, bytes)
}

func emitEncodedMessage(w interface{ Write([]byte) (int, error) }, stream, label string, codec *twilic.TwilicCodec, message *twilic.Message) error {
	bytes, err := codec.EncodeMessage(message)
	if err != nil {
		return err
	}
	return emitFrame(w, stream, label, bytes)
}

func emitControlStream(w interface{ Write([]byte) (int, error) }, stream, label string, codec *twilic.TwilicCodec, streamCodec twilic.ControlStreamCodec, payload []byte) error {
	msg := twilic.Message{
		Kind: twilic.MessageKindControlStream,
		ControlStream: &twilic.ControlStreamMessage{
			Codec:   streamCodec,
			Payload: append([]byte(nil), payload...),
		},
	}
	return emitEncodedMessage(w, stream, label, codec, &msg)
}

func emitFrame(w interface{ Write([]byte) (int, error) }, stream, label string, bytes []byte) error {
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

func makeI64Array(length int, start int64) []twilic.Value {
	out := make([]twilic.Value, length)
	for i := range out {
		out[i] = twilic.NewI64(start + int64(i))
	}
	return out
}

func bitpackControlPayload() []byte {
	out := make([]byte, 512)
	for i := range out {
		out[i] = byte(i % 2)
	}
	return out
}

func huffmanControlPayload() []byte {
	out := make([]byte, 512)
	for i := range out {
		out[i] = 7
	}
	return out
}

func fseControlPayload() []byte {
	out := make([]byte, 512)
	for i := range out {
		out[i] = byte(i % 4)
	}
	return out
}

func makeUserRows(names []string) []twilic.Value {
	rows := make([]twilic.Value, len(names))
	for i, name := range names {
		rows[i] = twilic.NewMap(
			twilic.Entry("id", twilic.NewU64(uint64(i+1))),
			twilic.Entry("name", twilic.NewString(name)),
		)
	}
	return rows
}
