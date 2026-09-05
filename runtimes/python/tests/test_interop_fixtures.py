"""Port of twilic-go/internal/core/interop_fixtures_test.go."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from interop_helpers import (
    assert_interop_codec_decode,
    assert_interop_session_decode,
    emit_interop_fixtures,
    interop_expect_codec_value,
    interop_expect_control_payload,
    parse_interop_frames,
)
from twilic import equal, new_twilic_codec


def _replay_codec_state(frames, stop_label: str):
    iso = new_twilic_codec()
    for prior in frames:
        if prior.stream != "codec":
            continue
        if prior.label == stop_label:
            break
        if interop_expect_control_payload(prior.label)[1] or prior.label == "base_snapshot":
            iso.decode_message(prior.bytes)
            continue
        if interop_expect_codec_value(prior.label)[1]:
            iso.decode_value(prior.bytes)
    return iso


def _interop_module_root() -> Path:
    path = Path(__file__).resolve().parent.parent
    if (path / "pyproject.toml").is_file():
        return path
    raise RuntimeError("could not find module root")


def _interop_require_twilic_rust(module_root: Path) -> None:
    if shutil.which("cargo") is None:
        pytest.skip("cargo not found in PATH")
    candidates = [
        module_root.parent / "rust",
    ]
    env_root = os.environ.get("TWILIC_RUST_ROOT")
    if env_root:
        candidates.insert(0, Path(env_root))
    for root in candidates:
        if (root / "Cargo.toml").is_file():
            return
    pytest.skip("Rust runtime not found (expected ../rust or TWILIC_RUST_ROOT)")


def test_interop_fixtures_codec_encode_decode_roundtrip():
    fixture_text = emit_interop_fixtures()
    frames = parse_interop_frames(fixture_text)
    codec = new_twilic_codec()

    for frame in frames:
        if frame.stream != "codec":
            continue
        assert_interop_codec_decode(codec, frame.label, frame.bytes)

        if interop_expect_codec_value(frame.label)[1]:
            iso = _replay_codec_state(frames, frame.label)
            got = iso.decode_value(frame.bytes)
            reencoded = iso.encode_value(got)
            roundtrip = iso.decode_value(reencoded)
            assert equal(roundtrip, got), f"{frame.label}: roundtrip value mismatch"


def test_interop_fixtures_session_encode_decode_roundtrip():
    fixture_text = emit_interop_fixtures()
    frames = parse_interop_frames(fixture_text)
    codec = new_twilic_codec()

    for frame in frames:
        if frame.stream != "session":
            continue
        assert_interop_session_decode(codec, frame.label, frame.bytes)


def test_interop_fixtures_decode_rust_server_frames():
    root = _interop_module_root()
    _interop_require_twilic_rust(root)
    conformance_root = root.parent.parent / "conformance"
    rust_manifest = conformance_root / "rust-server-fixtures" / "Cargo.toml"
    if not rust_manifest.is_file():
        pytest.skip(f"rust fixtures not available: {rust_manifest}")

    result = subprocess.run(
        ["cargo", "run", "--quiet", "--manifest-path", str(rust_manifest)],
        cwd=conformance_root,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        pytest.fail(result.stderr.decode().strip() or "rust emit failed")

    frames = parse_interop_frames(result.stdout.decode())
    codec_stream = new_twilic_codec()
    session_stream = new_twilic_codec()
    for frame in frames:
        if frame.stream == "session":
            decoder = session_stream
        elif frame.stream == "codec":
            decoder = codec_stream
        else:
            pytest.fail(f"unknown stream {frame.stream!r}")

        if frame.stream == "codec":
            assert_interop_codec_decode(decoder, frame.label, frame.bytes)
        else:
            assert_interop_session_decode(decoder, frame.label, frame.bytes)


def test_interop_fixtures_rust_decodes_python_frames_with_same_values():
    root = _interop_module_root()
    _interop_require_twilic_rust(root)
    conformance_root = root.parent.parent / "conformance"
    rust_check = conformance_root / "rust-client-check" / "Cargo.toml"
    if not rust_check.is_file():
        pytest.skip(f"rust client check not available: {rust_check}")

    python_buf = emit_interop_fixtures()
    result = subprocess.run(
        ["cargo", "run", "--quiet", "--manifest-path", str(rust_check)],
        cwd=conformance_root,
        input=python_buf,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(f"rust client check failed: {result.stderr.strip() or result.stdout.strip()}")
    assert "value checks passed for" in result.stdout
