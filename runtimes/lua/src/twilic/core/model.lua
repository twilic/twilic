--- Twilic data model types.
local M = {}

M.MAX_U64 = 0xFFFFFFFFFFFFFFFF
M.MIN_I64 = -0x8000000000000000
M.MAX_I64 = 0x7FFFFFFFFFFFFFFF

M.MESSAGE_KIND_SCALAR = 0x00
M.MESSAGE_KIND_ARRAY = 0x01
M.MESSAGE_KIND_MAP = 0x02
M.MESSAGE_KIND_SHAPED_OBJECT = 0x03
M.MESSAGE_KIND_SCHEMA_OBJECT = 0x04
M.MESSAGE_KIND_TYPED_VECTOR = 0x05
M.MESSAGE_KIND_ROW_BATCH = 0x06
M.MESSAGE_KIND_COLUMN_BATCH = 0x07
M.MESSAGE_KIND_CONTROL = 0x08
M.MESSAGE_KIND_EXT = 0x09
M.MESSAGE_KIND_STATE_PATCH = 0x0A
M.MESSAGE_KIND_TEMPLATE_BATCH = 0x0B
M.MESSAGE_KIND_CONTROL_STREAM = 0x0C
M.MESSAGE_KIND_BASE_SNAPSHOT = 0x0D

function M.message_kind_from_byte(b)
  local kinds = {
    [0x00]=M.MESSAGE_KIND_SCALAR,[0x01]=M.MESSAGE_KIND_ARRAY,[0x02]=M.MESSAGE_KIND_MAP,
    [0x03]=M.MESSAGE_KIND_SHAPED_OBJECT,[0x04]=M.MESSAGE_KIND_SCHEMA_OBJECT,
    [0x05]=M.MESSAGE_KIND_TYPED_VECTOR,[0x06]=M.MESSAGE_KIND_ROW_BATCH,
    [0x07]=M.MESSAGE_KIND_COLUMN_BATCH,[0x08]=M.MESSAGE_KIND_CONTROL,
    [0x09]=M.MESSAGE_KIND_EXT,[0x0A]=M.MESSAGE_KIND_STATE_PATCH,
    [0x0B]=M.MESSAGE_KIND_TEMPLATE_BATCH,[0x0C]=M.MESSAGE_KIND_CONTROL_STREAM,
    [0x0D]=M.MESSAGE_KIND_BASE_SNAPSHOT,
  }
  local k = kinds[b]
  if k then return k, true end
  return M.MESSAGE_KIND_SCALAR, false
end

M.VALUE_NULL = 0
M.VALUE_BOOL = 1
M.VALUE_I64 = 2
M.VALUE_U64 = 3
M.VALUE_F64 = 4
M.VALUE_STRING = 5
M.VALUE_BINARY = 6
M.VALUE_ARRAY = 7
M.VALUE_MAP = 8

M.ELEMENT_TYPE_BOOL = 0
M.ELEMENT_TYPE_I64 = 1
M.ELEMENT_TYPE_U64 = 2
M.ELEMENT_TYPE_F64 = 3
M.ELEMENT_TYPE_STRING = 4
M.ELEMENT_TYPE_BINARY = 5
M.ELEMENT_TYPE_VALUE = 6

function M.element_type_from_byte(b)
  if b >= 0 and b <= 6 then return b, true end
  return M.ELEMENT_TYPE_BOOL, false
end

M.VECTOR_CODEC_PLAIN = 0
M.VECTOR_CODEC_DIRECT_BITPACK = 1
M.VECTOR_CODEC_DELTA_BITPACK = 2
M.VECTOR_CODEC_FOR_BITPACK = 3
M.VECTOR_CODEC_DELTA_FOR_BITPACK = 4
M.VECTOR_CODEC_DELTA_DELTA_BITPACK = 5
M.VECTOR_CODEC_RLE = 6
M.VECTOR_CODEC_PATCHED_FOR = 7
M.VECTOR_CODEC_SIMPLE8B = 8
M.VECTOR_CODEC_XOR_FLOAT = 9
M.VECTOR_CODEC_DICTIONARY = 10
M.VECTOR_CODEC_STRING_REF = 11
M.VECTOR_CODEC_PREFIX_DELTA = 12

function M.vector_codec_from_byte(b)
  if b <= 12 then return b, true end
  return M.VECTOR_CODEC_PLAIN, false
end

M.STRING_MODE_EMPTY = 0
M.STRING_MODE_LITERAL = 1
M.STRING_MODE_REF = 2
M.STRING_MODE_PREFIX_DELTA = 3
M.STRING_MODE_INLINE_ENUM = 4

function M.string_mode_from_byte(b)
  if b >= 0 and b <= 4 then return b, true end
  return M.STRING_MODE_EMPTY, false
end

M.NULL_STRATEGY_NONE = 0
M.NULL_STRATEGY_PRESENCE_BITMAP = 1
M.NULL_STRATEGY_INVERTED_PRESENCE_BITMAP = 2
M.NULL_STRATEGY_ALL_PRESENT_ELIDED = 3

function M.null_strategy_from_byte(b)
  if b >= 0 and b <= 3 then return b, true end
  return M.NULL_STRATEGY_NONE, false
end

M.CONTROL_OPCODE_REGISTER_KEYS = 0
M.CONTROL_OPCODE_REGISTER_SHAPE = 1
M.CONTROL_OPCODE_REGISTER_STRINGS = 2
M.CONTROL_OPCODE_PROMOTE_STRING_FIELD_TO_ENUM = 3
M.CONTROL_OPCODE_RESET_TABLES = 4
M.CONTROL_OPCODE_RESET_STATE = 5

function M.control_opcode_from_byte(b)
  if b >= 0 and b <= 5 then return b, true end
  return M.CONTROL_OPCODE_REGISTER_KEYS, false
end

M.PATCH_OPCODE_KEEP = 0
M.PATCH_OPCODE_REPLACE_SCALAR = 1
M.PATCH_OPCODE_REPLACE_VECTOR = 2
M.PATCH_OPCODE_APPEND_VECTOR = 3
M.PATCH_OPCODE_TRUNCATE_VECTOR = 4
M.PATCH_OPCODE_DELETE_FIELD = 5
M.PATCH_OPCODE_INSERT_FIELD = 6
M.PATCH_OPCODE_STRING_REF = 7
M.PATCH_OPCODE_PREFIX_DELTA = 8

function M.patch_opcode_from_byte(b)
  if b <= 8 then return b, true end
  return M.PATCH_OPCODE_KEEP, false
end

M.CONTROL_STREAM_CODEC_PLAIN = 0
M.CONTROL_STREAM_CODEC_RLE = 1
M.CONTROL_STREAM_CODEC_BITPACK = 2
M.CONTROL_STREAM_CODEC_HUFFMAN = 3
M.CONTROL_STREAM_CODEC_FSE = 4

function M.control_stream_codec_from_byte(b)
  if b <= 4 then return b, true end
  return M.CONTROL_STREAM_CODEC_PLAIN, false
end

function M.empty_value_fields()
  return {
    kind = M.VALUE_NULL, bool = false, i64 = 0, u64 = 0, f64 = 0.0,
    str = "", bin = "", arr = {}, map = {},
  }
end

function M.null_value()
  return M.empty_value_fields()
end

function M.bool_value(b)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_BOOL
  v.bool = b
  return v
end

function M.i64_value(n)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_I64
  v.i64 = n
  return v
end

function M.u64_value(n)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_U64
  v.u64 = n & M.MAX_U64
  return v
end

function M.f64_value(n)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_F64
  v.f64 = n
  return v
end

function M.string_value(s)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_STRING
  v.str = s
  return v
end

function M.binary_value(b)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_BINARY
  v.bin = b
  return v
end

function M.array_value(items)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_ARRAY
  v.arr = {}
  for i = 1, #items do
    v.arr[i] = M.clone_value(items[i])
  end
  return v
end

function M.entry(key, value)
  return { key = key, value = value }
end

function M.map_value(entries)
  local v = M.empty_value_fields()
  v.kind = M.VALUE_MAP
  v.map = {}
  if type(entries) ~= "table" then
    return v
  end
  -- Array of MapEntry tables (preferred; matches PHP variadic entry order).
  if entries[1] ~= nil and type(entries[1]) == "table" and entries[1].key ~= nil then
    for i = 1, #entries do
      local e = entries[i]
      v.map[i] = { key = e.key, value = M.clone_value(e.value) }
    end
    return v
  end
  -- Record-style map; preserve insertion order (Lua 5.4+).
  if entries.kind == nil then
    local i = 0
    for k, val in pairs(entries) do
      if type(k) == "string" then
        i = i + 1
        v.map[i] = { key = k, value = M.clone_value(val) }
      end
    end
  end
  return v
end

function M.key_ref_literal(s)
  return { literal = s, id = 0, is_id = false }
end

function M.key_ref_id(ref_id)
  return { literal = "", id = ref_id, is_id = true }
end

function M.base_ref_previous()
  return { previous = true, base_id = 0 }
end

function M.base_ref_id(ref_id)
  return { previous = false, base_id = ref_id }
end

function M.typed_vector_data(kind)
  return {
    kind = kind, bools = {}, i64s = {}, u64s = {}, f64s = {},
    strings = {}, binary = {}, values = {},
  }
end

function M.message(opts)
  opts = opts or {}
  return {
    kind = opts.kind or M.MESSAGE_KIND_SCALAR,
    scalar = opts.scalar,
    array = opts.array,
    map = opts.map,
    shaped_object = opts.shaped_object,
    schema_object = opts.schema_object,
    typed_vector = opts.typed_vector,
    row_batch = opts.row_batch,
    column_batch = opts.column_batch,
    control = opts.control,
    ext = opts.ext,
    state_patch = opts.state_patch,
    template_batch = opts.template_batch,
    control_stream = opts.control_stream,
    base_snapshot = opts.base_snapshot,
  }
end

function M.is_scalar(v)
  return v.kind ~= M.VALUE_ARRAY and v.kind ~= M.VALUE_MAP
end

function M.equal(a, b)
  if a.kind ~= b.kind then return false end
  if a.kind == M.VALUE_NULL then return true end
  if a.kind == M.VALUE_BOOL then return a.bool == b.bool end
  if a.kind == M.VALUE_I64 then return a.i64 == b.i64 end
  if a.kind == M.VALUE_U64 then return a.u64 == b.u64 end
  if a.kind == M.VALUE_F64 then return a.f64 == b.f64 end
  if a.kind == M.VALUE_STRING then return a.str == b.str end
  if a.kind == M.VALUE_BINARY then return a.bin == b.bin end
  if a.kind == M.VALUE_ARRAY then
    if #a.arr ~= #b.arr then return false end
    for i = 1, #a.arr do
      if not M.equal(a.arr[i], b.arr[i]) then return false end
    end
    return true
  end
  if a.kind == M.VALUE_MAP then
    if #a.map ~= #b.map then return false end
    for i = 1, #a.map do
      if a.map[i].key ~= b.map[i].key then return false end
      if not M.equal(a.map[i].value, b.map[i].value) then return false end
    end
    return true
  end
  return false
end

function M.clone_value(v)
  if v.kind == M.VALUE_NULL or v.kind == M.VALUE_BOOL or v.kind == M.VALUE_I64
      or v.kind == M.VALUE_U64 or v.kind == M.VALUE_F64 or v.kind == M.VALUE_STRING then
    local c = M.empty_value_fields()
    c.kind = v.kind
    c.bool, c.i64, c.u64, c.f64, c.str = v.bool, v.i64, v.u64, v.f64, v.str
    return c
  end
  if v.kind == M.VALUE_BINARY then
    return M.binary_value(v.bin)
  end
  if v.kind == M.VALUE_ARRAY then
    return M.array_value(v.arr)
  end
  if v.kind == M.VALUE_MAP then
    return M.map_value(v.map)
  end
  return M.null_value()
end

function M.clone_typed_vector_data(d)
  return {
    kind = d.kind,
    bools = (function() local t={} for i=1,#d.bools do t[i]=d.bools[i] end return t end)(),
    i64s = (function() local t={} for i=1,#d.i64s do t[i]=d.i64s[i] end return t end)(),
    u64s = (function() local t={} for i=1,#d.u64s do t[i]=d.u64s[i] end return t end)(),
    f64s = (function() local t={} for i=1,#d.f64s do t[i]=d.f64s[i] end return t end)(),
    strings = (function() local t={} for i=1,#d.strings do t[i]=d.strings[i] end return t end)(),
    binary = (function() local t={} for i=1,#d.binary do t[i]=d.binary[i] end return t end)(),
    values = (function() local t={} for i=1,#d.values do t[i]=M.clone_value(d.values[i]) end return t end)(),
  }
end

function M.clone_typed_vector(tv)
  if not tv then return nil end
  local out = M.typed_vector_data(tv.element_type)
  local d = tv.data
  if tv.element_type == M.ELEMENT_TYPE_BOOL then
    for i = 1, #d.bools do out.bools[i] = d.bools[i] end
  elseif tv.element_type == M.ELEMENT_TYPE_I64 then
    for i = 1, #d.i64s do out.i64s[i] = d.i64s[i] end
  elseif tv.element_type == M.ELEMENT_TYPE_U64 then
    for i = 1, #d.u64s do out.u64s[i] = d.u64s[i] end
  elseif tv.element_type == M.ELEMENT_TYPE_F64 then
    for i = 1, #d.f64s do out.f64s[i] = d.f64s[i] end
  elseif tv.element_type == M.ELEMENT_TYPE_STRING then
    for i = 1, #d.strings do out.strings[i] = d.strings[i] end
  elseif tv.element_type == M.ELEMENT_TYPE_BINARY then
    for i = 1, #d.binary do out.binary[i] = d.binary[i] end
  elseif tv.element_type == M.ELEMENT_TYPE_VALUE then
    for i = 1, #d.values do out.values[i] = M.clone_value(d.values[i]) end
  end
  return { element_type = tv.element_type, codec = tv.codec, data = out }
end

function M.clone_column(c)
  local pres
  if c.has_presence and c.presence then
    pres = {}
    for i = 1, #c.presence do pres[i] = c.presence[i] end
  end
  return {
    field_id = c.field_id,
    null_strategy = c.null_strategy,
    presence = pres,
    has_presence = c.has_presence,
    codec = c.codec,
    dictionary_id = c.dictionary_id,
    values = M.clone_typed_vector_data(c.values),
  }
end

function M.clone_control(c)
  if not c then return nil end
  local rs
  if c.register_shape then
    local keys = {}
    for i = 1, #c.register_shape.keys do keys[i] = c.register_shape.keys[i] end
    rs = { shape_id = c.register_shape.shape_id, keys = keys }
  end
  local pe
  if c.promote_string_field_to_enum then
    local vals = {}
    for i = 1, #c.promote_string_field_to_enum.values do
      vals[i] = c.promote_string_field_to_enum.values[i]
    end
    pe = {
      field_identity = c.promote_string_field_to_enum.field_identity,
      values = vals,
    }
  end
  local rk, rs2 = {}, {}
  for i = 1, #(c.register_keys or {}) do rk[i] = c.register_keys[i] end
  for i = 1, #(c.register_strings or {}) do rs2[i] = c.register_strings[i] end
  return {
    opcode = c.opcode,
    register_keys = rk,
    register_shape = rs,
    register_strings = rs2,
    promote_string_field_to_enum = pe,
    reset_tables = c.reset_tables,
    reset_state = c.reset_state,
  }
end

function M.clone_message(msg)
  local k = msg.kind
  if k == M.MESSAGE_KIND_SCALAR then
    return M.message({ kind = k, scalar = M.clone_value(msg.scalar or M.null_value()) })
  elseif k == M.MESSAGE_KIND_ARRAY then
    local arr = {}
    for i = 1, #(msg.array or {}) do arr[i] = M.clone_value(msg.array[i]) end
    return M.message({ kind = k, array = arr })
  elseif k == M.MESSAGE_KIND_MAP then
    local m = {}
    for i = 1, #(msg.map or {}) do
      m[i] = { key = msg.map[i].key, value = M.clone_value(msg.map[i].value) }
    end
    return M.message({ kind = k, map = m })
  elseif k == M.MESSAGE_KIND_SHAPED_OBJECT then
    local s = msg.shaped_object
    local vals, pres = {}, nil
    for i = 1, #s.values do vals[i] = M.clone_value(s.values[i]) end
    if s.has_presence and s.presence then
      pres = {}
      for i = 1, #s.presence do pres[i] = s.presence[i] end
    end
    return M.message({
      kind = k,
      shaped_object = {
        shape_id = s.shape_id, values = vals,
        has_presence = s.has_presence, presence = pres,
      },
    })
  elseif k == M.MESSAGE_KIND_SCHEMA_OBJECT then
    local s = msg.schema_object
    local fields, pres = {}, nil
    for i = 1, #s.fields do fields[i] = M.clone_value(s.fields[i]) end
    if s.has_presence and s.presence then
      pres = {}
      for i = 1, #s.presence do pres[i] = s.presence[i] end
    end
    return M.message({
      kind = k,
      schema_object = {
        schema_id = s.schema_id, fields = fields,
        has_presence = s.has_presence, presence = pres,
      },
    })
  elseif k == M.MESSAGE_KIND_TYPED_VECTOR then
    return M.message({ kind = k, typed_vector = M.clone_typed_vector(msg.typed_vector) })
  elseif k == M.MESSAGE_KIND_ROW_BATCH then
    local rows = {}
    for i = 1, #msg.row_batch.rows do
      rows[i] = {}
      for j = 1, #msg.row_batch.rows[i] do
        rows[i][j] = M.clone_value(msg.row_batch.rows[i][j])
      end
    end
    return M.message({ kind = k, row_batch = { rows = rows } })
  elseif k == M.MESSAGE_KIND_COLUMN_BATCH then
    local cols = {}
    for i = 1, #msg.column_batch.columns do cols[i] = M.clone_column(msg.column_batch.columns[i]) end
    return M.message({
      kind = k,
      column_batch = { count = msg.column_batch.count, columns = cols },
    })
  elseif k == M.MESSAGE_KIND_CONTROL then
    return M.message({ kind = k, control = M.clone_control(msg.control) })
  elseif k == M.MESSAGE_KIND_EXT then
    return M.message({
      kind = k,
      ext = { ext_type = msg.ext.ext_type, payload = msg.ext.payload },
    })
  elseif k == M.MESSAGE_KIND_STATE_PATCH then
    local sp = msg.state_patch
    local ops, lits = {}, {}
    for i = 1, #sp.operations do
      local op = sp.operations[i]
      ops[i] = {
        field_id = op.field_id, opcode = op.opcode,
        value = op.value and M.clone_value(op.value) or nil,
      }
    end
    for i = 1, #sp.literals do lits[i] = M.clone_value(sp.literals[i]) end
    return M.message({
      kind = k,
      state_patch = { base_ref = sp.base_ref, operations = ops, literals = lits },
    })
  elseif k == M.MESSAGE_KIND_TEMPLATE_BATCH then
    local tb = msg.template_batch
    local mask, cols = {}, {}
    for i = 1, #tb.changed_column_mask do mask[i] = tb.changed_column_mask[i] end
    for i = 1, #tb.columns do cols[i] = M.clone_column(tb.columns[i]) end
    return M.message({
      kind = k,
      template_batch = {
        template_id = tb.template_id, count = tb.count,
        changed_column_mask = mask, columns = cols,
      },
    })
  elseif k == M.MESSAGE_KIND_CONTROL_STREAM then
    local cs = msg.control_stream
    return M.message({
      kind = k,
      control_stream = { codec = cs.codec, payload = cs.payload },
    })
  elseif k == M.MESSAGE_KIND_BASE_SNAPSHOT then
    local bs = msg.base_snapshot
    return M.message({
      kind = k,
      base_snapshot = {
        base_id = bs.base_id,
        schema_or_shape_ref = bs.schema_or_shape_ref,
        payload = M.clone_message(bs.payload),
      },
    })
  end
  return M.message({ kind = M.MESSAGE_KIND_SCALAR })
end

return M
