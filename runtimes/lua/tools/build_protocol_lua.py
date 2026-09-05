#!/usr/bin/env python3
"""Emit twilic.core.protocol from twilic-python protocol.py (TwilicCodec + SessionEncoder)."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python" / "src" / "twilic" / "protocol.py"
OUT = Path(__file__).resolve().parents[1] / "src" / "twilic" / "core" / "protocol.lua"
SRC = Path(__file__).resolve().parents[1] / "src"

HEADER = """local errors = require("twilic.core.errors")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local byte_buffer = require("twilic.core.byte_buffer")
local codec_mod = require("twilic.core.codec")
local dictionary = require("twilic.core.dictionary")
local session = require("twilic.core.session")
local ph = require("twilic.core.protocol_helpers")

local M = {}

M.TAG_NULL = 0
M.TAG_BOOL_FALSE = 1
M.TAG_BOOL_TRUE = 2
M.TAG_I64 = 3
M.TAG_U64 = 4
M.TAG_F64 = 5
M.TAG_STRING = 6
M.TAG_BINARY = 7
M.TAG_ARRAY = 8
M.TAG_MAP = 9

local TwilicCodec = {}
local SessionEncoder = {}

"""

FOOTER = """
function M.new_twilic_codec(state)
  return TwilicCodec.new(state)
end

function M.twilic_codec_with_options(options)
  return TwilicCodec.new(session.new_session_state(options))
end

function M.new_session_encoder(options)
  return SessionEncoder.new(options)
end

function M.reset_encode_shape_observation(codec, keys)
  local sk = session.shape_key(keys)
  codec.state.encode_shape_observations[sk] = nil
end

TwilicCodec.new = function(state)
  local self = { state = state or session.new_session_state() }
  return setmetatable(self, { __index = TwilicCodec })
end

SessionEncoder.new = function(options)
  local self = {
    codec = TwilicCodec.new(session.new_session_state(options or session.default_session_options())),
  }
  return setmetatable(self, { __index = SessionEncoder })
end

return M
"""

ENUM = [
    ("MessageKind.", "model.MESSAGE_KIND_"),
    ("ValueKind.", "model.VALUE_"),
    ("VectorCodec.", "model.VECTOR_CODEC_"),
    ("ElementType.", "model.ELEMENT_TYPE_"),
    ("StringMode.", "model.STRING_MODE_"),
    ("NullStrategy.", "model.NULL_STRATEGY_"),
    ("ControlOpcode.", "model.CONTROL_OPCODE_"),
    ("PatchOpcode.", "model.PATCH_OPCODE_"),
    ("ControlStreamCodec.", "model.CONTROL_STREAM_CODEC_"),
    ("UnknownReferencePolicy.", "session.UNKNOWN_REFERENCE_POLICY_"),
    ("DictionaryFallback.", "session.DICTIONARY_FALLBACK_"),
]

REPL = [
    (r"\bnew_null\(\)", "model.null_value()"),
    (r"\bnew_bool\(", "model.bool_value("),
    (r"\bnew_i64\(", "model.i64_value("),
    (r"\bnew_u64\(", "model.u64_value("),
    (r"\bnew_f64\(", "model.f64_value("),
    (r"\bnew_string\(", "model.string_value("),
    (r"\bnew_binary\(", "model.binary_value("),
    (r"\bnew_array\(", "model.array_value("),
    (r"\bnew_map\(", "model.map_value("),
    (r"\bentry\(", "model.entry("),
    (r"\bequal\(", "model.equal("),
    (r"\bMessage\(", "model.message("),
    (r"\bkey_ref_id\(", "model.key_ref_id("),
    (r"\bkey_ref_literal\(", "model.key_ref_literal("),
    (r"\bbase_ref_previous\(\)", "model.base_ref_previous()"),
    (r"\bbase_ref_id\(", "model.base_ref_id("),
    (r"\bencode_varuint\(", "wire.encode_varuint("),
    (r"\bencode_bytes\(", "wire.encode_bytes("),
    (r"\bencode_string\(", "wire.encode_string("),
    (r"\bencode_bitmap\(", "wire.encode_bitmap("),
    (r"\bencode_zigzag\(", "wire.encode_zigzag("),
    (r"\bdecode_zigzag\(", "wire.decode_zigzag("),
    (r"\bappend_f64_le\(", "wire.append_f64_le("),
    (r"\bread_f64_le\(", "wire.read_f64_le("),
    (r"\bnew_reader\(", "wire.new_reader("),
    (r"\bencode_i64_vector\(", "codec_mod.encode_i64_vector("),
    (r"\bdecode_i64_vector\(", "codec_mod.decode_i64_vector("),
    (r"\bencode_u64_vector\(", "codec_mod.encode_u64_vector("),
    (r"\bdecode_u64_vector\(", "codec_mod.decode_u64_vector("),
    (r"\bencode_f64_vector\(", "codec_mod.encode_f64_vector("),
    (r"\bdecode_f64_vector\(", "codec_mod.decode_f64_vector("),
    (r"\binvalid_data\(", "errors.invalid_data("),
    (r"\binvalid_tag\(", "errors.invalid_tag("),
    (r"\binvalid_kind\(", "errors.invalid_kind("),
    (r"\bunknown_reference\(", "errors.unknown_reference("),
    (r"\bstateless_retry_required\(", "errors.stateless_retry_required("),
    (r"\bis_unknown_reference\(", "errors.is_unknown_reference("),
    (r"\bis_stateless_retry\(", "errors.is_stateless_retry("),
    (r"\bnew_session_state\(", "session.new_session_state("),
    (r"\bnew_session_state_with_options\(", "session.new_session_state("),
    (r"\bdefault_session_options\(\)", "session.default_session_options()"),
    (r"\breset_state\(", "session.reset_state("),
    (r"\breset_tables\(", "session.reset_tables("),
    (r"\bregister_base_snapshot\(", "session.register_base_snapshot("),
    (r"\bget_base_snapshot\(", "session.get_base_snapshot("),
    (r"\ballocate_base_id\(", "session.allocate_base_id("),
    (r"\ballocate_template_id\(", "session.allocate_template_id("),
    (r"\bshape_key\(", "session.shape_key("),
    (r"\bmessage_kind_from_byte\(", "model.message_kind_from_byte("),
    (r"\bvector_codec_from_byte\(", "model.vector_codec_from_byte("),
    (r"\belement_type_from_byte\(", "model.element_type_from_byte("),
    (r"\bstring_mode_from_byte\(", "model.string_mode_from_byte("),
    (r"\bnull_strategy_from_byte\(", "model.null_strategy_from_byte("),
    (r"\bcontrol_opcode_from_byte\(", "model.control_opcode_from_byte("),
    (r"\bpatch_opcode_from_byte\(", "model.patch_opcode_from_byte("),
    (r"\bcontrol_stream_codec_from_byte\(", "model.control_stream_codec_from_byte("),
    (r"\bdictionary_fallback_from_byte\(", "session.dictionary_fallback_from_byte("),
    (r"\btyped_vector_len\(", "ph.typed_vector_len("),
    (r"\bselect_integer_codec\(", "ph.select_integer_codec("),
    (r"\bselect_u64_codec\(", "ph.select_u64_codec("),
    (r"\bselect_float_codec\(", "ph.select_float_codec("),
    (r"\bselect_string_codec\(", "ph.select_string_codec("),
    (r"\brows_to_columns\(", "ph.rows_to_columns("),
    (r"\bcolumns_from_map_values\(", "ph.columns_from_map_values("),
    (r"\brows_from_values\(", "ph.rows_from_values("),
    (r"\bdiff_message\(", "ph.diff_message("),
    (r"\bmessage_fields\(", "ph.message_fields("),
    (r"\brebuild_message_like\(", "ph.rebuild_message_like("),
    (r"\bentries_to_map\(", "ph.entries_to_map("),
    (r"\bshape_values_to_map\(", "ph.shape_values_to_map("),
    (r"\bkey_ref_string\(", "ph.key_ref_string("),
    (r"\bkey_ref_field_identity\(", "ph.key_ref_field_identity("),
    (r"\btyped_vector_to_value\(", "ph.typed_vector_to_value("),
    (r"\bencoded_size\(", "ph.encoded_size("),
    (r"\bsupports_state_patch\(", "ph.supports_state_patch("),
    (r"\bhas_uniform_micro_batch_shape\(", "ph.has_uniform_micro_batch_shape("),
    (r"\bfind_template_id\(", "ph.find_template_id("),
    (r"\bdiff_template_columns\(", "ph.diff_template_columns("),
    (r"\bmerge_template_columns\(", "ph.merge_template_columns("),
    (r"\btemplate_descriptor_from_columns\(", "ph.template_descriptor_from_columns("),
    (r"\bapply_dictionary_references\(", "dictionary.apply_dictionary_references("),
    (r"\bdecode_trained_dictionary_payload\(", "dictionary.decode_trained_dictionary_payload("),
    (r"\bencode_trained_dictionary_block\(", "dictionary.encode_trained_dictionary_block("),
    (r"\bdecode_trained_dictionary_block\(", "dictionary.decode_trained_dictionary_block("),
    (r"\bdictionary_payload_hash\(", "dictionary.dictionary_payload_hash("),
    (r"\bcommon_prefix_len\(", "ph.common_prefix_len("),
    (r"\brle_encode_bytes\(", "ph.rle_encode_bytes("),
    (r"\brle_decode_bytes\(", "ph.rle_decode_bytes("),
    (r"\bcontrol_bitpack_encode_bytes\(", "ph.control_bitpack_encode_bytes("),
    (r"\bcontrol_bitpack_decode_bytes\(", "ph.control_bitpack_decode_bytes("),
    (r"\bcontrol_huffman_encode_bytes\(", "ph.control_huffman_encode_bytes("),
    (r"\bcontrol_huffman_decode_bytes\(", "ph.control_huffman_decode_bytes("),
    (r"\bcontrol_fse_encode_bytes\(", "ph.control_fse_encode_bytes("),
    (r"\bcontrol_fse_decode_bytes\(", "ph.control_fse_decode_bytes("),
    (r"\bwrite_smallest_u64\(", "ph.write_smallest_u64("),
    (r"\bread_smallest_u64\(", "ph.read_smallest_u64("),
    (r"\bschema_present_field_indices\(", "ph.schema_present_field_indices("),
    (r"\bnormalized_logical_type\(", "ph.normalized_logical_type("),
    (r"\blookup_map_field\(", "ph.lookup_map_field("),
    (r"\bclone_typed_vector_data\(", "model.clone_typed_vector_data("),
    (r"\bshould_register_shape\(", "ph.should_register_shape("),
]


def extract_class(name: str, text: str) -> str:
    pat = rf"^class {name}:.*?(?=^class |\ndef new_twilic_codec|\Z)"
    m = re.search(pat, text, re.MULTILINE | re.DOTALL)
    if not m:
        raise SystemExit(f"class {name} not found")
    return m.group(0)


def convert_method_body(body: str) -> str:
    lines_out: list[str] = []
    indent_stack = [0]

    def cur_ind() -> str:
        return "  " * indent_stack[-1]

    for raw in body.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        if line.strip().startswith("from ") or line.strip().startswith("import "):
            continue

        # def line
        m = re.match(r"(\s*)def (\w+)\(self(?:, ([^)]*))?\)", line)
        if m:
            ind, name, params = m.group(1), m.group(2), m.group(3) or ""
            params = re.sub(r":[^,)]+", "", params)
            params = params.strip()
            lua_name = name[1:] if name.startswith("_") else name
            lua_params = "self" + (", " + params if params else "")
            lines_out.append(f"{ind}function TwilicCodec.{lua_name}({lua_params})")
            indent_stack = [len(ind) // 4 + 1]
            continue

        m = re.match(r"(\s*)def (\w+)\(self, options", line)
        if m and "SessionEncoder" in body[:200]:
            continue

        s = line
        s = re.sub(r"^(\s*)", lambda mm: "  " * (len(mm.group(1)) // 4 + indent_stack[-1]), s, count=1)
        s = s.replace("True", "true").replace("False", "false").replace("None", "nil")
        s = re.sub(r"\band\b", " and ", s)
        s = re.sub(r"\bor\b", " or ", s)
        s = re.sub(r"\bnot\b", " not ", s)
        s = re.sub(r"\blen\(([^)]+)\)", r"#\1", s)
        s = re.sub(r"\bbytearray\(\)", "byte_buffer.new()", s)
        s = re.sub(r"\bbytes\(out\)", "byte_buffer.bytes(out)", s)
        s = re.sub(r"out\.append\(([^)]+)\)", r"byte_buffer.append(out, \1)", s)
        s = re.sub(r"reader\.read_varuint\(\)", "reader:read_varuint()", s)
        s = re.sub(r"reader\.read_u8\(\)", "reader:read_u8()", s)
        s = re.sub(r"reader\.read_bytes\(\)", "reader:read_bytes()", s)
        s = re.sub(r"reader\.read_string\(\)", "reader:read_string()", s)
        s = re.sub(r"reader\.read_bitmap\(\)", "reader:read_bitmap()", s)
        s = re.sub(r"reader\.is_eof\(\)", "reader:is_eof()", s)
        s = re.sub(r"self\.state\.(\w+)", r"self.state.\1", s)
        s = re.sub(r"self\.state\.key_table\.get_id\(", "session.intern_get_id(self.state.key_table, ", s)
        s = re.sub(r"self\.state\.key_table\.register\(", "session.intern_register(self.state.key_table, ", s)
        s = re.sub(r"self\.state\.key_table\.get_value\(", "session.intern_get_value(self.state.key_table, ", s)
        s = re.sub(r"self\.state\.string_table\.get_id\(", "session.intern_get_id(self.state.string_table, ", s)
        s = re.sub(r"self\.state\.string_table\.register\(", "session.intern_register(self.state.string_table, ", s)
        s = re.sub(r"self\.state\.string_table\.get_value\(", "session.intern_get_value(self.state.string_table, ", s)
        s = re.sub(r"self\.state\.shape_table\.get_id\(", "session.shape_get_id(self.state.shape_table, ", s)
        s = re.sub(r"self\.state\.shape_table\.get_keys\(", "session.shape_get_keys(self.state.shape_table, ", s)
        s = re.sub(r"self\.state\.shape_table\.register\(", "session.shape_register(self.state.shape_table, ", s)
        s = re.sub(r"self\.state\.shape_table\.register_with_id\(", "session.shape_register_with_id(self.state.shape_table, ", s)
        s = re.sub(r"self\.state\.shape_table\.observe\(", "session.shape_observe(self.state.shape_table, ", s)
        s = re.sub(r"raise invalid_data", "errors.raise(errors.invalid_data", s)
        s = re.sub(r"raise invalid_tag", "errors.raise(errors.invalid_tag", s)
        s = re.sub(r"raise invalid_kind", "errors.raise(errors.invalid_kind", s)
        s = re.sub(r"raise self\._reference_error", "errors.raise(TwilicCodec.reference_error(self", s)
        s = re.sub(r"raise self\.reference_error", "errors.raise(TwilicCodec.reference_error(self", s)
        if "errors.raise(errors." in s and s.count("(") > s.count(")"):
            s = s + ")"
        s = re.sub(r"return self\._reference_error", "return TwilicCodec.reference_error(self", s)
        s = re.sub(r"self\._(\w+)\(", r"TwilicCodec.\1(self, ", s)
        s = re.sub(r"msg\.clone\(\)", "model.clone_message(msg)", s)
        s = re.sub(r"value\.clone\(\)", "model.clone_value(value)", s)
        s = re.sub(r"\.clone\(\)", ".clone_value()", s)
        s = re.sub(r"for _ in range\(([^)]+)\)", r"for _ = 1, \1 do", s)
        s = re.sub(r"for (\w+) in range\(([^)]+)\)", r"for \1 = 1, \2 do", s)
        s = re.sub(r"for (\w+), (\w+) in enumerate\(([^)]+)\)", r"for \2, \1 in ipairs(\3) do", s)
        s = re.sub(r"for (\w+) in (\w+):", r"for _, \1 in ipairs(\2) do", s)
        s = re.sub(r"if (\w+) is None:", r"if \1 == nil then", s)
        s = re.sub(r"elif ", "elseif ", s)
        s = re.sub(r"assert .+", "", s)
        for k, v in ENUM:
            s = s.replace(k, v)
        for pat, rep in REPL:
            s = re.sub(pat, rep, s)
        # match/case rough
        m2 = re.match(r"(\s*)match (\w+.*):", s)
        if m2:
            s = f"{m2.group(1)}if true then -- match {m2.group(2)}"
        if s.strip().startswith("case "):
            ce = s.strip()[5:].rstrip(":")
            s = re.sub(r"case (.+):", r"elseif \1 then", s.strip())
            s = "  " * indent_stack[-1] + s.replace("elseif _", "else")
        if s.strip() == "pass":
            continue
        lines_out.append(s)
    lines_out.append(cur_ind() + "end")
    return "\n".join(lines_out)


def convert_session_encoder(text: str) -> str:
    out = ["function SessionEncoder.encode(self, value)"]
    out.append("  local msg = TwilicCodec.message_for_value(self.codec, value)")
    out.append("  if self.codec.state.options.enable_state_patch and self.codec.state.previous_message")
    out.append("      and ph.supports_state_patch(self.codec.state.previous_message, msg) then")
    out.append("    local ops = ph.diff_message(self.codec.state.previous_message, msg)")
    out.append("    local patch_msg = model.message({")
    out.append("      kind = model.MESSAGE_KIND_STATE_PATCH,")
    out.append("      state_patch = { base_ref = model.base_ref_previous(), operations = ops, literals = {} },")
    out.append("    })")
    out.append("    if ph.encoded_size(patch_msg) < ph.encoded_size(msg) then")
    out.append("      local ok, result = pcall(TwilicCodec.encode_message, self.codec, patch_msg)")
    out.append("      if ok then return result end")
    out.append("    end")
    out.append("  end")
    out.append("  return TwilicCodec.encode_message(self.codec, msg)")
    out.append("end")
    out.append("")
    out.append("function SessionEncoder.encode_with_schema(self, schema, value)")
    out.append("  self.codec.state.schemas[schema.schema_id] = schema")
    out.append("  self.codec.state.last_schema_id = schema.schema_id")
    out.append("  for i = 1, #schema.fields do")
    out.append("    local f = schema.fields[i]")
    out.append("    if f.enum_values then self.codec.state.field_enums[f.name] = f.enum_values end")
    out.append("  end")
    out.append("  if value.kind ~= model.VALUE_MAP then")
    out.append("    errors.raise(errors.invalid_data('encode_with_schema expects map value'))")
    out.append("  end")
    out.append("  local presence, fields, has_presence = {}, {}, false")
    out.append("  for i = 1, #schema.fields do")
    out.append("    local f = schema.fields[i]")
    out.append("    local v = ph.lookup_map_field(value, f.name)")
    out.append("    if v then")
    out.append("      presence[i] = true")
    out.append("      fields[i] = model.clone_value(v)")
    out.append("    else")
    out.append("      presence[i] = false")
    out.append("      has_presence = true")
    out.append("    end")
    out.append("  end")
    out.append("  local msg = model.message({")
    out.append("    kind = model.MESSAGE_KIND_SCHEMA_OBJECT,")
    out.append("    schema_object = { schema_id = schema.schema_id, presence = presence, has_presence = has_presence, fields = fields },")
    out.append("  })")
    out.append("  return TwilicCodec.encode_message(self.codec, msg)")
    out.append("end")
    out.append("")
    out.append("function SessionEncoder.encode_batch(self, values)")
    out.append("  local msg")
    out.append("  if #values == 0 then")
    out.append("    msg = model.message({ kind = model.MESSAGE_KIND_ROW_BATCH, row_batch = { rows = {} } })")
    out.append("  elseif #values >= 16 then")
    out.append("    local cols = ph.columns_from_map_values(values)")
    out.append("    if not cols then cols = ph.rows_to_columns(ph.rows_from_values(values)) end")
    out.append("    if self.codec.state.options.enable_trained_dictionary then")
    out.append("      dictionary.apply_dictionary_references(self.codec.state, cols)")
    out.append("    end")
    out.append("    msg = model.message({ kind = model.MESSAGE_KIND_COLUMN_BATCH, column_batch = { count = #values, columns = cols } })")
    out.append("  else")
    out.append("    msg = model.message({ kind = model.MESSAGE_KIND_ROW_BATCH, row_batch = { rows = ph.rows_from_values(values) } })")
    out.append("  end")
    out.append("  local data = TwilicCodec.encode_message(self.codec, msg)")
    out.append("  self.codec.state.previous_message = model.clone_message(msg)")
    out.append("  self.codec.state.previous_message_size = #data")
    out.append("  SessionEncoder.record_full_message_as_base(self)")
    out.append("  return data")
    out.append("end")
    out.append("")
    out.append("function SessionEncoder.encode_patch(self, value)")
    out.append("  local msg = TwilicCodec.message_for_value(self.codec, value)")
    out.append("  if not self.codec.state.previous_message or not ph.supports_state_patch(self.codec.state.previous_message, msg) then")
    out.append("    return TwilicCodec.encode_message(self.codec, msg)")
    out.append("  end")
    out.append("  local ops = ph.diff_message(self.codec.state.previous_message, msg)")
    out.append("  local patch_msg = model.message({")
    out.append("    kind = model.MESSAGE_KIND_STATE_PATCH,")
    out.append("    state_patch = { base_ref = model.base_ref_previous(), operations = ops, literals = {} },")
    out.append("  })")
    out.append("  if ph.encoded_size(patch_msg) >= ph.encoded_size(msg) then")
    out.append("    return TwilicCodec.encode_message(self.codec, msg)")
    out.append("  end")
    out.append("  return TwilicCodec.encode_message(self.codec, patch_msg)")
    out.append("end")
    out.append("")
    out.append("function SessionEncoder.encode_micro_batch(self, values)")
    out.append("  if #values == 0 then return SessionEncoder.encode_batch(self, values) end")
    out.append("  if not self.codec.state.options.enable_template_batch or not ph.has_uniform_micro_batch_shape(values) then")
    out.append("    return SessionEncoder.encode_batch(self, values)")
    out.append("  end")
    out.append("  local columns = ph.columns_from_map_values(values)")
    out.append("  if not columns then columns = ph.rows_to_columns(ph.rows_from_values(values)) end")
    out.append("  if self.codec.state.options.enable_trained_dictionary then")
    out.append("    dictionary.apply_dictionary_references(self.codec.state, columns)")
    out.append("  end")
    out.append("  local template_id, ok = ph.find_template_id(self.codec.state.templates, columns)")
    out.append("  if not ok then")
    out.append("    template_id = session.allocate_template_id(self.codec.state)")
    out.append("    self.codec.state.templates[template_id] = ph.template_descriptor_from_columns(template_id, columns)")
    out.append("    self.codec.state.template_columns[template_id] = columns")
    out.append("    local mask = {}")
    out.append("    for i = 1, #columns do mask[i] = true end")
    out.append("    local msg = model.message({")
    out.append("      kind = model.MESSAGE_KIND_TEMPLATE_BATCH,")
    out.append("      template_batch = { template_id = template_id, count = #values, changed_column_mask = mask, columns = columns },")
    out.append("    })")
    out.append("    return TwilicCodec.encode_message(self.codec, msg)")
    out.append("  end")
    out.append("  local mask, changed_cols = ph.diff_template_columns(self.codec.state.template_columns[template_id], columns)")
    out.append("  self.codec.state.template_columns[template_id] = columns")
    out.append("  local msg = model.message({")
    out.append("    kind = model.MESSAGE_KIND_TEMPLATE_BATCH,")
    out.append("    template_batch = { template_id = template_id, count = #values, changed_column_mask = mask, columns = changed_cols },")
    out.append("  })")
    out.append("  return TwilicCodec.encode_message(self.codec, msg)")
    out.append("end")
    out.append("")
    out.append("function SessionEncoder.reset(self)")
    out.append("  session.reset_state(self.codec.state)")
    out.append("end")
    out.append("")
    out.append("function SessionEncoder.decode_message(self, data)")
    out.append("  return TwilicCodec.decode_message(self.codec, data)")
    out.append("end")
    out.append("")
    out.append("function SessionEncoder.record_full_message_as_base(self)")
    out.append("  if self.codec.state.options.max_base_snapshots == 0 then return end")
    out.append("  if not self.codec.state.previous_message then return end")
    out.append("  local base_id = session.allocate_base_id(self.codec.state)")
    out.append("  session.register_base_snapshot(self.codec.state, base_id, self.codec.state.previous_message)")
    out.append("end")
    return "\n".join(out)


def main() -> None:
    text = PY.read_text()
    codec_cls = extract_class("TwilicCodec", text)
    # Split into methods and convert each - simplified: use HAND_PORTED from file if exists
    hand = Path(__file__).with_name("protocol_hand.lua")
    if hand.exists():
        body = hand.read_text()
    else:
        body = convert_method_body(codec_cls)
    session_body = convert_session_encoder(text)
    OUT.write_text(HEADER + body + "\n" + session_body + FOOTER)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
    r = subprocess.run(
        ["/opt/homebrew/bin/lua", "-e", 'require("twilic.core.protocol")'],
        cwd=SRC,
        env={"LUA_PATH": "?.lua;?/init.lua"},
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print("LOAD ERROR:", r.stderr[:2000])
    else:
        print("protocol.lua loads OK")


if __name__ == "__main__":
    main()
