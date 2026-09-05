#!/usr/bin/env python3
"""Decode wire fixtures emitted by Rust for Python client interop checks."""

from __future__ import annotations

import sys

from twilic import (
    MessageKind,
    ValueKind,
    entry,
    equal,
    new_array,
    new_i64,
    new_map,
    new_string,
    new_twilic_codec,
    new_u64,
)


def parse_frame_line(line: str) -> tuple[str, str, str]:
    parts = line.split("|", 2)
    if len(parts) != 3 or not parts[0] or not parts[1]:
        raise ValueError("invalid frame")
    return parts[0], parts[1], parts[2]


def decode_hex(hex_str: str) -> bytes:
    if len(hex_str) % 2 != 0:
        raise ValueError("invalid hex length")
    return bytes.fromhex(hex_str)


def make_i64_array(length: int, start: int):
    return [new_i64(start + i) for i in range(length)]


def codec_value(label: str):
    if label == "scalar_string":
        return new_string("alpha"), True
    if label.startswith("map_two_fields_"):
        return (
            new_map(
                entry("id", new_u64(1)),
                entry("name", new_string("alice")),
            ),
            True,
        )
    if label.startswith("map_three_fields_"):
        return (
            new_map(
                entry("id", new_u64(1)),
                entry("name", new_string("alice")),
                entry("role", new_string("admin")),
            ),
            True,
        )
    if label.startswith("bulk_map_"):
        idx = int(label.removeprefix("bulk_map_"))
        return (
            new_map(
                entry("id", new_u64(10 + idx)),
                entry("name", new_string(f"user-{idx}")),
            ),
            True,
        )
    return None, False


def assert_codec(label: str, codec, frame: bytes) -> None:
    if label == "base_snapshot":
        msg = codec.decode_message(frame)
        if msg.kind != MessageKind.BASE_SNAPSHOT or msg.base_snapshot is None:
            raise ValueError("expected base snapshot")
        if msg.base_snapshot.base_id != 77:
            raise ValueError("base_id mismatch")
        payload = msg.base_snapshot.payload
        if (
            payload.kind != MessageKind.SCALAR
            or payload.scalar is None
            or payload.scalar.kind != ValueKind.I64
            or payload.scalar.i64 != 42
        ):
            raise ValueError("payload mismatch")
        return

    if label in ("control_stream_bitpack", "control_stream_huffman", "control_stream_fse"):
        msg = codec.decode_message(frame)
        if msg.kind != MessageKind.CONTROL_STREAM or msg.control_stream is None:
            raise ValueError("expected control stream")
        if not msg.control_stream.payload:
            raise ValueError("control payload empty")
        return

    want, ok = codec_value(label)
    if not ok:
        raise ValueError(f"no expectation for {label!r}")
    got = codec.decode_value(frame)
    if not equal(got, want):
        raise ValueError("decoded value mismatch")


def assert_session(label: str, codec, frame: bytes) -> None:
    if label == "session_base_array":
        got = codec.decode_value(frame)
        want = new_array(make_i64_array(100, 0))
        if not equal(got, want):
            raise ValueError("session_base_array value mismatch")
        return

    msg = codec.decode_message(frame)
    if label == "session_patch_one_change":
        if msg.kind != MessageKind.STATE_PATCH or msg.state_patch is None:
            raise ValueError("expected state patch from Rust encoder")
        return

    if label == "session_patch_many_changes":
        if msg.kind not in (
            MessageKind.STATE_PATCH,
            MessageKind.TYPED_VECTOR,
            MessageKind.ARRAY,
        ):
            raise ValueError("expected patch or array message")
        return

    if label.startswith("session_patch_iter_"):
        if msg.kind not in (
            MessageKind.STATE_PATCH,
            MessageKind.TYPED_VECTOR,
            MessageKind.ARRAY,
        ):
            raise ValueError("expected patch or array message")
        return

    if label in ("session_micro_batch_first", "session_micro_batch_second"):
        if (
            msg.kind != MessageKind.TEMPLATE_BATCH
            or msg.template_batch is None
            or msg.template_batch.count != 4
        ):
            raise ValueError("expected template batch with 4 rows")
        return

    raise ValueError(f"no session expectation for {label!r}")


def assert_decoded(stream: str, label: str, codec, frame: bytes) -> None:
    if stream == "codec":
        assert_codec(label, codec, frame)
    elif stream == "session":
        assert_session(label, codec, frame)
    else:
        raise ValueError(f"unknown stream {stream!r}")


def run(input_lines) -> None:
    codec_stream = new_twilic_codec()
    session_stream = new_twilic_codec()
    decoded = 0

    for line_no, raw_line in enumerate(input_lines, start=1):
        line = raw_line.strip()
        if not line:
            continue

        stream, label, hex_str = parse_frame_line(line)
        try:
            frame = decode_hex(hex_str)
        except ValueError as exc:
            raise ValueError(f"line {line_no} ({label}): {exc}") from exc

        decoder = codec_stream if stream == "codec" else session_stream
        if stream not in ("codec", "session"):
            raise ValueError(f"line {line_no}: unknown stream {stream!r}")

        try:
            assert_decoded(stream, label, decoder, frame)
        except ValueError as exc:
            raise ValueError(f"line {line_no} ({label}): {exc}") from exc

        decoded += 1

    if decoded == 0:
        raise ValueError("no fixture frames found")

    print(f"Python client decode and value checks passed for {decoded} Rust frames")


def main() -> None:
    try:
        run(sys.stdin)
    except Exception as exc:  # noqa: BLE001
        print(f"decode fixtures: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
