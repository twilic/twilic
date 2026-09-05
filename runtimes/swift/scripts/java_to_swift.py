#!/usr/bin/env python3
"""Convert twilic-java internal core sources to Swift skeletons."""

from __future__ import annotations

import re
from pathlib import Path

RUNTIMES_ROOT = Path(__file__).resolve().parents[2]
JAVA = RUNTIMES_ROOT / "java" / "src/main/java/io/twilic/internal/core"
OUT = RUNTIMES_ROOT / "swift" / "Sources/Twilic/Core"

MAP = {
    "ProtocolCodec.java": "ProtocolCodec.swift",
    "ProtocolHelpers.java": "ProtocolHelpers.swift",
    "ProtocolTypes.java": "ModelTypes.swift",
    "Codec.java": "Codec.swift",
    "Dictionary.java": "Dictionary.swift",
    "Session.java": "Session.swift",
    "V2.java": "V2.swift",
    "Wire.java": "Wire.swift",
    "Errors.java": "Errors.swift",
    "Value.java": "Value.swift",
    "MessageKind.java": "MessageKind.swift",
    "ValueKind.java": "ValueKind.swift",
    "KeyRef.java": "KeyRef.swift",
    "BaseRef.java": "BaseRef.swift",
    "MapEntry.java": "MapEntry.swift",
    "Schema.java": "Schema.swift",
    "SchemaField.java": "SchemaField.swift",
    "SessionEncoder.java": "SessionEncoder.swift",
    "Api.java": "Api.swift",
}


def convert(name: str, text: str) -> str:
    text = re.sub(r"package io\.twilic\.internal\.core;\n\n", "", text)
    text = re.sub(r"import io\.twilic\.internal\.core\.Errors\.TwilicException;", "", text)
    text = re.sub(r"import io\.twilic\.internal\.core\.\w+;\n", "", text)
    text = re.sub(r"import java\.io\.ByteArrayOutputStream;", "", text)
    text = re.sub(r"import java\.nio\..*;\n", "", text)
    text = re.sub(r"import java\.util\..*;\n", "", text)
    text = text.replace("final class", "final class")
    text = text.replace("public final class", "public final class")
    text = text.replace("enum ", "enum ")
    text = text.replace("long ", "UInt64 ")
    text = text.replace("int ", "Int ")
    text = text.replace("byte[]", "Data")
    text = text.replace("byte ", "UInt8 ")
    text = text.replace("boolean", "Bool")
    text = text.replace("double", "Double")
    text = text.replace("String", "String")
    text = text.replace("List<", "[")
    text = text.replace(">", "]")
    text = text.replace("new ArrayList<>()", "[]")
    text = text.replace("new HashMap<>()", "[:]")
    text = text.replace("throws TwilicException", "throws")
    text = text.replace("TwilicException", "TwilicError")
    text = text.replace("Errors.", "TwilicErrors.")
    text = text.replace("@Override", "")
    text = text.replace("null", "nil")
    text = text.replace("true", "true")
    text = text.replace("false", "false")
    return "import Foundation\n\n" + text


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for jname, sname in MAP.items():
        src = JAVA / jname
        if not src.exists():
            print("skip", jname)
            continue
        body = convert(jname, src.read_text())
        (OUT / sname).write_text(body)
        print("wrote", sname)


if __name__ == "__main__":
    main()
