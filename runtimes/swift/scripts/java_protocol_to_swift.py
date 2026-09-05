#!/usr/bin/env python3
"""Convert twilic-java ProtocolCodec.java + ProtocolHelpers.java to Swift."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
JAVA = REPO / "java/src/main/java/io/twilic/internal/core"
OUT = ROOT / "Sources/Twilic/Core"


def convert_java_to_swift(java: str, class_name: str | None = None) -> str:
    lines = java.splitlines()
    out: list[str] = ["import Foundation", ""]
    skip_until_class = True
    brace_depth = 0
    in_class = False

    for raw in lines:
        line = raw.rstrip()
        if skip_until_class:
            if line.startswith("final class ") or line.startswith("public final class "):
                skip_until_class = False
                name = re.search(r"class (\w+)", line).group(1)
                if name == "Protocol":
                    continue
                if name == "TwilicCodec":
                    out.append("public final class TwilicCodec {")
                    out.append("    public var state: SessionState")
                    out.append("    public init(state: SessionState = newSessionState()) { self.state = state }")
                    in_class = True
                    brace_depth = 0
                    continue
                if name == "SessionEncoder":
                    out.append("public final class SessionEncoder {")
                    out.append("    public let codec: TwilicCodec")
                    out.append("    public init(options: SessionOptions = defaultSessionOptions()) {")
                    out.append("        self.codec = TwilicCodec(state: newSessionStateWithOptions(options))")
                    out.append("    }")
                    in_class = True
                    continue
                out.append(f"enum {name} {{")
                in_class = True
                continue
            continue

        if line.strip().startswith("package ") or line.strip().startswith("import "):
            continue
        if line.strip() == "final class Protocol {":
            continue

        s = line
        s = s.replace("ByteArrayOutputStream", "Data")
        s = s.replace("byte[]", "Data")
        s = s.replace("boolean", "Bool")
        s = s.replace("double", "Double")
        s = s.replace("String", "String")
        s = s.replace("List<", "[")
        s = s.replace(">", "]")
        s = s.replace("Map<", "[String: ")
        s = s.replace("HashMap<", "[String: ")
        s = s.replace("new ArrayList<>()", "[]")
        s = s.replace("new ArrayList<", "[")
        s = s.replace("new HashMap<>()", "[:]")
        s = s.replace("Errors.", "TwilicErrors.")
        s = s.replace("Wire.", "Wire.")
        s = s.replace("ProtocolHelpers.", "ProtocolHelpers.")
        s = s.replace("Dictionary.", "DictionaryCore.")
        s = s.replace("Codec.", "Codec.")
        s = s.replace("Value.of", "new")  # rough
        s = re.sub(r"\blong\b", "UInt64", s)
        s = re.sub(r"\bint\b", "Int", s)
        s = re.sub(r"\bbyte\b", "UInt8", s)
        s = s.replace("void ", "func ")
        s = s.replace("throws TwilicException", "throws")
        s = s.replace("TwilicException", "TwilicError")
        s = s.replace("@Override", "")
        s = s.replace("null", "nil")
        s = s.replace("true", "true")
        s = s.replace("false", "false")
        s = s.replace("MessageKind.", ".")
        s = s.replace("ValueKind.", ".")
        s = s.replace("VectorCodec.", ".")
        s = s.replace("ElementType.", ".")
        s = s.replace("NullStrategy.", ".")
        s = s.replace("ControlOpcode.", ".")
        s = s.replace("PatchOpcode.", ".")
        s = s.replace("StringMode.", ".")
        s = s.replace("ControlStreamCodec.", ".")
        s = s.replace("UnknownReferencePolicy.", ".")
        s = s.replace("DictionaryFallback.", ".")
        s = s.replace("    case ", "        case ")
        s = s.replace("switch (", "switch ")
        s = s.replace(") {", " {")
        s = s.replace(".write((byte)", ".append(UInt8(")
        s = s.replace(".write(", ".append(UInt8(")
        s = s.replace("out.toByteArray()", "out")
        s = s.replace("new Reader(", "Wire.newReader(")
        s = s.replace("new ByteArrayOutputStream()", "Data()")
        s = s.replace("ByteArrayOutputStream out = new Data()", "var out = Data()")
        s = s.replace("Data out = Data()", "var out = Data()")
        s = s.replace("appendBytes(out, bos)", "out.append(bos)")
        if s.strip():
            out.append(s)

    if in_class:
        out.append("}")
    return "\n".join(out)


def main() -> None:
    codec_java = (JAVA / "ProtocolCodec.java").read_text()
    helpers_java = (JAVA / "ProtocolHelpers.java").read_text()

    # Extract TwilicCodec and SessionEncoder from ProtocolCodec.java
    (OUT / "Protocol.swift").write_text(convert_java_to_swift(codec_java))
    (OUT / "ProtocolHelpers.swift").write_text(
        "enum ProtocolHelpers {\n" + convert_java_to_swift(helpers_java).split("\n", 2)[-1]
    )
    print("wrote Protocol.swift and ProtocolHelpers.swift")


if __name__ == "__main__":
    main()
