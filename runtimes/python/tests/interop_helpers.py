"""Interop fixture helpers ported from twilic-go interop_fixtures.go."""

from __future__ import annotations

import io
from dataclasses import dataclass

from twilic import (
    BaseSnapshotMessage,
    ControlStreamCodec,
    ControlStreamCodecBitpack,
    ControlStreamCodecFse,
    ControlStreamCodecHuffman,
    Message,
    MessageKind,
    Value,
    ValueKind,
    default_session_options,
    entry,
    equal,
    new_array,
    new_i64,
    new_map,
    new_session_encoder,
    new_string,
    new_twilic_codec,
    new_u64,
    reset_encode_shape_observation,
)
from twilic.protocol import typed_vector_to_value


@dataclass
class InteropFrame:
    stream: str
    label: str
    hex: str
    bytes: bytes


def interop_id_name_map(ref_id: int, name: str) -> Value:
    return new_map(entry("id", new_u64(ref_id)), entry("name", new_string(name)))


def interop_id_name_role_map(ref_id: int, name: str, role: str) -> Value:
    return new_map(
        entry("id", new_u64(ref_id)),
        entry("name", new_string(name)),
        entry("role", new_string(role)),
    )


def interop_make_i64_array(length: int, start: int) -> list[Value]:
    return [new_i64(start + i) for i in range(length)]


def interop_make_user_rows(names: list[str]) -> list[Value]:
    return [
        new_map(entry("id", new_u64(i + 1)), entry("name", new_string(name)))
        for i, name in enumerate(names)
    ]


def interop_bitpack_control_payload() -> bytes:
    return bytes(i % 2 for i in range(512))


def interop_huffman_control_payload() -> bytes:
    return bytes(7 for _ in range(512))


def interop_fse_control_payload() -> bytes:
    return bytes(i % 4 for i in range(512))


def emit_interop_fixtures() -> str:
    buf = io.StringIO()
    codec = new_twilic_codec()

    alpha = new_string("alpha")
    _emit_interop_value(buf, "codec", "scalar_string", codec, alpha)

    map_two = interop_id_name_map(1, "alice")
    _emit_interop_value(buf, "codec", "map_two_fields_first", codec, map_two)
    reset_encode_shape_observation(codec, ["id", "name"])
    _emit_interop_value(buf, "codec", "map_two_fields_second", codec, map_two)

    map_three = interop_id_name_role_map(1, "alice", "admin")
    _emit_interop_value(buf, "codec", "map_three_fields_first", codec, map_three)
    reset_encode_shape_observation(codec, ["id", "name", "role"])
    _emit_interop_value(buf, "codec", "map_three_fields_second", codec, map_three)

    for i in range(8):
        dynamic = interop_id_name_map(10 + i, f"user-{i}")
        _emit_interop_value(buf, "codec", f"bulk_map_{i}", codec, dynamic)

    scalar = new_i64(42)
    base_snapshot = Message(
        kind=MessageKind.BASE_SNAPSHOT,
        base_snapshot=BaseSnapshotMessage(
            base_id=77,
            schema_or_shape_ref=0,
            payload=Message(kind=MessageKind.SCALAR, scalar=scalar),
        ),
    )
    _emit_interop_message(buf, "codec", "base_snapshot", codec, base_snapshot)

    enc = new_session_encoder(default_session_options())
    base_array = new_array(interop_make_i64_array(100, 0))
    base_bytes = enc.encode(base_array)
    _emit_interop_frame(buf, "session", "session_base_array", base_bytes)

    one_change_arr = interop_make_i64_array(100, 0)
    one_change_arr[0] = new_i64(10_000)
    one_change = new_array(one_change_arr)
    one_patch = enc.encode_patch(one_change)
    _emit_interop_frame(buf, "session", "session_patch_one_change", one_patch)

    for step in range(4):
        iter_arr = interop_make_i64_array(100, 0)
        iter_arr[step] = new_i64(20_000 + step)
        iterative = new_array(iter_arr)
        patch_bytes = enc.encode_patch(iterative)
        _emit_interop_frame(buf, "session", f"session_patch_iter_{step}", patch_bytes)

    many_arr = interop_make_i64_array(100, 0)
    for idx in range(12):
        many_arr[idx] = new_i64(10_000 + idx)
    many_change = new_array(many_arr)
    many_patch = enc.encode_patch(many_change)
    _emit_interop_frame(buf, "session", "session_patch_many_changes", many_patch)

    rows1 = interop_make_user_rows(["a", "b", "c", "d"])
    micro_first = enc.encode_micro_batch(rows1)
    _emit_interop_frame(buf, "session", "session_micro_batch_first", micro_first)

    rows2 = interop_make_user_rows(["aa", "bb", "cc", "dd"])
    micro_second = enc.encode_micro_batch(rows2)
    _emit_interop_frame(buf, "session", "session_micro_batch_second", micro_second)

    return buf.getvalue()


def _emit_interop_value(buf: io.StringIO, stream: str, label: str, codec, value: Value) -> None:
    data = codec.encode_value(value)
    _emit_interop_frame(buf, stream, label, data)


def _emit_interop_message(
    buf: io.StringIO, stream: str, label: str, codec, message: Message
) -> None:
    data = codec.encode_message(message)
    _emit_interop_frame(buf, stream, label, data)


def _emit_interop_frame(buf: io.StringIO, stream: str, label: str, data: bytes) -> None:
    buf.write(f"{stream}|{label}|")
    buf.write(data.hex())
    buf.write("\n")


def parse_interop_frames(input_text: str) -> list[InteropFrame]:
    frames: list[InteropFrame] = []
    for line_no, raw_line in enumerate(input_text.split("\n")):
        line = raw_line.strip()
        if not line:
            continue
        stream, label, hex_str = _parse_interop_frame_line(line)
        try:
            frame_bytes = bytes.fromhex(hex_str)
        except ValueError as err:
            raise ValueError(f"line {line_no + 1} ({label}): {err}") from err
        frames.append(InteropFrame(stream=stream, label=label, hex=hex_str, bytes=frame_bytes))
    if not frames:
        raise ValueError("no fixture frames found")
    return frames


def _parse_interop_frame_line(line: str) -> tuple[str, str, str]:
    first = line.find("|")
    if first <= 0:
        raise ValueError("invalid frame")
    rest = line[first + 1 :]
    second = rest.find("|")
    if second <= 0:
        raise ValueError("invalid frame")
    return line[:first], rest[:second], rest[second + 1 :]


def interop_expect_codec_value(label: str) -> tuple[Value, bool]:
    if label == "scalar_string":
        return new_string("alpha"), True
    if label.startswith("map_two_fields_"):
        return interop_id_name_map(1, "alice"), True
    if label.startswith("map_three_fields_"):
        return interop_id_name_role_map(1, "alice", "admin"), True
    if label.startswith("bulk_map_"):
        idx = int(label.removeprefix("bulk_map_"))
        return interop_id_name_map(10 + idx, f"user-{idx}"), True
    return Value(), False


def interop_expect_control_stream_codec(label: str) -> tuple[ControlStreamCodec, bool]:
    match label:
        case "control_stream_bitpack":
            return ControlStreamCodecBitpack, True
        case "control_stream_huffman":
            return ControlStreamCodecHuffman, True
        case "control_stream_fse":
            return ControlStreamCodecFse, True
        case _:
            return ControlStreamCodec(0), False


def interop_expect_control_payload(label: str) -> tuple[bytes, bool]:
    match label:
        case "control_stream_bitpack":
            return interop_bitpack_control_payload(), True
        case "control_stream_huffman":
            return interop_huffman_control_payload(), True
        case "control_stream_fse":
            return interop_fse_control_payload(), True
        case _:
            return b"", False


def assert_interop_codec_decode(codec, label: str, frame: bytes) -> None:
    if label == "base_snapshot":
        msg = codec.decode_message(frame)
        if msg.kind != MessageKind.BASE_SNAPSHOT or msg.base_snapshot is None:
            raise ValueError("expected base snapshot message")
        if msg.base_snapshot.base_id != 77:
            raise ValueError(f"base_id: got {msg.base_snapshot.base_id} want 77")
        payload = msg.base_snapshot.payload
        if (
            payload.kind != MessageKind.SCALAR
            or payload.scalar is None
            or payload.scalar.kind != ValueKind.I64
            or payload.scalar.i64 != 42
        ):
            raise ValueError("base snapshot payload mismatch")
        return

    if interop_expect_control_payload(label)[1]:
        msg = codec.decode_message(frame)
        if msg.kind != MessageKind.CONTROL_STREAM or msg.control_stream is None:
            raise ValueError("expected control stream message")
        if len(msg.control_stream.payload) == 0:
            raise ValueError(f"control stream payload empty for {label}")
        want_codec, ok = interop_expect_control_stream_codec(label)
        if ok and msg.control_stream.codec != want_codec:
            raise ValueError(f"control stream codec mismatch for {label}")
        return

    expected, ok = interop_expect_codec_value(label)
    if not ok:
        raise ValueError(f"no codec expectation for label {label!r}")
    got = codec.decode_value(frame)
    if not equal(got, expected):
        raise ValueError(f"decoded value mismatch for {label}")


def assert_interop_session_decode(codec, label: str, frame: bytes) -> None:
    match label:
        case "session_base_array":
            got = codec.decode_value(frame)
            want = new_array(interop_make_i64_array(100, 0))
            if not equal(got, want):
                raise ValueError("session_base_array value mismatch")
        case "session_patch_one_change":
            msg = codec.decode_message(frame)
            want_arr = interop_make_i64_array(100, 0)
            want_arr[0] = new_i64(10_000)
            want = new_array(want_arr)
            match msg.kind:
                case MessageKind.STATE_PATCH:
                    return
                case MessageKind.TYPED_VECTOR:
                    if msg.typed_vector is None:
                        raise ValueError("session_patch_one_change: missing typed vector")
                    got = typed_vector_to_value(msg.typed_vector)
                    if not equal(got, want):
                        raise ValueError("session_patch_one_change typed vector mismatch")
                case MessageKind.ARRAY:
                    got = new_array(msg.array)
                    if not equal(got, want):
                        raise ValueError("session_patch_one_change array mismatch")
                case _:
                    raise ValueError(f"session_patch_one_change: unexpected kind {msg.kind}")
        case (
            "session_patch_many_changes"
            | "session_micro_batch_first"
            | "session_micro_batch_second"
        ):
            msg = codec.decode_message(frame)
            if label == "session_patch_many_changes":
                if msg.kind not in (
                    MessageKind.STATE_PATCH,
                    MessageKind.TYPED_VECTOR,
                    MessageKind.ARRAY,
                ):
                    raise ValueError(f"expected patch or array message, got {msg.kind}")
            elif msg.kind != MessageKind.TEMPLATE_BATCH or msg.template_batch is None:
                raise ValueError(f"expected template batch message, got {msg.kind}")
            elif msg.template_batch.count != 4:
                raise ValueError(f"expected 4 rows, got {msg.template_batch.count}")
        case _:
            if label.startswith("session_patch_iter_"):
                msg = codec.decode_message(frame)
                if msg.kind not in (
                    MessageKind.STATE_PATCH,
                    MessageKind.TYPED_VECTOR,
                    MessageKind.ARRAY,
                ):
                    raise ValueError(f"{label}: expected patch or array message, got {msg.kind}")
            else:
                raise ValueError(f"no session expectation for label {label!r}")
