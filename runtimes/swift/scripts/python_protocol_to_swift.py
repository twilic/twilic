#!/usr/bin/env python3
"""Translate twilic-python protocol.py into Swift Protocol.swift + helpers."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PY = ROOT.parent / "python" / "src" / "twilic" / "protocol.py"
OUT_PROTOCOL = ROOT / "Sources" / "Twilic" / "Core" / "Protocol.swift"

ENUM_PREFIXES = (
    "MessageKind",
    "ValueKind",
    "StringMode",
    "ElementType",
    "VectorCodec",
    "NullStrategy",
    "ControlOpcode",
    "PatchOpcode",
    "ControlStreamCodec",
    "UnknownReferencePolicy",
)

REPLACEMENTS: list[tuple[str, str]] = [
    (r"^from .*$", ""),
    (r"^import .*$", ""),
    (r'^"""[\s\S]*?"""', ""),
    (r"bytearray\(\)", "Data()"),
    (r"\bbytearray\b", "Data"),
    (r"\bbytes\b", "Data"),
    (r"list\[", "["),
    (r"tuple\[", "("),
    (r"dict\[", "["),
    (r"\| None", "?"),
    (r"None", "nil"),
    (r"\bTrue\b", "true"),
    (r"\bFalse\b", "false"),
    (r"\bself\.", ""),
    (r"\bself\b", "self"),
    (r"def (\w+)\(self", r"func \1("),
    (r"def (\w+)\(", r"func \1("),
    (r"-> None:", "throws {"),
    (r"-> bytes:", "throws -> Data {"),
    (r"-> Message:", "throws -> Message {"),
    (r"-> Value:", "throws -> Value {"),
    (r"-> KeyRef:", "throws -> KeyRef {"),
    (r"-> Column:", "throws -> Column {"),
    (r"-> ControlMessage:", "throws -> ControlMessage {"),
    (r"-> BaseRef:", "throws -> BaseRef {"),
    (r"-> TypedVector:", "throws -> TypedVector {"),
    (r"-> \[str\]:", "throws -> [String] {"),
    (r"-> \[Value\]:", "throws -> [Value] {"),
    (r"-> \[Column\]:", "throws -> [Column] {"),
    (r"-> \(list\[bool\], bool\):", "throws -> ([Bool], Bool) {"),
    (r"-> \(int, int, bool\):", "throws -> (UInt64, Int, Bool) {"),
    (r"-> \(list\[PatchOperation\], int\):", "throws -> ([PatchOperation], Int) {"),
    (r"-> \(list\[bool\], list\[Column\]\):", "throws -> ([Bool], [Column]) {"),
    (r"-> tuple\[TypedVector, bool\]:", "throws -> (TypedVector, Bool) {"),
    (r"-> int:", "-> Int {"),
    (r"-> bool:", "-> Bool {"),
    (r"-> Exception:", "-> Error {"),
    (r": int\b", ": Int64"),
    (r": bool\b", ": Bool"),
    (r": str\b", ": String"),
    (r": float\b", ": Double"),
    (r": Reader\b", ": Reader"),
    (r": SessionState\b", ": SessionState"),
    (r": SessionOptions\b", ": SessionOptions"),
    (r": TwilicCodec\b", ": TwilicCodec"),
    (r": Value\b", ": Value"),
    (r": Message\b", ": Message"),
    (r": Schema\b", ": Schema"),
    (r": SchemaField\b", ": SchemaField"),
    (r": KeyRef\b", ": KeyRef"),
    (r": Column\b", ": Column"),
    (r": ControlMessage\b", ": ControlMessage"),
    (r": TypedVector\b", ": TypedVector"),
    (r": BaseRef\b", ": BaseRef"),
    (r": VectorCodec\b", ": VectorCodec"),
    (r": ControlStreamCodec\b", ": ControlStreamCodec"),
    (r"invalid_data\(", "throw TwilicErrors.invalidData("),
    (r"invalid_kind\(", "throw TwilicErrors.invalidKind("),
    (r"invalid_tag\(", "throw TwilicErrors.invalidTag("),
    (r"unknown_reference\(", "throw TwilicErrors.unknownReference("),
    (r"stateless_retry_required\(", "throw TwilicErrors.statelessRetryRequired("),
    (r"is_unknown_reference\(", "TwilicErrors.isUnknownReference("),
    (r"is_stateless_retry\(", "TwilicErrors.isStatelessRetry("),
    (r"encode_varuint\(", "Wire.encodeVaruint("),
    (r"encode_string\(", "Wire.encodeString("),
    (r"encode_bytes\(", "Wire.encodeBytes("),
    (r"encode_bitmap\(", "Wire.encodeBitmap("),
    (r"encode_zigzag\(", "Wire.encodeZigzag("),
    (r"decode_zigzag\(", "Wire.decodeZigzag("),
    (r"append_f64_le\(", "Wire.appendF64LE("),
    (r"append_u64_le\(", "Wire.appendU64LE("),
    (r"read_f64_le\(", "reader.readF64LE("),
    (r"new_reader\(", "Wire.newReader("),
    (r"encode_i64_vector\(", "try Codec.encodeI64Vector("),
    (r"decode_i64_vector\(", "try Codec.decodeI64Vector("),
    (r"encode_u64_vector\(", "try Codec.encodeU64Vector("),
    (r"decode_u64_vector\(", "try Codec.decodeU64Vector("),
    (r"encode_f64_vector\(", "try Codec.encodeF64Vector("),
    (r"decode_f64_vector\(", "try Codec.decodeF64Vector("),
    (r"apply_dictionary_references\(", "applyDictionaryReferences("),
    (r"decode_trained_dictionary_block\(", "try DictionaryCore.decodeTrainedDictionaryBlock("),
    (r"decode_trained_dictionary_payload\(", "try DictionaryCore.decodeTrainedDictionaryPayload("),
    (r"encode_trained_dictionary_block\(", "try DictionaryCore.encodeTrainedDictionaryBlock("),
    (r"dictionary_payload_hash\(", "dictionaryPayloadHash("),
    (r"new_session_state_with_options\(", "newSessionStateWithOptions("),
    (r"new_session_state\(", "newSessionState("),
    (r"default_session_options\(", "defaultSessionOptions("),
    (r"allocate_base_id\(", "allocateBaseID("),
    (r"allocate_template_id\(", "allocateTemplateID("),
    (r"register_base_snapshot\(", "registerBaseSnapshot("),
    (r"reset_state\(", "resetState("),
    (r"reset_tables\(", "resetTables("),
    (r"get_base_snapshot\(", "getBaseSnapshot("),
    (r"shape_key\(", "shapeKey("),
    (r"clone_typed_vector_data\(", "cloneTypedVectorData("),
    (r"len\(", ""),
    (r"\.append\(", ".append("),
    (r"schema\.schema_id", "schema.schemaID"),
    (r"shape_id", "shapeID"),
    (r"template_id", "templateID"),
    (r"ref_id", "refID"),
    (r"enum_values", "enumValues"),
    (r"logical_type", "logicalType"),
    (r"has_presence", "hasPresence"),
    (r"field_identity", "fieldIdentity"),
    (r"base_ref", "baseRef"),
    (r"enable_state_patch", "enableStatePatch"),
    (r"enable_template_batch", "enableTemplateBatch"),
    (r"enable_trained_dictionary", "enableTrainedDictionary"),
    (r"unknown_reference_policy", "unknownReferencePolicy"),
    (r"max_base_snapshots", "maxBaseSnapshots"),
    (r"previous_message", "previousMessage"),
    (r"previous_message_size", "previousMessageSize"),
    (r"encode_shape_observations", "encodeShapeObservations"),
    (r"field_enums", "fieldEnums"),
    (r"last_schema_id", "lastSchemaID"),
    (r"template_columns", "templateColumns"),
    (r"is_id", "isID"),
    (r"is_eof\(\)", "isEOF"),
    (r"read_varuint\(\)", "readVaruint()"),
    (r"read_string\(\)", "readString()"),
    (r"read_byte\(\)", "readByte()"),
    (r"read_bytes\(", "readBytes("),
    (r"raise ", "throw "),
    (r"except Exception", "catch"),
    (r"pass", "break"),
    (r"assert ", "// assert "),
    (r"struct\.", "// struct."),
    (r"\.pop\(([^,]+), None\)", ".removeValue(forKey: \\1)"),
    (r"\.size\(\)", ".count"),
    (r"\.length\(\)", ".count"),
    (r"\.isEmpty\(\)", ".isEmpty"),
    (r"\.get\(", "["),
    (r"\)\.clone\(\)", ".clone()"),
    (r"for e in ", "for e in "),
    (r"zip\(", "// zip("),
]


def camel_enum(s: str) -> str:
    for prefix in ENUM_PREFIXES:
        s = re.sub(rf"\b{prefix}\.([A-Z_]+)\b", lambda m, p=prefix: f"{p}.{snake_to_camel(m.group(1))}", s)
    return s


def snake_to_camel(name: str) -> str:
    parts = name.lower().split("_")
    if not parts:
        return name
    out = parts[0]
    for p in parts[1:]:
        out += p[:1].upper() + p[1:]
    return out


def convert_message_ctor(line: str) -> str:
    if "Message(" not in line or "kind=" not in line:
        return line
    m = re.search(r"Message\(kind=MessageKind\.(\w+)", line)
    if not m:
        return line
    kind = snake_to_camel(m.group(1))
    rest = line.split("Message(", 1)[1]
    body = rest.rsplit(")", 1)[0]
    body = body.replace("kind=MessageKind." + m.group(1) + ",", "").strip()
    if body.startswith(","):
        body = body[1:].strip()
    swift = f"let msg = Message(kind: .{kind})\n"
    for part in re.split(r",\s*(?=\w+=)", body):
        if not part.strip():
            continue
        k, v = part.split("=", 1)
        k = k.strip()
        v = v.strip()
        swift_name = {
            "scalar": "scalar",
            "array": "array",
            "map": "map",
            "shaped_object": "shapedObject",
            "schema_object": "schemaObject",
            "typed_vector": "typedVector",
            "row_batch": "rowBatch",
            "column_batch": "columnBatch",
            "control": "control",
            "state_patch": "statePatch",
            "template_batch": "templateBatch",
        }.get(k, k)
        swift += f"        msg.{swift_name} = {v}\n"
    swift += "        return msg"
    return swift


def transform_line(line: str, in_class: str | None) -> tuple[str, str | None]:
    raw = line.rstrip()
    if not raw.strip() or raw.strip().startswith("#"):
        return "", in_class

    if raw.startswith("class TwilicCodec"):
        return "public final class TwilicCodec {\n    public var state: SessionState\n\n    public init(state: SessionState? = nil) {\n        self.state = state ?? newSessionState()\n    }", "TwilicCodec"
    if raw.startswith("class SessionEncoder"):
        return "public final class SessionEncoder {\n    public let codec: TwilicCodec\n\n    public init(options: SessionOptions? = nil) {\n        let opts = options ?? defaultSessionOptions()\n        self.codec = TwilicCodec(state: newSessionStateWithOptions(opts))\n    }", "SessionEncoder"

    indent = len(raw) - len(raw.lstrip())
    body = raw.strip()

    if body.startswith("def ") and in_class:
        name = re.match(r"def (_?\w+)", body).group(1)
        if name == "__init__":
            return "", in_class
        sig = body[4:]
        sig = sig.replace("self, ", "").replace("self,", "")
        sig = re.sub(r"\) -> [^:]+:", ") throws -> Data {", sig, count=1)
        sig = sig.replace("def ", "func ")
        sig = re.sub(r": list\[Value\]", ": [Value]", sig)
        sig = re.sub(r": list\[MapEntry\]", ": [MapEntry]", sig)
        sig = re.sub(r": list\[str\]", ": [String]", sig)
        sig = re.sub(r": list\[bool\]", ": [Bool]", sig)
        sig = re.sub(r": list\[Column\]", ": [Column]", sig)
        sig = re.sub(r": list\[PatchOperation\]", ": [PatchOperation]", sig)
        sig = re.sub(r": list\[int\]", ": [Int64]", sig)
        sig = re.sub(r": list\[float\]", ": [Double]", sig)
        sig = re.sub(r": dict\[", ": [", sig)
        sig = re.sub(r"\bint\b", "Int64", sig)
        sig = re.sub(r"\bbool\b", "Bool", sig)
        sig = re.sub(r"\bstr\b", "String", sig)
        sig = re.sub(r"\bfloat\b", "Double", sig)
        sig = sig.replace("data: Data", "data: Data")
        pad = " " * (indent // 4 + 1 if in_class else 0)
        return f"{pad}{sig} {{", in_class

    s = body
    for pat, repl in REPLACEMENTS:
        s = re.sub(pat, repl, s)
    s = camel_enum(s)

    if s.startswith("match "):
        s = s.replace("match ", "switch ").replace(":", " {")
    if s.startswith("case "):
        case = s[5:].split(":", 1)[0].strip()
        if case.startswith("MessageKind.") or case.startswith("ValueKind."):
            case = "." + case.split(".", 1)[1].lower()
            s = f"case {case}:"
        elif case.startswith("ElementType."):
            s = f"case {case.split('.')[1].lower()}:"
    if s == "else:":
        s = "default:"

    pad = "    " * (indent // 4 + (1 if in_class else 0))
    if s in ("}",) or s.endswith("}"):
        return f"{pad}{s}", in_class
    return f"{pad}{s}", in_class


def main() -> None:
    text = PY.read_text()
    # strip module docstring/imports through TAG constants
    start = text.find("TAG_NULL = 0")
    text = text[start:]

    lines_out = [
        "import Foundation",
        "",
        "private let tagNull: UInt8 = 0",
        "private let tagBoolFalse: UInt8 = 1",
        "private let tagBoolTrue: UInt8 = 2",
        "private let tagI64: UInt8 = 3",
        "private let tagU64: UInt8 = 4",
        "private let tagF64: UInt8 = 5",
        "private let tagString: UInt8 = 6",
        "private let tagBinary: UInt8 = 7",
        "private let tagArray: UInt8 = 8",
        "private let tagMap: UInt8 = 9",
        "",
    ]

    in_class: str | None = None
    for line in text.splitlines():
        if line.startswith("class TwilicCodec"):
            in_class = "TwilicCodec"
            lines_out.append("public final class TwilicCodec {")
            lines_out.append("    public var state: SessionState")
            lines_out.append("")
            lines_out.append("    public init(state: SessionState? = nil) {")
            lines_out.append("        self.state = state ?? newSessionState()")
            lines_out.append("    }")
            continue
        if line.startswith("class SessionEncoder"):
            if in_class:
                lines_out.append("}")
            in_class = "SessionEncoder"
            lines_out.extend(
                [
                    "public final class SessionEncoder {",
                    "    public let codec: TwilicCodec",
                    "",
                    "    public init(options: SessionOptions? = nil) {",
                    "        let opts = options ?? defaultSessionOptions()",
                    "        self.codec = TwilicCodec(state: newSessionStateWithOptions(opts))",
                    "    }",
                ]
            )
            continue
        if line.startswith("def new_twilic_codec"):
            in_class = None
            break
        # Skip - manual helpers appended from python bottom functions later
        converted, _ = transform_line(line, in_class)
        if converted:
            lines_out.append(converted)

    if in_class:
        lines_out.append("}")

    # Public factory functions
    lines_out.extend(
        [
            "",
            "public func newTwilicCodec() -> TwilicCodec { TwilicCodec() }",
            "",
            "public func twilicCodecWithOptions(_ options: SessionOptions) -> TwilicCodec {",
            "    TwilicCodec(state: newSessionStateWithOptions(options))",
            "}",
            "",
            "public func newSessionEncoder(_ options: SessionOptions? = nil) -> SessionEncoder {",
            "    SessionEncoder(options: options)",
            "}",
        ]
    )

    OUT_PROTOCOL.write_text("\n".join(lines_out) + "\n")
    print(f"wrote {OUT_PROTOCOL} ({len(lines_out)} lines) — needs manual fixup")


if __name__ == "__main__":
    main()
