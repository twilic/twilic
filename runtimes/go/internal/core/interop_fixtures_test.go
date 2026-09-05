package core

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestInteropFixtures_CodecEncodeDecodeRoundtrip(t *testing.T) {
	var buf bytes.Buffer
	if err := EmitInteropFixtures(&buf); err != nil {
		t.Fatalf("emit fixtures: %v", err)
	}
	frames, err := ParseInteropFrames(buf.String())
	if err != nil {
		t.Fatalf("parse fixtures: %v", err)
	}

	codec := NewTwilicCodec()
	for _, frame := range frames {
		if frame.Stream != "codec" {
			continue
		}
		if err := assertInteropCodecDecode(codec, frame.Label, frame.Bytes); err != nil {
			t.Fatalf("%s: %v", frame.Label, err)
		}

		if _, ok := interopExpectCodecValue(frame.Label); ok {
			iso := replayCodecState(t, frames, frame.Label)
			got, err := iso.DecodeValue(frame.Bytes)
			if err != nil {
				t.Fatalf("%s: value decode failed: %v", frame.Label, err)
			}
			v := got
			reencoded, err := iso.EncodeValue(&v)
			if err != nil {
				t.Fatalf("%s: re-encode failed: %v", frame.Label, err)
			}
			roundtrip, err := iso.DecodeValue(reencoded)
			if err != nil {
				t.Fatalf("%s: roundtrip decode failed: %v", frame.Label, err)
			}
			if !Equal(roundtrip, got) {
				t.Fatalf("%s: roundtrip value mismatch", frame.Label)
			}
		}
	}
}

func TestInteropFixtures_SessionEncodeDecodeRoundtrip(t *testing.T) {
	var buf bytes.Buffer
	if err := EmitInteropFixtures(&buf); err != nil {
		t.Fatalf("emit fixtures: %v", err)
	}
	frames, err := ParseInteropFrames(buf.String())
	if err != nil {
		t.Fatalf("parse fixtures: %v", err)
	}

	codec := NewTwilicCodec()
	for _, frame := range frames {
		if frame.Stream != "session" {
			continue
		}
		if err := assertInteropSessionDecode(codec, frame.Label, frame.Bytes); err != nil {
			t.Fatalf("%s: %v", frame.Label, err)
		}
	}
}

func TestInteropFixtures_DecodeRustServerFrames(t *testing.T) {
	root := interopModuleRoot(t)
	interopRequireTwilicRust(t, root)
	rustManifest := filepath.Join(root, "scripts", "rust-server-fixtures", "Cargo.toml")
	if _, err := os.Stat(rustManifest); err != nil {
		t.Skipf("rust fixtures not available: %v", err)
	}

	cmd := exec.Command("cargo", "run", "--quiet", "--manifest-path", rustManifest)
	cmd.Dir = root
	rustOut, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			t.Fatalf("rust emit failed: %s", strings.TrimSpace(string(ee.Stderr)))
		}
		t.Fatalf("rust emit failed: %v", err)
	}
	frames, err := ParseInteropFrames(string(rustOut))
	if err != nil {
		t.Fatalf("parse rust fixtures: %v", err)
	}

	codecStream := NewTwilicCodec()
	sessionStream := NewTwilicCodec()
	for _, frame := range frames {
		decoder := codecStream
		if frame.Stream == "session" {
			decoder = sessionStream
		} else if frame.Stream != "codec" {
			t.Fatalf("unknown stream %q", frame.Stream)
		}
		switch frame.Stream {
		case "codec":
			if err := assertInteropCodecDecode(decoder, frame.Label, frame.Bytes); err != nil {
				t.Fatalf("%s: %v", frame.Label, err)
			}
		case "session":
			if err := assertInteropSessionDecode(decoder, frame.Label, frame.Bytes); err != nil {
				t.Fatalf("%s: %v", frame.Label, err)
			}
		}
	}
}

func TestInteropFixtures_RustDecodesGoFramesWithSameValues(t *testing.T) {
	root := interopModuleRoot(t)
	interopRequireTwilicRust(t, root)
	rustCheck := filepath.Join(root, "scripts", "rust-client-check", "Cargo.toml")
	if _, err := os.Stat(rustCheck); err != nil {
		t.Skipf("rust client check not available: %v", err)
	}

	var goBuf bytes.Buffer
	if err := EmitInteropFixtures(&goBuf); err != nil {
		t.Fatalf("emit go fixtures: %v", err)
	}

	cmd := exec.Command("cargo", "run", "--quiet", "--manifest-path", rustCheck)
	cmd.Dir = root
	cmd.Stdin = &goBuf
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("rust client check failed: %v\n%s", err, strings.TrimSpace(string(out)))
	}
	if !strings.Contains(string(out), "value checks passed for") {
		t.Fatalf("unexpected rust output: %s", strings.TrimSpace(string(out)))
	}
}

func replayCodecState(t *testing.T, frames []InteropFrame, stopLabel string) *TwilicCodec {
	t.Helper()
	iso := NewTwilicCodec()
	for _, prior := range frames {
		if prior.Stream != "codec" {
			continue
		}
		if prior.Label == stopLabel {
			break
		}
		if _, ok := interopExpectControlPayload(prior.Label); ok || prior.Label == "base_snapshot" {
			if _, err := iso.DecodeMessage(prior.Bytes); err != nil {
				t.Fatalf("replay %s: %v", prior.Label, err)
			}
			continue
		}
		if _, ok := interopExpectCodecValue(prior.Label); ok {
			if _, err := iso.DecodeValue(prior.Bytes); err != nil {
				t.Fatalf("replay %s: %v", prior.Label, err)
			}
		}
	}
	return iso
}

func interopFramesByLabel(frames []InteropFrame) map[string]InteropFrame {
	out := make(map[string]InteropFrame, len(frames))
	for _, frame := range frames {
		out[frame.Label] = frame
	}
	return out
}

func interopModuleRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not find module root")
		}
		dir = parent
	}
}

func interopRequireTwilicRust(t *testing.T, moduleRoot string) {
	t.Helper()
	if _, err := exec.LookPath("cargo"); err != nil {
		t.Skip("cargo not found in PATH")
	}
	candidates := []string{
		filepath.Join(moduleRoot, "..", "rust"),
	}
	if env := os.Getenv("TWILIC_RUST_ROOT"); env != "" {
		candidates = append([]string{env}, candidates...)
	}
	for _, root := range candidates {
		if _, err := os.Stat(filepath.Join(root, "Cargo.toml")); err == nil {
			return
		}
	}
	t.Skip("Rust runtime not found (expected ../rust or TWILIC_RUST_ROOT)")
}
