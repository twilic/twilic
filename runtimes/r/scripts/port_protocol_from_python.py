#!/usr/bin/env python3
"""Port twilic-python protocol.py helpers + codec skeleton to R."""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python" / "src" / "twilic" / "protocol.py"
R_HELPERS = Path(__file__).resolve().parents[1] / "R" / "protocol_helpers.R"
R_PROTO = Path(__file__).resolve().parents[1] / "R" / "protocol.R"

HELPER_START = "def typed_vector_len"
CLASS_START = "class TwilicCodec:"
SESSION_START = "class SessionEncoder:"


def py_helpers_to_r(source: str) -> str:
    """Convert module-level helper functions (rough mechanical port)."""
    lines = source.splitlines()
    out: list[str] = [
        "# Ported from twilic-python protocol.py (module helpers)",
        "",
        "TAG_NULL <- 0L",
        "TAG_BOOL_FALSE <- 1L",
        "TAG_BOOL_TRUE <- 2L",
        "TAG_I64 <- 3L",
        "TAG_U64 <- 4L",
        "TAG_F64 <- 5L",
        "TAG_STRING <- 6L",
        "TAG_BINARY <- 7L",
        "TAG_ARRAY <- 8L",
        "TAG_MAP <- 9L",
        "",
    ]
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^def (\w+)\((.*)\)(?: -> .*)?:", line)
        if not m:
            i += 1
            continue
        name, args = m.group(1), m.group(2)
        if name in ("new_twilic_codec", "twilic_codec_with_options", "new_session_encoder", "reset_encode_shape_observation"):
            i += 1
            while i < len(lines) and (lines[i].startswith(" ") or lines[i].strip() == ""):
                i += 1
            continue
        body: list[str] = []
        i += 1
        while i < len(lines):
            if re.match(r"^def \w+\(", lines[i]) or lines[i].startswith("class "):
                break
            body.append(lines[i])
            i += 1
        out.extend(convert_function(name, args, body))
        out.append("")
    return "\n".join(out)


def convert_function(name: str, args: str, body: list[str]) -> list[str]:
    r_args = []
    for a in args.split(","):
        a = a.strip()
        if not a:
            continue
        a = re.sub(r":.*", "", a)
        a = re.sub(r"=.*", "", a).strip()
        if a in ("self", "codec", "state"):
            continue
        r_args.append(a)
    sig = ", ".join(r_args) if r_args else ""
    out = [f"{name} <- function({sig}) {{"]
    indent_body = convert_body(body)
    if not indent_body:
        out.append("  NULL")
    else:
        out.extend(indent_body)
    out.append("}")
    return out


def convert_body(body: list[str]) -> list[str]:
    result: list[str] = []
    for line in body:
        stripped = line.rstrip()
        if not stripped.strip():
            result.append("")
            continue
        if stripped.strip().startswith('"""') or stripped.strip().startswith("'''"):
            continue
        conv = convert_line(stripped)
        if conv is not None:
            result.append(conv)
    return result


def convert_line(line: str) -> str | None:
    indent = len(line) - len(line.lstrip())
    sp = " " * indent
    s = line.strip()
    if s.startswith("#"):
        return sp + s
    if s.startswith("from .") or s.startswith("import "):
        return None
    s = re.sub(r"\bTrue\b", "TRUE", s)
    s = re.sub(r"\bFalse\b", "FALSE", s)
    s = re.sub(r"\bNone\b", "NULL", s)
    s = re.sub(r"\blen\(([^)]+)\)", r"length(\1)", s)
    s = re.sub(r"\brange\(([^)]+)\)", r"seq(\1)", s)
    s = re.sub(r"\.append\(([^)]+)\)", r"[[length(x)+1]] <- \1  # FIXME append", s)
    s = re.sub(r"\braise (\w+)\(", r"twilic_stop(\1(", s)
    s = re.sub(r"\breturn\b", "return", s)
    s = re.sub(r"MessageKind\.(\w+)", r"MessageKind\1", s)
    s = re.sub(r"ValueKind\.(\w+)", r"ValueKind\1", s)
    s = re.sub(r"VectorCodec\.(\w+)", r"VectorCodec\1", s)
    s = re.sub(r"ElementType\.(\w+)", r"ElementType\1", s)
    s = re.sub(r"NullStrategy\.(\w+)", r"NullStrategy\1", s)
    s = re.sub(r"PatchOpcode\.(\w+)", r"PatchOpcode\1", s)
    s = re.sub(r"ControlStreamCodec\.(\w+)", r"ControlStreamCodec\1", s)
    if s.startswith("match "):
        return sp + f"# TODO match: {s}"
    if s.startswith("case "):
        return sp + f"# TODO case: {s}"
    if s.startswith("class ") or s.startswith("def "):
        return None
    return sp + s


def emit_protocol_wrappers() -> str:
    return textwrap.dedent(
        """
        # TwilicCodec and SessionEncoder (ported from twilic-python protocol.py)

        new_twilic_codec <- function(options = NULL) {
          state <- if (is.null(options)) new_session_state() else new_session_state_with_options(options)
          list(
            state = state,
            encode_message = function(msg) twilic_codec_encode_message(list(state = state), msg),
            decode_message = function(data) twilic_codec_decode_message(list(state = state), data),
            encode_value = function(val) twilic_codec_encode_value(list(state = state), val),
            decode_value = function(data) twilic_codec_decode_value(list(state = state), data)
          )
        }

        twilic_codec_with_options <- function(options) new_twilic_codec(options)

        new_session_encoder <- function(options = NULL) {
          opts <- options %||% default_session_options()
          state <- new_session_state_with_options(opts)
          codec <- new_twilic_codec(state)
          list(
            state = state,
            codec = codec,
            encode = function(v) session_encoder_encode(list(state = state, codec = codec), v),
            encode_with_schema = function(schema, v) session_encoder_encode_with_schema(list(state = state, codec = codec), schema, v),
            encode_batch = function(vals) session_encoder_encode_batch(list(state = state, codec = codec), vals),
            encode_patch = function(v) session_encoder_encode_patch(list(state = state, codec = codec), v),
            encode_micro_batch = function(vals) session_encoder_encode_micro_batch(list(state = state, codec = codec), vals),
            decode_message = function(data) session_encoder_decode_message(list(state = state, codec = codec), data),
            reset = function() session_encoder_reset(list(state = state, codec = codec))
          )
        }

        reset_encode_shape_observation <- function(codec, keys) {
          codec$state$encode_shape_observations[[shape_key(keys)]] <- NULL
          invisible(NULL)
        }

        # --- codec API (implementations below) ---
        """
    ).strip() + "\n"


def main() -> None:
    text = PY.read_text()
    idx_helpers = text.index(HELPER_START)
    idx_class = text.index(CLASS_START)
    idx_session = text.index(SESSION_START)
    helpers_src = text[idx_helpers:idx_class] + text[text.index("def new_twilic_codec"):]

    # For helpers: use hand-maintained port from PHP reference for critical paths
    # Run mechanical port as starting point
    r_helpers = py_helpers_to_r(helpers_src)
    R_HELPERS.write_text(r_helpers + "\n")
    print(f"wrote {R_HELPERS} ({len(r_helpers.splitlines())} lines)")

    # Protocol: copy Python class body via subprocess to temp and note manual merge needed
    class_src = text[idx_class:idx_session]
    R_PROTO.write_text(
        emit_protocol_wrappers()
        + "\n# Class body port required — see twilic-python protocol.py TwilicCodec\n"
        + "\n".join(f"# {l}" for l in class_src.splitlines()[:20])
        + "\n"
    )
    print(f"wrote stub {R_PROTO}")


if __name__ == "__main__":
    main()
