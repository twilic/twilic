#!/usr/bin/env python3
"""Emit R protocol I/O helpers from twilic-php Protocol.php (write/read message paths)."""

from __future__ import annotations

import re
from pathlib import Path

PHP = Path(__file__).resolve().parents[2] / "php" / "src" / "Twilic" / "Protocol.php"
OUT = Path(__file__).resolve().parents[1] / "R" / "protocol_io_messages.R"

# PHP private method names to emit as R twilic_* functions
METHODS = [
    ("writePresence", "twilic_write_presence"),
    ("readPresence", "twilic_read_presence"),
    ("writeStringVector", "twilic_write_string_vector"),
    ("readStringVector", "twilic_read_string_vector"),
    ("writeSchemaFields", "twilic_write_schema_fields"),
    ("readSchemaFields", "twilic_read_schema_fields"),
    ("writeSchemaFieldValue", "twilic_write_schema_field_value"),
    ("readSchemaFieldValue", "twilic_read_schema_field_value"),
    ("writeColumn", "twilic_write_column"),
    ("readColumn", "twilic_read_column"),
    ("writeControl", "twilic_write_control"),
    ("readControl", "twilic_read_control"),
    ("writeBaseRef", "twilic_write_base_ref"),
    ("readBaseRef", "twilic_read_base_ref"),
    ("writeControlStreamPayload", "twilic_write_control_stream_payload"),
    ("readControlStreamPayload", "twilic_read_control_stream_payload"),
]


def php_to_r(body: str) -> str:
    s = body
    s = re.sub(r"/\*\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//.*", "", s)
    s = s.replace("$this->state", "codec$state")
    s = s.replace("$this->", "")
    s = re.sub(r"\$([a-zA-Z_][a-zA-Z0-9_]*)", r"\1", s)
    s = s.replace("->", "$")
    s = s.replace("::", "")
    s = s.replace("new Message(", "new_message(")
    s = s.replace("new TypedVector(", "list(")
    s = s.replace("new TypedVectorData(", "list(")
    s = s.replace("new Column(", "list(")
    s = s.replace("new ControlMessage(", "list(")
    s = s.replace("new RegisterShapeControl(", "list(")
    s = s.replace("new PromoteEnumControl(", "list(")
    s = s.replace("new DictionaryProfile(", "list(")
    s = s.replace("new SchemaObjectMessage(", "list(")
    s = s.replace("new ShapedObjectMessage(", "list(")
    s = s.replace("new RowBatchMessage(", "list(")
    s = s.replace("new ColumnBatchMessage(", "list(")
    s = s.replace("new TemplateBatchMessage(", "list(")
    s = s.replace("new StatePatchMessage(", "list(")
    s = s.replace("new ExtMessage(", "list(")
    s = s.replace("new BaseSnapshotMessage(", "list(")
    s = s.replace("new ControlStreamMessage(", "list(")
    s = s.replace("MessageKind::", "MessageKind")
    s = s.replace("ElementType::", "ElementType")
    s = s.replace("VectorCodec::", "VectorCodec")
    s = s.replace("NullStrategy::", "NullStrategy")
    s = s.replace("ControlOpcode::", "ControlOpcode")
    s = s.replace("ControlStreamCodec::", "ControlStreamCodec")
    s = s.replace("ValueKind::", "ValueKind")
    s = s.replace("DictionaryFallback::", "DictionaryFallback")
    s = s.replace("count(", "length(")
    s = s.replace("array_fill(0, length(", "rep(TRUE, length(")
    s = s.replace("array_key_exists", "exists")
    s = s.replace("strlen", "nchar")
    s = s.replace("substr", "substring")
    s = s.replace("true", "TRUE")
    s = s.replace("false", "FALSE")
    s = s.replace("null", "NULL")
    s = s.replace("!==", "!=")
    s = s.replace("===", "==")
    s = s.replace("throw invalid_", "twilic_stop(invalid_")
    s = s.replace("throw $this->referenceError", "twilic_reference_error(codec,")
    s = s.replace("throw invalid_kind", "twilic_stop(invalid_kind")
    s = s.replace("out->append((int)", "out <- raw_append_byte(out,")
    s = s.replace("out->append(", "out <- raw_append_byte(out, ")
    s = s.replace("writeValue(", "twilic_write_value(codec, ")
    s = s.replace("writeValueWithField(", "twilic_write_value_with_field(codec, ")
    s = s.replace("readValue(", "twilic_read_value(codec, ")
    s = s.replace("readValueWithField(", "twilic_read_value_with_field(codec, ")
    s = s.replace("writeKeyRef(", "twilic_write_key_ref(codec, ")
    s = s.replace("readKeyRef(", "twilic_read_key_ref(codec, ")
    s = s.replace("writeTypedVector(", "twilic_write_typed_vector(codec, ")
    s = s.replace("readTypedVector(", "twilic_read_typed_vector(codec, ")
    s = s.replace("writeMessage(", "twilic_write_message(codec, ")
    s = s.replace("readMessage(", "twilic_read_message(codec, ")
    s = s.replace("writePresence(", "twilic_write_presence(")
    s = s.replace("readPresence(", "twilic_read_presence(")
    s = s.replace("writeColumn(", "twilic_write_column(codec, ")
    s = s.replace("readColumn(", "twilic_read_column(codec, ")
    s = s.replace("writeControl(", "twilic_write_control(codec, ")
    s = s.replace("readControl(", "twilic_read_control(codec, ")
    s = s.replace("writeBaseRef(", "twilic_write_base_ref(")
    s = s.replace("readBaseRef(", "twilic_read_base_ref(codec, ")
    s = s.replace("writeControlStreamPayload(", "twilic_write_control_stream_payload(")
    s = s.replace("readControlStreamPayload(", "twilic_read_control_stream_payload(codec, ")
    s = s.replace("writeStringVector(", "twilic_write_string_vector(codec, ")
    s = s.replace("readStringVector(", "twilic_read_string_vector(codec, ")
    s = s.replace("writeSchemaFields(", "twilic_write_schema_fields(codec, ")
    s = s.replace("readSchemaFields(", "twilic_read_schema_fields(codec, ")
    s = s.replace("writeSchemaFieldValue(", "twilic_write_schema_field_value(codec, ")
    s = s.replace("readSchemaFieldValue(", "twilic_read_schema_field_value(codec, ")
    s = s.replace("clone_typed_vector_data", "typed_vector_data_clone")
    s = s.replace("normalized_logical_type", "normalized_logical_type")
    s = s.replace("schema_present_field_indices", "schema_present_field_indices")
    s = s.replace("register_base_snapshot", "register_base_snapshot")
    s = s.replace("reset_tables", "reset_tables")
    s = s.replace("reset_state", "reset_state")
    s = s.replace("dictionary_payload_hash", "dictionary_payload_hash")
    s = s.replace("decode_trained_dictionary_payload", "decode_trained_dictionary_payload")
    s = s.replace("encode_trained_dictionary_block", "encode_trained_dictionary_block")
    s = s.replace("decode_trained_dictionary_block", "decode_trained_dictionary_block")
    s = s.replace("common_prefix_len", "common_prefix_len")
    s = s.replace("typed_vector_len", "typed_vector_len")
    s = s.replace("key_ref_field_identity", "key_ref_field_identity")
    s = s.replace("key_ref_string", "key_ref_string")
    s = s.replace("twilic_observe_decode_shape_candidate", "twilic_observe_decode_shape_candidate")
    s = s.replace("merge_template_columns", "merge_template_columns")
    s = s.replace("template_descriptor_from_columns", "template_descriptor_from_columns")
    s = s.replace("ByteBuffer $out", "out")
    s = s.replace("Reader $reader", "reader")
    s = s.replace("Message $message", "message")
    s = s.replace("Value $value", "value")
    s = s.replace("Schema $schema", "schema")
    s = s.replace("Column $column", "column")
    s = s.replace("ControlMessage $control", "control")
    s = s.replace("BaseRef $baseRef", "base_ref")
    s = s.replace("TypedVector $vector", "vector")
    s = s.replace("SchemaField $field", "field")
    s = s.replace("ControlStreamCodec $codec", "stream_codec")
    s = s.replace("string $payload", "payload")
    s = s.replace("array $", "")
    s = s.replace("list<", "list(")
    s = s.replace(">", "")
    return s


def extract_method(src: str, name: str) -> str:
    pat = rf"private function {name}\([^)]*\)[^{{]*\{{"
    m = re.search(pat, src)
    if not m:
        raise SystemExit(f"missing method {name}")
    start = m.end()
    depth = 1
    i = start
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[start : i - 1]


def main() -> None:
    src = PHP.read_text()
    parts = [
        "# Auto-generated protocol message I/O from twilic-php Protocol.php",
        "# Do not edit by hand; regenerate with scripts/emit_protocol_io_from_php.py",
        "",
        "typed_vector_data_clone <- function(data) serialize(data, NULL) %>% unserialize()",
        "",
    ]
    for php_name, r_name in METHODS:
        body = extract_method(src, php_name)
        r_body = php_to_r(body)
        parts.append(f"{r_name} <- function(codec, ...) {{")
        parts.append("  stop('emit_protocol_io_from_php.py: manual port required')")
        parts.append("}")
        parts.append("")
    OUT.write_text("\n".join(parts))
    print(f"wrote {OUT} stub with {len(METHODS)} methods")


if __name__ == "__main__":
    main()
