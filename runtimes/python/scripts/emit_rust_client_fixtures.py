#!/usr/bin/env python3
"""Emit wire fixtures encoded by Python for Rust client interop checks."""

from __future__ import annotations

import sys

from twilic import (
    BaseSnapshotMessage,
    Message,
    MessageKind,
    default_session_options,
    entry,
    new_array,
    new_i64,
    new_map,
    new_session_encoder,
    new_string,
    new_twilic_codec,
    new_u64,
    reset_encode_shape_observation,
)


def emit_frame(stream: str, label: str, data: bytes) -> None:
    hex_chars = data.hex()
    sys.stdout.write(f"{stream}|{label}|{hex_chars}\n")


def emit_encoded_value(stream: str, label: str, codec, value) -> None:
    emit_frame(stream, label, codec.encode_value(value))


def emit_encoded_message(stream: str, label: str, codec, message: Message) -> None:
    emit_frame(stream, label, codec.encode_message(message))


def make_i64_array(length: int, start: int) -> list:
    return [new_i64(start + i) for i in range(length)]


def make_user_rows(names: list[str]) -> list:
    return [
        new_map(
            entry("id", new_u64(i + 1)),
            entry("name", new_string(name)),
        )
        for i, name in enumerate(names)
    ]


def run() -> None:
    codec = new_twilic_codec()

    alpha = new_string("alpha")
    emit_encoded_value("codec", "scalar_string", codec, alpha)

    map_small = new_map(
        entry("id", new_u64(1)),
        entry("name", new_string("alice")),
    )
    emit_encoded_value("codec", "map_two_fields_first", codec, map_small)
    reset_encode_shape_observation(codec, ["id", "name"])
    emit_encoded_value("codec", "map_two_fields_second", codec, map_small)

    map_shape = new_map(
        entry("id", new_u64(1)),
        entry("name", new_string("alice")),
        entry("role", new_string("admin")),
    )
    emit_encoded_value("codec", "map_three_fields_first", codec, map_shape)
    reset_encode_shape_observation(codec, ["id", "name", "role"])
    emit_encoded_value("codec", "map_three_fields_second", codec, map_shape)

    for i in range(8):
        dynamic = new_map(
            entry("id", new_u64(10 + i)),
            entry("name", new_string(f"user-{i}")),
        )
        emit_encoded_value("codec", f"bulk_map_{i}", codec, dynamic)

    scalar = new_i64(42)
    base_snapshot = Message(
        kind=MessageKind.BASE_SNAPSHOT,
        base_snapshot=BaseSnapshotMessage(
            base_id=77,
            schema_or_shape_ref=0,
            payload=Message(kind=MessageKind.SCALAR, scalar=scalar),
        ),
    )
    emit_encoded_message("codec", "base_snapshot", codec, base_snapshot)

    enc = new_session_encoder(default_session_options())

    base_array = new_array(make_i64_array(100, 0))
    emit_frame("session", "session_base_array", enc.encode(base_array))

    one_change_arr = make_i64_array(100, 0)
    one_change_arr[0] = new_i64(10_000)
    one_change = new_array(one_change_arr)
    emit_frame("session", "session_patch_one_change", enc.encode_patch(one_change))

    for step in range(4):
        iter_arr = make_i64_array(100, 0)
        iter_arr[step] = new_i64(20_000 + step)
        iterative = new_array(iter_arr)
        emit_frame("session", f"session_patch_iter_{step}", enc.encode_patch(iterative))

    many_arr = make_i64_array(100, 0)
    for idx in range(12):
        many_arr[idx] = new_i64(10_000 + idx)
    many_change = new_array(many_arr)
    emit_frame("session", "session_patch_many_changes", enc.encode_patch(many_change))

    rows1 = make_user_rows(["a", "b", "c", "d"])
    emit_frame("session", "session_micro_batch_first", enc.encode_micro_batch(rows1))

    rows2 = make_user_rows(["aa", "bb", "cc", "dd"])
    emit_frame("session", "session_micro_batch_second", enc.encode_micro_batch(rows2))


def main() -> None:
    try:
        run()
    except Exception as exc:  # noqa: BLE001
        print(f"emit fixtures: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
