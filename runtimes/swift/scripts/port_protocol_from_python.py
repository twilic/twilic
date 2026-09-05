#!/usr/bin/env python3
"""AST-based port of twilic-python protocol.py to Swift Protocol*.swift."""

from __future__ import annotations

import ast
import re
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PY_PATH = ROOT.parent / "python" / "src" / "twilic" / "protocol.py"
OUT_PROTOCOL = ROOT / "Sources" / "Twilic" / "Core" / "Protocol.swift"
OUT_HELPERS = ROOT / "Sources" / "Twilic" / "Core" / "ProtocolHelpers.swift"

ENUM_MAP = {
    "MessageKind": {
        "SCALAR": "scalar",
        "ARRAY": "array",
        "MAP": "map",
        "SHAPED_OBJECT": "shapedObject",
        "SCHEMA_OBJECT": "schemaObject",
        "TYPED_VECTOR": "typedVector",
        "ROW_BATCH": "rowBatch",
        "COLUMN_BATCH": "columnBatch",
        "CONTROL": "control",
        "EXT": "ext",
        "STATE_PATCH": "statePatch",
        "TEMPLATE_BATCH": "templateBatch",
        "CONTROL_STREAM": "controlStream",
        "BASE_SNAPSHOT": "baseSnapshot",
    },
    "ValueKind": {
        "NULL": "null",
        "BOOL": "bool",
        "I64": "i64",
        "U64": "u64",
        "F64": "f64",
        "STRING": "string",
        "BINARY": "binary",
        "ARRAY": "array",
        "MAP": "map",
    },
    "StringMode": {
        "EMPTY": "empty",
        "LITERAL": "literal",
        "REF": "ref",
        "PREFIX_DELTA": "prefixDelta",
        "INLINE_ENUM": "inlineEnum",
    },
    "ElementType": {
        "BOOL": "bool",
        "I64": "i64",
        "U64": "u64",
        "F64": "f64",
        "STRING": "string",
        "BINARY": "binary",
        "VALUE": "value",
    },
    "VectorCodec": {
        "PLAIN": "plain",
        "DIRECT_BITPACK": "directBitpack",
        "DELTA_BITPACK": "deltaBitpack",
        "FOR_BITPACK": "forBitpack",
        "DELTA_FOR_BITPACK": "deltaForBitpack",
        "DELTA_DELTA_BITPACK": "deltaDeltaBitpack",
        "RLE": "rle",
        "PATCHED_FOR": "patchedFor",
        "SIMPLE8B": "simple8b",
        "XOR_FLOAT": "xorFloat",
        "DICTIONARY": "dictionary",
        "STRING_REF": "stringRef",
        "PREFIX_DELTA": "prefixDelta",
    },
    "NullStrategy": {
        "NONE": "none",
        "PRESENCE_BITMAP": "presenceBitmap",
        "INVERTED_PRESENCE_BITMAP": "invertedPresenceBitmap",
        "ALL_PRESENT_ELIDED": "allPresentElided",
    },
    "ControlOpcode": {
        "REGISTER_KEYS": "registerKeys",
        "REGISTER_SHAPE": "registerShape",
        "REGISTER_STRINGS": "registerStrings",
        "PROMOTE_STRING_FIELD_TO_ENUM": "promoteStringFieldToEnum",
        "RESET_TABLES": "resetTables",
        "RESET_STATE": "resetState",
    },
    "PatchOpcode": {
        "KEEP": "keep",
        "REPLACE_SCALAR": "replaceScalar",
        "REPLACE_VECTOR": "replaceVector",
        "APPEND_VECTOR": "appendVector",
        "TRUNCATE_VECTOR": "truncateVector",
        "DELETE_FIELD": "deleteField",
        "INSERT_FIELD": "insertField",
        "STRING_REF": "stringRef",
        "PREFIX_DELTA": "prefixDelta",
    },
    "ControlStreamCodec": {
        "PLAIN": "plain",
        "RLE": "rle",
        "BITPACK": "bitpack",
        "HUFFMAN": "huffman",
        "FSE": "fse",
    },
    "UnknownReferencePolicy": {
        "FAIL_FAST": "failFast",
        "STATELESS_RETRY": "statelessRetry",
    },
}


def map_enum(expr: str) -> str:
    for enum, members in ENUM_MAP.items():
        for py_name, swift_name in members.items():
            expr = re.sub(rf"\b{enum}\.{py_name}\b", f".{swift_name}", expr)
    return expr


def py_type_to_swift(t: ast.expr | None) -> str:
    if t is None:
        return "Void"
    if isinstance(t, ast.Name):
        m = {
            "int": "Int64",
            "bool": "Bool",
            "str": "String",
            "float": "Double",
            "bytes": "Data",
            "Value": "Value",
            "Message": "Message",
            "Schema": "Schema",
            "SchemaField": "SchemaField",
            "KeyRef": "KeyRef",
            "Column": "Column",
            "TypedVector": "TypedVector",
            "TypedVectorData": "TypedVectorData",
            "ControlMessage": "ControlMessage",
            "BaseRef": "BaseRef",
            "VectorCodec": "VectorCodec",
            "ControlStreamCodec": "ControlStreamCodec",
            "SessionState": "SessionState",
            "SessionOptions": "SessionOptions",
            "Reader": "Wire.Reader",
            "TwilicCodec": "TwilicCodec",
            "Exception": "Error",
        }
        return m.get(t.id, t.id)
    if isinstance(t, ast.Subscript):
        base = py_type_to_swift(t.value)
        if base == "list":
            return f"[{py_type_to_swift(t.slice)}]"
        if base == "tuple":
            elts = t.slice.elts if isinstance(t.slice, ast.Tuple) else [t.slice]
            return f"({', '.join(py_type_to_swift(e) for e in elts)})"
        if base == "dict":
            return f"[String: {py_type_to_swift(t.slice)}]"
    if isinstance(t, ast.BinOp) and isinstance(t.op, ast.BitOr):
        left = py_type_to_swift(t.left)
        right = py_type_to_swift(t.right)
        if right == "None":
            return f"{left}?"
        return f"{left}?"
    if isinstance(t, ast.Constant) and t.value is None:
        return "Void"
    return "Any"


def expr_to_swift(node: ast.expr) -> str:
    if isinstance(node, ast.Constant):
        if node.value is None:
            return "nil"
        if isinstance(node.value, bool):
            return "true" if node.value else "false"
        if isinstance(node.value, str):
            return repr(node.value)
        return repr(node.value)
    if isinstance(node, ast.Name):
        if node.id == "self":
            return ""  # handled by caller
        return node.id
    if isinstance(node, ast.Attribute):
        base = expr_to_swift(node.value)
        attr = node.attr
        renames = {
            "schema_id": "schemaID",
            "shape_id": "shapeID",
            "template_id": "templateID",
            "field_id": "fieldID",
            "ref_id": "refID",
            "enum_values": "enumValues",
            "logical_type": "logicalType",
            "has_presence": "hasPresence",
            "is_id": "isID",
            "is_eof": "isEOF",
            "previous_message": "previousMessage",
            "previous_message_size": "previousMessageSize",
            "encode_shape_observations": "encodeShapeObservations",
            "field_enums": "fieldEnums",
            "last_schema_id": "lastSchemaID",
            "template_columns": "templateColumns",
            "enable_state_patch": "enableStatePatch",
            "enable_template_batch": "enableTemplateBatch",
            "enable_trained_dictionary": "enableTrainedDictionary",
            "unknown_reference_policy": "unknownReferencePolicy",
            "max_base_snapshots": "maxBaseSnapshots",
            "by_id": "registeredStringsInOrder",
        }
        attr = renames.get(attr, attr)
        if base in ("", "self"):
            return attr
        if base == "state":
            return f"state.{attr}"
        if base == "reader":
            return f"reader.{swift_reader_method(attr)}"
        if base == "codec":
            return f"codec.{attr}"
        return f"{base}.{attr}"
    if isinstance(node, ast.Call):
        func = expr_to_swift(node.func)
        args = ", ".join(expr_to_swift(a) for a in node.args)
        # map known calls
        call_map = {
            "len": ".count",
            "int": "Int",
            "new_null": "newNull()",
            "new_bool": "newBool",
            "new_i64": "newI64",
            "new_u64": "newU64",
            "new_f64": "newF64",
            "new_string": "newString",
            "new_binary": "newBinary",
            "new_array": "newArray",
            "new_map": "newMap",
            "entry": "entry",
            "key_ref_literal": "keyRefLiteral",
            "key_ref_id": "keyRefID",
            "base_ref_previous": "baseRefPrevious()",
            "base_ref_id": "baseRefID",
            "encode_varuint": "Wire.encodeVaruint",
            "encode_string": "Wire.encodeString",
            "encode_bytes": "Wire.encodeBytes",
            "encode_bitmap": "Wire.encodeBitmap",
            "encode_zigzag": "Wire.encodeZigzag",
            "decode_zigzag": "Wire.decodeZigzag",
            "append_f64_le": "Wire.appendF64LE",
            "new_reader": "Wire.newReader",
            "invalid_data": "TwilicErrors.invalidData",
            "invalid_kind": "TwilicErrors.invalidKind",
            "invalid_tag": "TwilicErrors.invalidTag",
            "reset_tables": "resetTables",
            "reset_state": "resetState",
            "shape_key": "shapeKey",
            "clone_typed_vector_data": "cloneTypedVectorData",
            "apply_dictionary_references": "applyDictionaryReferences",
            "allocate_base_id": "allocateBaseID",
            "allocate_template_id": "allocateTemplateID",
            "register_base_snapshot": "registerBaseSnapshot",
            "get_base_snapshot": "getBaseSnapshot",
            "dictionary_payload_hash": "dictionaryPayloadHash",
            "should_register_shape": "shouldRegisterShape",
            "supports_state_patch": "supportsStatePatch",
            "encoded_size": "encodedSize",
            "diff_message": "diffMessage",
            "message_kind_from_byte": "messageKindFromByte",
            "string_mode_from_byte": "stringModeFromByte",
            "element_type_from_byte": "elementTypeFromByte",
            "vector_codec_from_byte": "vectorCodecFromByte",
            "null_strategy_from_byte": "nullStrategyFromByte",
            "control_opcode_from_byte": "controlOpcodeFromByte",
            "patch_opcode_from_byte": "patchOpcodeFromByte",
            "control_stream_codec_from_byte": "controlStreamCodecFromByte",
            "dictionary_fallback_from_byte": "dictionaryFallbackFromByte",
        }
        if func in call_map:
            mapped = call_map[func]
            if mapped.endswith(")"):
                return mapped
            return f"{mapped}({args})"
        return f"{func}({args})"
    if isinstance(node, ast.Compare):
        left = expr_to_swift(node.left)
        parts = [left]
        for op, comp in zip(node.ops, node.comparators):
            sop = "==" if isinstance(op, ast.Eq) else ">=" if isinstance(op, ast.GtE) else "<=" if isinstance(op, ast.LtE) else ">"
            parts.append(f"{sop} {expr_to_swift(comp)}")
        return " ".join(parts)
    if isinstance(node, ast.BoolOp):
        join = " && " if isinstance(node.op, ast.And) else " || "
        return join.join(f"({expr_to_swift(v)})" for v in node.values)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return f"!{expr_to_swift(node.operand)}"
    if isinstance(node, ast.List):
        return "[" + ", ".join(expr_to_swift(e) for e in node.elts) + "]"
    if isinstance(node, ast.Tuple):
        return "(" + ", ".join(expr_to_swift(e) for e in node.elts) + ")"
    if isinstance(node, ast.Subscript):
        return f"{expr_to_swift(node.value)}[{expr_to_swift(node.slice)}]"
    if isinstance(node, ast.IfExp):
        return f"({expr_to_swift(node.body)} ? {expr_to_swift(node.orelse)} : {expr_to_swift(node.test)})"
    return ast.unparse(node)


def swift_reader_method(name: str) -> str:
    return {
        "read_u8": "readU8()",
        "read_varuint": "readVaruint()",
        "read_string": "readString()",
        "read_bytes": "readBytes()",
        "read_bitmap": "readBitmap()",
        "read_f64_le": "readF64LE()",
        "is_eof": "isEOF",
    }.get(name, name)


def convert_function(fn: ast.FunctionDef, indent: str, is_method: bool) -> list[str]:
    lines: list[str] = []
    name = fn.name.lstrip("_")
    swift_name = fn.name
    if swift_name.startswith("_"):
        swift_name = swift_name  # keep private prefix in swift as private func

    args: list[str] = []
    if is_method and fn.name != "__init__":
        pass
    for a in fn.args.args:
        if a.arg == "self":
            continue
        ann = py_type_to_swift(a.annotation)
        args.append(f"_ {a.arg}: {ann}")

    ret = "Void"
    throws = True
    for n in ast.walk(fn):
        if isinstance(n, ast.Raise):
            throws = True
    ret_ann = fn.returns
    if ret_ann:
        ret = py_type_to_swift(ret_ann)
        if ret != "Void":
            ret_swift = f"throws -> {ret}"
        else:
            ret_swift = "throws"
    else:
        ret_swift = "throws"

    if fn.name == "__init__":
        lines.append(f"{indent}public init(state: SessionState? = nil) {{")
        lines.append(f"{indent}    self.state = state ?? newSessionState()")
        lines.append(f"{indent}}}")
        return lines

    sig = f"{indent}func {swift_name}({', '.join(args)}) {ret_swift} {{"
    lines.append(sig)
    lines.append(f"{indent}    // TODO: port body of {fn.name}")
    lines.append(f"{indent}    throw TwilicErrors.invalidData(\"not ported: {fn.name}\")")
    lines.append(f"{indent}}}")
    return lines


def main() -> None:
    src = PY_PATH.read_text()
    tree = ast.parse(src)

    protocol_lines = [
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
        "public final class TwilicCodec {",
        "    public var state: SessionState",
        "",
        "    public init(state: SessionState? = nil) {",
        "        self.state = state ?? newSessionState()",
        "    }",
    ]

    helper_lines = [
        "import Foundation",
        "",
        "enum ProtocolHelpers {",
    ]

    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            if node.name == "TwilicCodec":
                for item in node.body:
                    if isinstance(item, ast.FunctionDef):
                        protocol_lines.extend(convert_function(item, "    ", True))
            elif node.name == "SessionEncoder":
                protocol_lines.append("}")
                protocol_lines.extend(
                    [
                        "",
                        "public final class SessionEncoder {",
                        "    public let codec: TwilicCodec",
                        "",
                        "    public init(options: SessionOptions? = nil) {",
                        "        let opts = options ?? defaultSessionOptions()",
                        "        codec = TwilicCodec(state: newSessionStateWithOptions(opts))",
                        "    }",
                    ]
                )
                for item in node.body:
                    if isinstance(item, ast.FunctionDef):
                        protocol_lines.extend(convert_function(item, "    ", True))
                protocol_lines.append("}")
        elif isinstance(node, ast.FunctionDef):
            helper_lines.extend(convert_function(node, "    ", False))

    helper_lines.append("}")
    protocol_lines.extend(
        [
            "",
            "public func newTwilicCodec() -> TwilicCodec { TwilicCodec() }",
            "public func twilicCodecWithOptions(_ options: SessionOptions) -> TwilicCodec {",
            "    TwilicCodec(state: newSessionStateWithOptions(options))",
            "}",
            "public func newSessionEncoder(_ options: SessionOptions? = nil) -> SessionEncoder {",
            "    SessionEncoder(options: options)",
            "}",
        ]
    )

    OUT_PROTOCOL.write_text("\n".join(protocol_lines) + "\n")
    OUT_HELPERS.write_text("\n".join(helper_lines) + "\n")
    print("wrote stubs - manual port required for bodies")


if __name__ == "__main__":
    main()
