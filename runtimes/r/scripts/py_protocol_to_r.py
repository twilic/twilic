#!/usr/bin/env python3
"""Mechanical Python protocol.py -> R/protocol.R + R/protocol_helpers.R (best-effort)."""

from __future__ import annotations

import re
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python" / "src" / "twilic" / "protocol.py"
OUT_PROTO = Path(__file__).resolve().parents[1] / "R" / "protocol.R"
OUT_HELPERS = Path(__file__).resolve().parents[1] / "R" / "protocol_helpers.R"


def py_expr_to_r(expr: str) -> str:
    e = expr
    e = e.replace("self.state", "codec$state")
    e = e.replace("self.", "codec$")
    e = re.sub(r"\bTrue\b", "TRUE", e)
    e = re.sub(r"\bFalse\b", "FALSE", e)
    e = re.sub(r"\bNone\b", "NULL", e)
    e = re.sub(r"\blen\(([^)]+)\)", r"length(\1)", e)
    e = re.sub(r"\.append\(([^)]+)\)", r"<- raw_append_byte(out, \1)", e)
    return e


def convert_function(name: str, args: str, body_lines: list[str], prefix: str = "") -> list[str]:
    r_args = []
    for a in [x.strip() for x in args.split(",") if x.strip()]:
        a = a.replace("self", "codec").replace(": TwilicCodec", "").replace(": SessionEncoder", "enc")
        a = re.sub(r":.*", "", a).strip()
        if a and a != "codec" and a != "enc":
            r_args.append(a)
    sig = ", ".join(["codec"] + r_args) if prefix == "codec" else ", ".join(r_args or ["..."])
    out = [f"{prefix}{name} <- function({sig}) {{"]
    for line in body_lines:
        line = line.rstrip()
        if not line.strip():
            out.append("")
            continue
        if line.strip().startswith('"""'):
            continue
        converted = py_expr_to_r(line)
        # very rough: pass through with comment
        out.append(f"  # {converted}")
    out.append("  stop('port incomplete')")
    out.append("}")
    return out


def main() -> None:
    lines = PY.read_text().splitlines()
    helpers_start = next(i for i, l in enumerate(lines) if l.startswith("def new_twilic_codec"))
    codec_start = next(i for i, l in enumerate(lines) if l.startswith("class TwilicCodec"))
    session_start = next(i for i, l in enumerate(lines) if l.startswith("class SessionEncoder"))

  # For now emit stubs that call into Python reference via stop()
    header = "# Auto-generated stubs from twilic-python protocol.py — implement incrementally.\n\n"
    header += "TAG_NULL <- 0L\nTAG_BOOL_FALSE <- 1L\nTAG_BOOL_TRUE <- 2L\nTAG_I64 <- 3L\nTAG_U64 <- 4L\nTAG_F64 <- 5L\nTAG_STRING <- 6L\nTAG_BINARY <- 7L\nTAG_ARRAY <- 8L\nTAG_MAP <- 9L\n\n"

    stubs = []
    for i in range(helpers_start, len(lines)):
        m = re.match(r"^def (\w+)\(", lines[i])
        if m:
            stubs.append(f"{m.group(1)} <- function(...) stop('protocol helper not ported: {m.group(1)}')")

    OUT_HELPERS.write_text(header + "\n".join(stubs) + "\n")

    codec_stubs = [
        "new_twilic_codec <- function(options = NULL) {",
        "  state <- new_session_state(options)",
        "  list(",
        "    state = state,",
        "    encode_message = function(msg) twilic_codec_encode_message(list(state = state), msg),",
        "    decode_message = function(data) twilic_codec_decode_message(list(state = state), data),",
        "    encode_value = function(val) twilic_codec_encode_value(list(state = state), val),",
        "    decode_value = function(data) twilic_codec_decode_value(list(state = state), data)",
        "  )",
        "}",
        "twilic_codec_with_options <- function(options) new_twilic_codec(options)",
        "new_session_encoder <- function(options = NULL) {",
        "  enc_state <- new_session_state(options)",
        "  list(state = enc_state, codec = new_twilic_codec(enc_state$options), encode = function(v) session_encoder_encode(list(state=enc_state), v))",
        "}",
        "reset_encode_shape_observation <- function(codec, keys) {",
        "  codec$state$encode_shape_observations[[shape_key(keys)]] <- NULL",
        "  invisible(NULL)",
        "}",
        "twilic_codec_encode_message <- function(codec, message) stop('not ported')",
        "twilic_codec_decode_message <- function(codec, data) stop('not ported')",
        "twilic_codec_encode_value <- function(codec, value) stop('not ported')",
        "twilic_codec_decode_value <- function(codec, data) stop('not ported')",
        "session_encoder_encode <- function(enc, value) stop('not ported')",
    ]
    OUT_PROTO.write_text(header + "\n".join(codec_stubs) + "\n")
    print("wrote stubs", OUT_PROTO, OUT_HELPERS)


if __name__ == "__main__":
    main()
