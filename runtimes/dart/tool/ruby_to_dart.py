#!/usr/bin/env python3
"""Convert twilic-ruby core/*.rb to Dart lib/src/*.dart (mechanical baseline)."""
from __future__ import annotations

import re
from pathlib import Path

RUBY = Path(__file__).resolve().parents[2] / "ruby/lib/twilic/core"
OUT = Path(__file__).resolve().parents[1] / "lib/src"

MAP = {
    "v2.rb": "v2.dart",
    "session.rb": "session.dart",
    "codec.rb": "codec.dart",
    "dictionary.rb": "dictionary.dart",
    "protocol_helpers.rb": "protocol_helpers.dart",
    "protocol.rb": "protocol.dart",
}


def convert(rb: str, module: str) -> str:
    lines_out = [
        "// Mechanical port from twilic-ruby/%s — may need manual fixes.\n" % module,
        "import 'dart:convert';",
        "import 'dart:typed_data';",
        "import 'errors.dart';",
        "import 'model.dart';",
        "import 'wire.dart';",
    ]
    if module in ("v2.dart",):
        pass
    if module in ("codec.dart", "protocol.dart", "protocol_helpers.dart", "dictionary.dart"):
        lines_out.append("import 'codec.dart';" if module != "codec.dart" else "")
        lines_out.append("import 'session.dart';")
        lines_out.append("import 'dictionary.dart';" if module != "dictionary.dart" else "")
    lines_out = [l for l in lines_out if l]
    lines_out.append("")

    skip = 0
    for line in rb.splitlines():
        if "frozen_string_literal" in line or line.strip().startswith("require "):
            continue
        if re.match(r"\s*module Twilic", line):
            skip = 1
            continue
        if skip == 1 and re.match(r"\s*module Core", line):
            skip = 2
            continue
        if skip == 2 and re.match(r"\s*module \w+", line):
            skip = 3
            continue
        if line.strip() == "end" and skip > 0:
            skip -= 1
            continue
        if skip > 0 and skip < 3:
            continue

        s = line
        s = s.replace("Model::", "").replace("Wire::", "").replace("Errors.", "")
        s = s.replace("Session::", "").replace("Codec::", "").replace("V2.", "")
        s = s.replace("Dictionary.", "").replace("ProtocolHelpers.", "")
        s = s.replace("ValueKind::", "ValueKind.")
        s = s.replace("MessageKind::", "MessageKind.")
        s = s.replace("VectorCodec::", "VectorCodec.")
        s = s.replace("ElementType::", "ElementType.")
        s = s.replace("StringMode::", "StringMode.")
        s = s.replace("NullStrategy::", "NullStrategy.")
        s = s.replace("ControlOpcode::", "ControlOpcode.")
        s = s.replace("PatchOpcode::", "PatchOpcode.")
        s = s.replace("ControlStreamCodec::", "ControlStreamCodec.")
        s = s.replace("UnknownReferencePolicy::", "UnknownReferencePolicy.")
        s = s.replace("DictionaryFallback::", "DictionaryFallback.")
        s = re.sub(r"\.bool\b", ".boolValue", s)
        s = s.replace("module_function", "")
        s = s.replace("attr_accessor", "// attr")
        s = s.replace("+\"\"", "BytesBuilder()")
        s = s.replace("out << ", "out.addByte(") if ".chr" in s else s.replace("out << ", "out.add(")
        s = s.replace(".chr", "")
        s = s.replace("raise ", "throw ")
        s = s.replace("unless ", "if (!(")
        s = s.replace("def self.", "static ")
        s = re.sub(r"^\s*def (\w+)", r"void \1(", s)
        s = s.replace("@", "")
        s = s.replace("||", "||")
        s = s.replace("&&", "&&")
        s = s.replace("nil", "null")
        s = s.replace("true", "true").replace("false", "false")
        s = s.replace("bytes", "Uint8List")
        s = s.replace(".bytesize", ".length")
        s = s.replace(".unpack1", ".unpack")  # wrong but placeholder
        if s.strip():
            lines_out.append(s)
    return "\n".join(lines_out) + "\n"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for rb_name, dart_name in MAP.items():
        src = RUBY / rb_name
        if not src.exists():
            print("skip", rb_name)
            continue
        text = convert(src.read_text(encoding="utf-8"), dart_name)
        (OUT / dart_name).write_text(text, encoding="utf-8")
        print("wrote", dart_name, len(text))


if __name__ == "__main__":
    main()
