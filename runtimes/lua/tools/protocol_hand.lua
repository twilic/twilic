
function TwilicCodec.encode_message(self, message)
  local out = byte_buffer.new()
  TwilicCodec.write_message(self, message, out)
  return byte_buffer.bytes(out)
end

function TwilicCodec.decode_message(self, data)
  local reader = wire.new_reader(data)
  local msg = TwilicCodec.read_message(self, reader)
  if not reader:is_eof() then
    errors.raise(errors.invalid_data("trailing bytes in message"))
  end
  local k = msg.kind
  if k == model.MESSAGE_KIND_CONTROL then
  elseif k == model.MESSAGE_KIND_STATE_PATCH then
    local sp = msg.state_patch
    local ok, reconstructed = pcall(TwilicCodec.apply_state_patch, self, sp.base_ref, sp.operations, sp.literals)
    if not ok then
      if not errors.is_unknown_reference(reconstructed) and not errors.is_stateless_retry(reconstructed) then
        -- ignore non-reference errors on patch
      else
        errors.raise(reconstructed)
      end
    else
      self.state.previous_message = reconstructed
      self.state.previous_message_size = #data
    end
  elseif k == model.MESSAGE_KIND_TEMPLATE_BATCH then
    if not self.state.previous_message then
      self.state.previous_message = model.clone_message(msg)
      self.state.previous_message_size = #data
    end
  else
    self.state.previous_message = model.clone_message(msg)
    self.state.previous_message_size = #data
  end
  return msg
end

function TwilicCodec.encode_value(self, value)
  local msg = TwilicCodec.message_for_value(self, value)
  local out = TwilicCodec.encode_message(self, msg)
  self.state.previous_message = model.clone_message(msg)
  self.state.previous_message_size = #out
  return out
end

function TwilicCodec.decode_value(self, data)
  local msg = TwilicCodec.decode_message(self, data)
  self.state.previous_message = model.clone_message(msg)
  local k = msg.kind
  if k == model.MESSAGE_KIND_SCALAR then
    return model.clone_value(msg.scalar)
  elseif k == model.MESSAGE_KIND_ARRAY then
    return model.array_value(msg.array)
  elseif k == model.MESSAGE_KIND_MAP then
    local entries = ph.entries_to_map(msg.map, self.state)
    return model.map_value(entries)
  elseif k == model.MESSAGE_KIND_SHAPED_OBJECT then
    local so = msg.shaped_object
    local keys, ok = session.shape_get_keys(self.state.shape_table, so.shape_id)
    if not ok then errors.raise(TwilicCodec.reference_error(self, "shape_id", so.shape_id)) end
    local entries = ph.shape_values_to_map(keys, so.presence, so.has_presence, so.values)
    return model.map_value(entries)
  elseif k == model.MESSAGE_KIND_TYPED_VECTOR then
    return ph.typed_vector_to_value(msg.typed_vector)
  else
    errors.raise(errors.invalid_data("decode_value expects scalar/array/map/vector message"))
  end
end

function TwilicCodec.reference_error(self, kind, ref_id)
  if self.state.options.unknown_reference_policy == session.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY then
    return errors.stateless_retry_required(kind, ref_id)
  end
  return errors.unknown_reference(kind, ref_id)
end


function TwilicCodec.message_for_value(self, value)
  local k = value.kind
  if k == model.VALUE_ARRAY then
    local vec, ok = TwilicCodec.try_make_typed_vector(self, value.arr)
    if ok then
      return model.message({ kind = model.MESSAGE_KIND_TYPED_VECTOR, typed_vector = vec })
    end
    local arr = {}
    for i = 1, #value.arr do arr[i] = model.clone_value(value.arr[i]) end
    return model.message({ kind = model.MESSAGE_KIND_ARRAY, array = arr })
  elseif k == model.VALUE_MAP then
    local keys = {}
    for i = 1, #value.map do keys[i] = value.map[i].key end
    local sk = session.shape_key(keys)
    local had = self.state.encode_shape_observations[sk] ~= nil
    local obs = TwilicCodec.observe_encode_shape_candidate(self, keys)
    local shape_id, ok = session.shape_get_id(self.state.shape_table, keys)
    if ok and (not had or obs >= 2) then
      return TwilicCodec.shaped_message(self, shape_id, value.map)
    end
    return TwilicCodec.map_message(self, value.map)
  else
    return model.message({ kind = model.MESSAGE_KIND_SCALAR, scalar = model.clone_value(value) })
  end
end

function TwilicCodec.map_message(self, entries)
  local out = {}
  for i = 1, #entries do
    local e = entries[i]
    local key = e.key
    local ref_id, ok = session.intern_get_id(self.state.key_table, key)
    local key_ref
    if ok then
      key_ref = model.key_ref_id(ref_id)
    else
      session.intern_register(self.state.key_table, key)
      key_ref = model.key_ref_literal(key)
    end
    out[i] = { key = key_ref, value = model.clone_value(e.value) }
  end
  return model.message({ kind = model.MESSAGE_KIND_MAP, map = out })
end

function TwilicCodec.shaped_message(self, shape_id, entries)
  local keys, _ = session.shape_get_keys(self.state.shape_table, shape_id)
  local index = {}
  for i = 1, #entries do index[entries[i].key] = entries[i].value end
  local values, presence = {}, {}
  local all_present = true
  for i = 1, #keys do
    local key = keys[i]
    local v = index[key]
    if v then
      presence[i] = true
      values[#values + 1] = model.clone_value(v)
    else
      presence[i] = false
      all_present = false
    end
  end
  local so = { shape_id = shape_id, values = values, has_presence = false, presence = nil }
  if not all_present then
    so.has_presence = true
    so.presence = presence
  end
  return model.message({ kind = model.MESSAGE_KIND_SHAPED_OBJECT, shaped_object = so })
end

function TwilicCodec.try_make_typed_vector(self, values)
  if #values < 4 then return nil, false end
  local all_bool, all_i64, all_u64, all_f64, all_str = true, true, true, true, true
  for i = 1, #values do
    local vk = values[i].kind
    if vk == model.VALUE_BOOL then
      all_i64, all_u64, all_f64, all_str = false, false, false, false
    elseif vk == model.VALUE_I64 then
      all_bool, all_u64, all_f64, all_str = false, false, false, false
    elseif vk == model.VALUE_U64 then
      all_bool, all_i64, all_f64, all_str = false, false, false, false
    elseif vk == model.VALUE_F64 then
      all_bool, all_i64, all_u64, all_str = false, false, false, false
    elseif vk == model.VALUE_STRING then
      all_bool, all_i64, all_u64, all_f64 = false, false, false, false
    else
      return nil, false
    end
  end
  if all_bool then
    local bools = {}
    for i = 1, #values do bools[i] = values[i].bool end
    return {
      element_type = model.ELEMENT_TYPE_BOOL,
      codec = model.VECTOR_CODEC_DIRECT_BITPACK,
      data = ph.typed_data_bool(bools),
    }, true
  end
  if all_i64 then
    local vals = {}
    for i = 1, #values do vals[i] = values[i].i64 end
    return {
      element_type = model.ELEMENT_TYPE_I64,
      codec = ph.select_integer_codec(vals),
      data = ph.typed_data_i64(vals),
    }, true
  end
  if all_u64 then
    local vals = {}
    for i = 1, #values do vals[i] = values[i].u64 end
    return {
      element_type = model.ELEMENT_TYPE_U64,
      codec = ph.select_u64_codec(vals),
      data = ph.typed_data_u64(vals),
    }, true
  end
  if all_f64 then
    local vals = {}
    for i = 1, #values do vals[i] = values[i].f64 end
    return {
      element_type = model.ELEMENT_TYPE_F64,
      codec = ph.select_float_codec(vals),
      data = ph.typed_data_f64(vals),
    }, true
  end
  if all_str then
    local vals = {}
    for i = 1, #values do vals[i] = values[i].str end
    return {
      element_type = model.ELEMENT_TYPE_STRING,
      codec = ph.select_string_codec(vals),
      data = ph.typed_data_string(vals),
    }, true
  end
  return nil, false
end

function TwilicCodec.write_message(self, message, out)
  local k = message.kind
  if k == model.MESSAGE_KIND_SCALAR then
    byte_buffer.append(out, model.MESSAGE_KIND_SCALAR)
    TwilicCodec.write_value(self, message.scalar, out)
  elseif k == model.MESSAGE_KIND_ARRAY then
    byte_buffer.append(out, model.MESSAGE_KIND_ARRAY)
    wire.encode_varuint(#message.array, out)
    for i = 1, #message.array do TwilicCodec.write_value(self, message.array[i], out) end
  elseif k == model.MESSAGE_KIND_MAP then
    byte_buffer.append(out, model.MESSAGE_KIND_MAP)
    wire.encode_varuint(#message.map, out)
    for i = 1, #message.map do
      local e = message.map[i]
      TwilicCodec.write_key_ref(self, e.key, out)
      local field_id = ph.key_ref_field_identity(e.key, self.state)
      TwilicCodec.write_value_with_field(self, e.value, field_id, out)
    end
  elseif k == model.MESSAGE_KIND_SHAPED_OBJECT then
    byte_buffer.append(out, model.MESSAGE_KIND_SHAPED_OBJECT)
    local so = message.shaped_object
    wire.encode_varuint(so.shape_id, out)
    TwilicCodec.write_presence(self, so.presence, so.has_presence, out)
    wire.encode_varuint(#so.values, out)
    local keys, ok = session.shape_get_keys(self.state.shape_table, so.shape_id)
    if ok then
      local pres = so.presence
      if not so.has_presence then
        pres = {}
        for i = 1, #keys do pres[i] = true end
      end
      local v_idx = 1
      for i = 1, #keys do
        if i <= #pres and not pres[i] then goto continue end
        if v_idx > #so.values then break end
        TwilicCodec.write_value_with_field(self, so.values[v_idx], keys[i], out)
        v_idx = v_idx + 1
        ::continue::
      end
      while v_idx <= #so.values do
        TwilicCodec.write_value(self, so.values[v_idx], out)
        v_idx = v_idx + 1
      end
    else
      for i = 1, #so.values do TwilicCodec.write_value(self, so.values[i], out) end
    end
  elseif k == model.MESSAGE_KIND_SCHEMA_OBJECT then
    byte_buffer.append(out, model.MESSAGE_KIND_SCHEMA_OBJECT)
    local so = message.schema_object
    local schema_id = so.schema_id
    if schema_id ~= nil then
      byte_buffer.append(out, 1)
      wire.encode_varuint(schema_id, out)
    else
      byte_buffer.append(out, 0)
    end
    TwilicCodec.write_presence(self, so.presence, so.has_presence, out)
    wire.encode_varuint(#so.fields, out)
    local schema = nil
    if schema_id ~= nil then
      schema = self.state.schemas[schema_id]
    elseif self.state.last_schema_id ~= nil then
      schema = self.state.schemas[self.state.last_schema_id]
    end
    if schema ~= nil then
      byte_buffer.append(out, 1)
      TwilicCodec.write_schema_fields(self, schema, so.presence, so.has_presence, so.fields, out)
      if schema_id ~= nil then
        self.state.last_schema_id = schema_id
      end
    else
      byte_buffer.append(out, 0)
      for i = 1, #so.fields do TwilicCodec.write_value(self, so.fields[i], out) end
    end
  elseif k == model.MESSAGE_KIND_TYPED_VECTOR then
    byte_buffer.append(out, model.MESSAGE_KIND_TYPED_VECTOR)
    TwilicCodec.write_typed_vector(self, message.typed_vector, out)
  elseif k == model.MESSAGE_KIND_ROW_BATCH then
    byte_buffer.append(out, model.MESSAGE_KIND_ROW_BATCH)
    local rb = message.row_batch
    wire.encode_varuint(#rb.rows, out)
    for i = 1, #rb.rows do
      wire.encode_varuint(#rb.rows[i], out)
      for j = 1, #rb.rows[i] do TwilicCodec.write_value(self, rb.rows[i][j], out) end
    end
  elseif k == model.MESSAGE_KIND_COLUMN_BATCH then
    byte_buffer.append(out, model.MESSAGE_KIND_COLUMN_BATCH)
    wire.encode_varuint(message.column_batch.count, out)
    wire.encode_varuint(#message.column_batch.columns, out)
    for i = 1, #message.column_batch.columns do
      TwilicCodec.write_column(self, message.column_batch.columns[i], out)
    end
  elseif k == model.MESSAGE_KIND_CONTROL then
    byte_buffer.append(out, model.MESSAGE_KIND_CONTROL)
    TwilicCodec.write_control(self, message.control, out)
  elseif k == model.MESSAGE_KIND_EXT then
    byte_buffer.append(out, model.MESSAGE_KIND_EXT)
    wire.encode_varuint(message.ext.ext_type, out)
    wire.encode_bytes(message.ext.payload, out)
  elseif k == model.MESSAGE_KIND_STATE_PATCH then
    byte_buffer.append(out, model.MESSAGE_KIND_STATE_PATCH)
    local sp = message.state_patch
    TwilicCodec.write_base_ref(self, sp.base_ref, out)
    wire.encode_varuint(#sp.operations, out)
    for i = 1, #sp.operations do
      local op = sp.operations[i]
      wire.encode_varuint(op.field_id, out)
      byte_buffer.append(out, op.opcode)
      if op.value then
        byte_buffer.append(out, 1)
        TwilicCodec.write_value(self, op.value, out)
      else
        byte_buffer.append(out, 0)
      end
    end
    wire.encode_varuint(#sp.literals, out)
    for i = 1, #sp.literals do TwilicCodec.write_value(self, sp.literals[i], out) end
  elseif k == model.MESSAGE_KIND_TEMPLATE_BATCH then
    byte_buffer.append(out, model.MESSAGE_KIND_TEMPLATE_BATCH)
    local tb = message.template_batch
    wire.encode_varuint(tb.template_id, out)
    wire.encode_varuint(tb.count, out)
    wire.encode_bitmap(tb.changed_column_mask, out)
    wire.encode_varuint(#tb.columns, out)
    for i = 1, #tb.columns do TwilicCodec.write_column(self, tb.columns[i], out) end
  elseif k == model.MESSAGE_KIND_CONTROL_STREAM then
    byte_buffer.append(out, model.MESSAGE_KIND_CONTROL_STREAM)
    byte_buffer.append(out, message.control_stream.codec)
    TwilicCodec.write_control_stream_payload(self, message.control_stream.codec, message.control_stream.payload, out)
  elseif k == model.MESSAGE_KIND_BASE_SNAPSHOT then
    byte_buffer.append(out, model.MESSAGE_KIND_BASE_SNAPSHOT)
    local bs = message.base_snapshot
    wire.encode_varuint(bs.base_id, out)
    wire.encode_varuint(bs.schema_or_shape_ref, out)
    TwilicCodec.write_message(self, bs.payload, out)
    session.register_base_snapshot(self.state, bs.base_id, bs.payload)
  else
    errors.raise(errors.invalid_data("unsupported message kind"))
  end
end

function TwilicCodec.write_value(self, value, out)
  TwilicCodec.write_value_with_field(self, value, nil, out)
end

function TwilicCodec.write_value_with_field(self, value, field_identity, out)
  local k = value.kind
  if k == model.VALUE_NULL then
    byte_buffer.append(out, M.TAG_NULL)
  elseif k == model.VALUE_BOOL then
    byte_buffer.append(out, value.bool and M.TAG_BOOL_TRUE or M.TAG_BOOL_FALSE)
  elseif k == model.VALUE_I64 then
    byte_buffer.append(out, M.TAG_I64)
    ph.write_smallest_u64(wire.encode_zigzag(value.i64), out)
  elseif k == model.VALUE_U64 then
    byte_buffer.append(out, M.TAG_U64)
    ph.write_smallest_u64(value.u64, out)
  elseif k == model.VALUE_F64 then
    byte_buffer.append(out, M.TAG_F64)
    wire.append_f64_le(out, value.f64)
  elseif k == model.VALUE_STRING then
    byte_buffer.append(out, M.TAG_STRING)
    if field_identity then
      local enum_vals = self.state.field_enums[field_identity]
      if enum_vals then
        for i = 1, #enum_vals do
          if enum_vals[i] == value.str then
            byte_buffer.append(out, model.STRING_MODE_INLINE_ENUM)
            wire.encode_varuint(i - 1, out)
            return
          end
        end
      end
    end
    if value.str == "" then
      byte_buffer.append(out, model.STRING_MODE_EMPTY)
      return
    end
    local ref_id, ok = session.intern_get_id(self.state.string_table, value.str)
    if ok then
      byte_buffer.append(out, model.STRING_MODE_REF)
      wire.encode_varuint(ref_id, out)
      return
    end
    local base_id, prefix_len, prefix_ok = TwilicCodec.best_prefix_base(self, value.str)
    if prefix_ok and prefix_len >= 4 and prefix_len < #value.str then
      byte_buffer.append(out, model.STRING_MODE_PREFIX_DELTA)
      wire.encode_varuint(base_id, out)
      wire.encode_varuint(prefix_len, out)
      wire.encode_string(string.sub(value.str, prefix_len + 1), out)
      session.intern_register(self.state.string_table, value.str)
      return
    end
    byte_buffer.append(out, model.STRING_MODE_LITERAL)
    wire.encode_string(value.str, out)
    session.intern_register(self.state.string_table, value.str)
  elseif k == model.VALUE_BINARY then
    byte_buffer.append(out, M.TAG_BINARY)
    wire.encode_bytes(value.bin, out)
  elseif k == model.VALUE_ARRAY then
    byte_buffer.append(out, M.TAG_ARRAY)
    wire.encode_varuint(#value.arr, out)
    for i = 1, #value.arr do TwilicCodec.write_value(self, value.arr[i], out) end
  elseif k == model.VALUE_MAP then
    byte_buffer.append(out, M.TAG_MAP)
    wire.encode_varuint(#value.map, out)
    for i = 1, #value.map do
      TwilicCodec.write_key_ref(self, model.key_ref_literal(value.map[i].key), out)
      TwilicCodec.write_value_with_field(self, value.map[i].value, value.map[i].key, out)
    end
  end
end

function TwilicCodec.write_key_ref(self, key_ref, out)
  if key_ref.is_id then
    byte_buffer.append(out, 1)
    wire.encode_varuint(key_ref.id, out)
    return
  end
  byte_buffer.append(out, 0)
  wire.encode_string(key_ref.literal, out)
  session.intern_register(self.state.key_table, key_ref.literal)
end

function TwilicCodec.write_presence(self, presence, has_presence, out)
  if not has_presence then
    byte_buffer.append(out, 0)
    return
  end
  byte_buffer.append(out, 1)
  wire.encode_bitmap(presence, out)
end

function TwilicCodec.write_typed_vector(self, vector, out)
  byte_buffer.append(out, vector.element_type)
  wire.encode_varuint(ph.typed_vector_len(vector.data), out)
  byte_buffer.append(out, vector.codec)
  local et = vector.element_type
  local d = vector.data
  if et == model.ELEMENT_TYPE_BOOL then
    wire.encode_bitmap(d.bools, out)
  elseif et == model.ELEMENT_TYPE_I64 then
    codec_mod.encode_i64_vector(d.i64s, vector.codec, out)
  elseif et == model.ELEMENT_TYPE_U64 then
    codec_mod.encode_u64_vector(d.u64s, vector.codec, out)
  elseif et == model.ELEMENT_TYPE_F64 then
    codec_mod.encode_f64_vector(d.f64s, vector.codec, out)
  elseif et == model.ELEMENT_TYPE_STRING then
    TwilicCodec.write_string_vector(self, d.strings, vector.codec, out)
  elseif et == model.ELEMENT_TYPE_BINARY then
    wire.encode_varuint(#d.binary, out)
    for i = 1, #d.binary do wire.encode_bytes(d.binary[i], out) end
  elseif et == model.ELEMENT_TYPE_VALUE then
    wire.encode_varuint(#d.values, out)
    for i = 1, #d.values do TwilicCodec.write_value(self, d.values[i], out) end
  else
    errors.raise(errors.invalid_data("unsupported element type"))
  end
end

function TwilicCodec.write_column(self, column, out)
  wire.encode_varuint(column.field_id, out)
  byte_buffer.append(out, column.null_strategy)
  if column.null_strategy == model.NULL_STRATEGY_PRESENCE_BITMAP
      or column.null_strategy == model.NULL_STRATEGY_INVERTED_PRESENCE_BITMAP then
    if not column.has_presence or not column.presence then
      errors.raise(errors.invalid_data("missing column presence bitmap"))
    end
    wire.encode_bitmap(column.presence, out)
  end
  byte_buffer.append(out, column.codec)
  if column.dictionary_id then
    byte_buffer.append(out, 1)
    wire.encode_varuint(column.dictionary_id, out)
    local payload = self.state.dictionaries[column.dictionary_id]
    local profile = self.state.dictionary_profiles[column.dictionary_id]
    if payload and profile then
      byte_buffer.append(out, 1)
      wire.encode_varuint(profile.version, out)
      wire.encode_varuint(profile.hash, out)
      wire.encode_varuint(profile.expires_at, out)
      byte_buffer.append(out, profile.fallback)
      wire.encode_bytes(payload, out)
    else
      byte_buffer.append(out, 0)
    end
  else
    byte_buffer.append(out, 0)
  end
  byte_buffer.append(out, 0)
  local tv = {
    element_type = column.values.kind,
    codec = column.codec,
    data = model.clone_typed_vector_data(column.values),
  }
  TwilicCodec.write_typed_vector(self, tv, out)
end

function TwilicCodec.write_control(self, control, out)
  byte_buffer.append(out, control.opcode)
  if control.opcode == model.CONTROL_OPCODE_REGISTER_KEYS then
    wire.encode_varuint(#control.register_keys, out)
    for i = 1, #control.register_keys do
      wire.encode_string(control.register_keys[i], out)
      session.intern_register(self.state.key_table, control.register_keys[i])
    end
  elseif control.opcode == model.CONTROL_OPCODE_RESET_TABLES then
    session.reset_tables(self.state)
  elseif control.opcode == model.CONTROL_OPCODE_RESET_STATE then
    session.reset_state(self.state)
  end
end

function TwilicCodec.write_base_ref(self, base_ref, out)
  if base_ref.previous then
    byte_buffer.append(out, 0)
    return
  end
  byte_buffer.append(out, 1)
  wire.encode_varuint(base_ref.base_id, out)
end

function TwilicCodec.write_control_stream_payload(self, codec_id, payload, out)
  local encoded = payload
  if codec_id == model.CONTROL_STREAM_CODEC_RLE then
    encoded = ph.rle_encode_bytes(payload) or payload
  elseif codec_id == model.CONTROL_STREAM_CODEC_BITPACK then
    encoded = ph.control_bitpack_encode_bytes(payload)
  elseif codec_id == model.CONTROL_STREAM_CODEC_HUFFMAN then
    encoded = ph.control_huffman_encode_bytes(payload)
  elseif codec_id == model.CONTROL_STREAM_CODEC_FSE then
    encoded = ph.control_fse_encode_bytes(payload)
  end
  wire.encode_bytes(encoded, out)
end

function TwilicCodec.best_prefix_base(self, value)
  local best_id, best_len = 0, 0
  for sid = 1, #self.state.string_table.by_id do
    local candidate = self.state.string_table.by_id[sid]
    if candidate then
      local n = ph.common_prefix_len(value, candidate)
      if n > best_len then
        best_len = n
        best_id = sid - 1
      end
    end
  end
  if best_len == 0 then return 0, 0, false end
  return best_id, best_len, true
end

function TwilicCodec.write_string_vector(self, values, codec_id, out)
  if codec_id == model.VECTOR_CODEC_DICTIONARY then
    local dct, uniq, refs = {}, {}, {}
    for i = 1, #values do
      local v = values[i]
      local rid = dct[v]
      if rid then
        refs[i] = rid
      else
        rid = #uniq
        dct[v] = rid
        uniq[#uniq + 1] = v
        refs[i] = rid
      end
    end
    wire.encode_varuint(#uniq, out)
    for i = 1, #uniq do wire.encode_string(uniq[i], out) end
    codec_mod.encode_u64_vector(refs, model.VECTOR_CODEC_DIRECT_BITPACK, out)
  elseif codec_id == model.VECTOR_CODEC_STRING_REF then
    wire.encode_varuint(#values, out)
    for i = 1, #values do
      local sid, ok = session.intern_get_id(self.state.string_table, values[i])
      if not ok then sid = session.intern_register(self.state.string_table, values[i]) end
      wire.encode_varuint(sid, out)
    end
  elseif codec_id == model.VECTOR_CODEC_PREFIX_DELTA then
    wire.encode_varuint(#values, out)
    local prev = ""
    for i = 1, #values do
      local v = values[i]
      local prefix = ph.common_prefix_len(prev, v)
      wire.encode_varuint(prefix, out)
      wire.encode_string(string.sub(v, prefix + 1), out)
      prev = v
    end
  else
    wire.encode_varuint(#values, out)
    for i = 1, #values do wire.encode_string(values[i], out) end
  end
end

function TwilicCodec.observe_encode_shape_candidate(self, keys)
  local sk = session.shape_key(keys)
  self.state.encode_shape_observations[sk] = (self.state.encode_shape_observations[sk] or 0) + 1
  local count = self.state.encode_shape_observations[sk]
  if ph.should_register_shape(keys, count) then
    session.shape_register(self.state.shape_table, keys)
  end
  return count
end

function TwilicCodec.observe_decode_shape_candidate(self, keys)
  local _, ok = session.shape_get_id(self.state.shape_table, keys)
  if ok then return end
  local observed = session.shape_observe(self.state.shape_table, keys)
  if ph.should_register_shape(keys, observed) then
    session.shape_register(self.state.shape_table, keys)
  end
end

function TwilicCodec.write_schema_fields(self, schema, presence, has_presence, fields, out)
  local indices = ph.schema_present_field_indices(schema, presence, has_presence)
  for j = 1, #indices do
    local i = indices[j]
    local li = i + 1
    if li > #fields then
      errors.raise(errors.invalid_data("schema fields length mismatch"))
    end
    TwilicCodec.write_schema_field_value(self, schema.fields[li], fields[li], out)
  end
end

function TwilicCodec.read_schema_fields(self, schema, presence, has_presence, n, reader)
  local indices = ph.schema_present_field_indices(schema, presence, has_presence)
  if #indices ~= n then
    errors.raise(errors.invalid_data("schema fields length"))
  end
  local out = {}
  for j = 1, #indices do
    local i = indices[j]
    out[i + 1] = TwilicCodec.read_schema_field_value(self, schema.fields[i + 1], reader)
  end
  return out
end

function TwilicCodec.write_schema_field_value(self, field, value, out)
  local lt = ph.normalized_logical_type(field.logical_type)
  if lt == "bool" and value.kind ~= model.VALUE_BOOL then
    errors.raise(errors.invalid_data("schema bool field type mismatch"))
  end
  if (lt == "i64" or lt == "int64" or lt == "int") and value.kind ~= model.VALUE_I64 then
    errors.raise(errors.invalid_data("schema i64 field type mismatch"))
  end
  if (lt == "u64" or lt == "uint64" or lt == "uint") and value.kind ~= model.VALUE_U64 then
    errors.raise(errors.invalid_data("schema u64 field type mismatch"))
  end
  if (lt == "f64" or lt == "float64" or lt == "float") and value.kind ~= model.VALUE_F64 then
    errors.raise(errors.invalid_data("schema f64 field type mismatch"))
  end
  if lt == "string" then
    if value.kind ~= model.VALUE_STRING then
      errors.raise(errors.invalid_data("schema string field type mismatch"))
    end
    TwilicCodec.write_value_with_field(self, value, field.name, out)
    return
  end
  TwilicCodec.write_value(self, value, out)
end

function TwilicCodec.read_schema_field_value(self, field, reader)
  if ph.normalized_logical_type(field.logical_type) == "string" then
    return TwilicCodec.read_value_with_field(self, reader, field.name)
  end
  return TwilicCodec.read_value(self, reader)
end

function TwilicCodec.read_presence(self, reader)
  local flag = reader:read_u8()
  if flag == 0 then return {}, false end
  if flag ~= 1 then errors.raise(errors.invalid_data("presence flag")) end
  return reader:read_bitmap(), true
end

function TwilicCodec.read_base_ref(self, reader)
  local mode = reader:read_u8()
  if mode == 0 then return model.base_ref_previous() end
  if mode == 1 then return model.base_ref_id(reader:read_varuint()) end
  errors.raise(errors.invalid_data("base ref"))
end

function TwilicCodec.read_control_stream_payload(self, codec_id, reader)
  local encoded = reader:read_bytes()
  if codec_id == model.CONTROL_STREAM_CODEC_PLAIN then return encoded end
  if codec_id == model.CONTROL_STREAM_CODEC_RLE then return ph.rle_decode_bytes(encoded) end
  if codec_id == model.CONTROL_STREAM_CODEC_BITPACK then return ph.control_bitpack_decode_bytes(encoded) end
  if codec_id == model.CONTROL_STREAM_CODEC_HUFFMAN then return ph.control_huffman_decode_bytes(encoded) end
  if codec_id == model.CONTROL_STREAM_CODEC_FSE then return ph.control_fse_decode_bytes(encoded) end
  errors.raise(errors.invalid_data("control stream codec"))
end

function TwilicCodec.read_column(self, reader)
  local field_id = reader:read_varuint()
  local null_byte = reader:read_u8()
  local null_strategy, nok = model.null_strategy_from_byte(null_byte)
  if not nok then errors.raise(errors.invalid_data("null strategy")) end
  local presence, has_presence = {}, false
  if null_strategy == model.NULL_STRATEGY_PRESENCE_BITMAP
      or null_strategy == model.NULL_STRATEGY_INVERTED_PRESENCE_BITMAP then
    presence = reader:read_bitmap()
    has_presence = true
  end
  local codec_byte = reader:read_u8()
  local codec_id, cok = model.vector_codec_from_byte(codec_byte)
  if not cok then errors.raise(errors.invalid_data("column codec")) end
  local has_dict = reader:read_u8()
  local dictionary_id = nil
  if has_dict == 1 then
    local dict_id = reader:read_varuint()
    local has_profile = reader:read_u8()
    if has_profile == 0 then
      if not self.state.dictionaries[dict_id] then
        errors.raise(TwilicCodec.reference_error(self, "dict_id", dict_id))
      end
    elseif has_profile == 1 then
      local version = reader:read_varuint()
      local hash_val = reader:read_varuint()
      local expires_at = reader:read_varuint()
      local fallback_byte = reader:read_u8()
      local fallback, fok = session.dictionary_fallback_from_byte(fallback_byte)
      if not fok then errors.raise(errors.invalid_data("dictionary fallback")) end
      local payload = reader:read_bytes()
      if dictionary.dictionary_payload_hash(payload) ~= hash_val then
        errors.raise(errors.invalid_data("dictionary profile hash mismatch"))
      end
      self.state.dictionaries[dict_id] = payload
      self.state.dictionary_profiles[dict_id] = {
        version = version,
        hash = hash_val,
        expires_at = expires_at,
        fallback = fallback,
      }
    else
      errors.raise(errors.invalid_data("dictionary profile flag"))
    end
    dictionary_id = dict_id
  elseif has_dict ~= 0 then
    errors.raise(errors.invalid_data("dictionary flag"))
  end
  local payload_mode = reader:read_u8()
  local values
  if payload_mode == 0 then
    local tv = TwilicCodec.read_typed_vector(self, reader, nil, codec_id)
    values = tv.data
  elseif payload_mode == 1 then
    if not dictionary_id then
      errors.raise(errors.invalid_data("trained dictionary block requires dict_id"))
    end
    if codec_id ~= model.VECTOR_CODEC_DICTIONARY and codec_id ~= model.VECTOR_CODEC_STRING_REF then
      errors.raise(errors.invalid_data("trained dictionary block requires string dictionary codec"))
    end
    local dictionary_payload = self.state.dictionaries[dictionary_id]
    if not dictionary_payload then
      errors.raise(TwilicCodec.reference_error(self, "dict_id", dictionary_id))
    end
    local dict = dictionary.decode_trained_dictionary_payload(dictionary_payload)
    local block = reader:read_bytes()
    local strings = dictionary.decode_trained_dictionary_block(block, dict)
    values = model.typed_vector_data(model.ELEMENT_TYPE_STRING)
    values.strings = strings
  else
    errors.raise(errors.invalid_data("column payload mode"))
  end
  return {
    field_id = field_id,
    null_strategy = null_strategy,
    presence = presence,
    has_presence = has_presence,
    codec = codec_id,
    dictionary_id = dictionary_id,
    values = values,
  }
end

function TwilicCodec.read_control(self, reader)
  local op_byte = reader:read_u8()
  local opcode, ok = model.control_opcode_from_byte(op_byte)
  if not ok then errors.raise(errors.invalid_data("control opcode")) end
  local msg = { opcode = opcode }
  if opcode == model.CONTROL_OPCODE_REGISTER_KEYS then
    local n = reader:read_varuint()
    msg.register_keys = {}
    for i = 1, n do
      local s = reader:read_string()
      msg.register_keys[i] = s
      session.intern_register(self.state.key_table, s)
    end
  elseif opcode == model.CONTROL_OPCODE_REGISTER_SHAPE then
    local shape_id = reader:read_varuint()
    local n = reader:read_varuint()
    local keys, key_names = {}, {}
    for i = 1, n do
      local k = TwilicCodec.read_key_ref(self, reader)
      keys[i] = k
      key_names[i] = k.literal
    end
    session.shape_register_with_id(self.state.shape_table, shape_id, key_names)
    msg.register_shape = { shape_id = shape_id, keys = keys }
  elseif opcode == model.CONTROL_OPCODE_REGISTER_STRINGS then
    local n = reader:read_varuint()
    msg.register_strings = {}
    for i = 1, n do
      local s = reader:read_string()
      msg.register_strings[i] = s
      session.intern_register(self.state.string_table, s)
    end
  elseif opcode == model.CONTROL_OPCODE_PROMOTE_STRING_FIELD_TO_ENUM then
    local field_identity = reader:read_string()
    local n = reader:read_varuint()
    local values = {}
    for i = 1, n do values[i] = reader:read_string() end
    self.state.field_enums[field_identity] = values
    msg.promote_string_field_to_enum = { field_identity = field_identity, values = values }
  elseif opcode == model.CONTROL_OPCODE_RESET_TABLES then
    msg.reset_tables = true
    session.reset_tables(self.state)
  elseif opcode == model.CONTROL_OPCODE_RESET_STATE then
    msg.reset_state = true
    session.reset_state(self.state)
  end
  return msg
end

function TwilicCodec.read_message(self, reader)
  local kind_byte = reader:read_u8()
  local kind, ok = model.message_kind_from_byte(kind_byte)
  if not ok then errors.raise(errors.invalid_kind(kind_byte)) end
  if kind == model.MESSAGE_KIND_SCALAR then
    return model.message({ kind = kind, scalar = TwilicCodec.read_value(self, reader) })
  elseif kind == model.MESSAGE_KIND_ARRAY then
    local n = reader:read_varuint()
    local values = {}
    for i = 1, n do values[i] = TwilicCodec.read_value(self, reader) end
    return model.message({ kind = kind, array = values })
  elseif kind == model.MESSAGE_KIND_MAP then
    local n = reader:read_varuint()
    local entries = {}
    for i = 1, n do
      local key_ref = TwilicCodec.read_key_ref(self, reader)
      local field_identity = ph.key_ref_field_identity(key_ref, self.state)
      local v = TwilicCodec.read_value_with_field(self, reader, field_identity)
      entries[i] = { key = key_ref, value = v }
    end
    local keys = {}
    for i = 1, #entries do keys[i] = ph.key_ref_string(entries[i].key, self.state) end
    TwilicCodec.observe_decode_shape_candidate(self, keys)
    return model.message({ kind = kind, map = entries })
  elseif kind == model.MESSAGE_KIND_SHAPED_OBJECT then
    local shape_id = reader:read_varuint()
    local presence, has_presence = TwilicCodec.read_presence(self, reader)
    local n = reader:read_varuint()
    local values = {}
    local keys, sk_ok = session.shape_get_keys(self.state.shape_table, shape_id)
    if sk_ok then
      local pres = presence
      if not has_presence then
        pres = {}
        for i = 1, #keys do pres[i] = true end
      end
      local read_count = 0
      for i = 1, #keys do
        if i <= #pres and not pres[i] then goto skip_key end
        if read_count >= n then break end
        values[#values + 1] = TwilicCodec.read_value_with_field(self, reader, keys[i])
        read_count = read_count + 1
        ::skip_key::
      end
      while read_count < n do
        values[#values + 1] = TwilicCodec.read_value(self, reader)
        read_count = read_count + 1
      end
    else
      for _ = 1, n do values[#values + 1] = TwilicCodec.read_value(self, reader) end
    end
    return model.message({
      kind = kind,
      shaped_object = {
        shape_id = shape_id,
        presence = presence,
        has_presence = has_presence,
        values = values,
      },
    })
  elseif kind == model.MESSAGE_KIND_SCHEMA_OBJECT then
    local has_schema = reader:read_u8()
    local schema_id = nil
    if has_schema == 1 then schema_id = reader:read_varuint() end
    local presence, has_presence = TwilicCodec.read_presence(self, reader)
    local n = reader:read_varuint()
    local mode = reader:read_u8()
    local fields = {}
    if mode == 1 then
      local effective_id = schema_id
      if effective_id == nil then
        effective_id = self.state.last_schema_id
      end
      if effective_id == nil then
        errors.raise(errors.invalid_data("schema object requires schema id in context"))
      end
      local schema = self.state.schemas[effective_id]
      if not schema then
        errors.raise(TwilicCodec.reference_error(self, "schema_id", effective_id))
      end
      fields = TwilicCodec.read_schema_fields(self, schema, presence, has_presence, n, reader)
      self.state.last_schema_id = effective_id
    else
      for i = 1, n do fields[i] = TwilicCodec.read_value(self, reader) end
      if schema_id ~= nil then self.state.last_schema_id = schema_id end
    end
    return model.message({
      kind = kind,
      schema_object = {
        schema_id = schema_id,
        presence = presence,
        has_presence = has_presence,
        fields = fields,
      },
    })
  elseif kind == model.MESSAGE_KIND_TYPED_VECTOR then
    return model.message({ kind = kind, typed_vector = TwilicCodec.read_typed_vector(self, reader, nil, nil) })
  elseif kind == model.MESSAGE_KIND_ROW_BATCH then
    local row_count = reader:read_varuint()
    local rows = {}
    for _ = 1, row_count do
      local field_count = reader:read_varuint()
      local row = {}
      for i = 1, field_count do row[i] = TwilicCodec.read_value(self, reader) end
      rows[#rows + 1] = row
    end
    return model.message({ kind = kind, row_batch = { rows = rows } })
  elseif kind == model.MESSAGE_KIND_COLUMN_BATCH then
    local count = reader:read_varuint()
    local col_count = reader:read_varuint()
    local cols = {}
    for i = 1, col_count do cols[i] = TwilicCodec.read_column(self, reader) end
    return model.message({ kind = kind, column_batch = { count = count, columns = cols } })
  elseif kind == model.MESSAGE_KIND_CONTROL then
    return model.message({ kind = kind, control = TwilicCodec.read_control(self, reader) })
  elseif kind == model.MESSAGE_KIND_EXT then
    local ext_type = reader:read_varuint()
    local payload = reader:read_bytes()
    return model.message({ kind = kind, ext = { ext_type = ext_type, payload = payload } })
  elseif kind == model.MESSAGE_KIND_STATE_PATCH then
    local base_ref = TwilicCodec.read_base_ref(self, reader)
    local op_n = reader:read_varuint()
    local ops = {}
    for i = 1, op_n do
      local field_id = reader:read_varuint()
      local op_byte = reader:read_u8()
      local opcode, pok = model.patch_opcode_from_byte(op_byte)
      if not pok then errors.raise(errors.invalid_data("patch opcode")) end
      local has_value = reader:read_u8()
      local value = nil
      if has_value == 1 then value = TwilicCodec.read_value(self, reader) end
      ops[i] = { field_id = field_id, opcode = opcode, value = value }
    end
    local lit_n = reader:read_varuint()
    local lits = {}
    for i = 1, lit_n do lits[i] = TwilicCodec.read_value(self, reader) end
    return model.message({
      kind = kind,
      state_patch = { base_ref = base_ref, operations = ops, literals = lits },
    })
  elseif kind == model.MESSAGE_KIND_TEMPLATE_BATCH then
    local template_id = reader:read_varuint()
    local count = reader:read_varuint()
    local mask = reader:read_bitmap()
    local col_n = reader:read_varuint()
    local changed_cols = {}
    for i = 1, col_n do changed_cols[i] = TwilicCodec.read_column(self, reader) end
    local full_cols = changed_cols
    local prev = self.state.template_columns[template_id]
    if prev then
      full_cols = ph.merge_template_columns(prev, mask, changed_cols)
    else
      for i = 1, #mask do
        if not mask[i] then
          errors.raise(TwilicCodec.reference_error(self, "template_id", template_id))
        end
      end
    end
    self.state.template_columns[template_id] = full_cols
    self.state.templates[template_id] = ph.template_descriptor_from_columns(template_id, full_cols)
    if count >= 16 then
      self.state.previous_message = model.message({
        kind = model.MESSAGE_KIND_COLUMN_BATCH,
        column_batch = { count = count, columns = full_cols },
      })
    end
    return model.message({
      kind = kind,
      template_batch = {
        template_id = template_id,
        count = count,
        changed_column_mask = mask,
        columns = changed_cols,
      },
    })
  elseif kind == model.MESSAGE_KIND_CONTROL_STREAM then
    local codec_byte = reader:read_u8()
    local cs_codec, cok = model.control_stream_codec_from_byte(codec_byte)
    if not cok then errors.raise(errors.invalid_data("control stream codec")) end
    local payload = TwilicCodec.read_control_stream_payload(self, cs_codec, reader)
    return model.message({ kind = kind, control_stream = { codec = cs_codec, payload = payload } })
  elseif kind == model.MESSAGE_KIND_BASE_SNAPSHOT then
    local base_id = reader:read_varuint()
    local ref = reader:read_varuint()
    local payload = TwilicCodec.read_message(self, reader)
    session.register_base_snapshot(self.state, base_id, payload)
    return model.message({
      kind = kind,
      base_snapshot = { base_id = base_id, schema_or_shape_ref = ref, payload = payload },
    })
  else
    errors.raise(errors.invalid_data("unsupported message kind"))
  end
end

function TwilicCodec.read_value(self, reader)
  return TwilicCodec.read_value_with_field(self, reader, nil)
end

function TwilicCodec.read_value_with_field(self, reader, field_identity)
  local tag = reader:read_u8()
  if tag == M.TAG_NULL then return model.null_value() end
  if tag == M.TAG_BOOL_FALSE then return model.bool_value(false) end
  if tag == M.TAG_BOOL_TRUE then return model.bool_value(true) end
  if tag == M.TAG_I64 then
    return model.i64_value(wire.decode_zigzag(ph.read_smallest_u64(reader)))
  end
  if tag == M.TAG_U64 then return model.u64_value(ph.read_smallest_u64(reader)) end
  if tag == M.TAG_F64 then return model.f64_value(wire.read_f64_le(reader)) end
  if tag == M.TAG_STRING then
    local mode_byte = reader:read_u8()
    local mode, mok = model.string_mode_from_byte(mode_byte)
    if not mok then errors.raise(errors.invalid_data("string mode")) end
    if mode == model.STRING_MODE_EMPTY then return model.string_value("") end
    if mode == model.STRING_MODE_LITERAL then
      local s = reader:read_string()
      session.intern_register(self.state.string_table, s)
      return model.string_value(s)
    end
    if mode == model.STRING_MODE_REF then
      local ref_id = reader:read_varuint()
      local s, ok = session.intern_get_value(self.state.string_table, ref_id)
      if not ok then errors.raise(TwilicCodec.reference_error(self, "string_id", ref_id)) end
      return model.string_value(s)
    end
    if mode == model.STRING_MODE_PREFIX_DELTA then
      local base_id = reader:read_varuint()
      local prefix_len = reader:read_varuint()
      local suffix = reader:read_string()
      local base, ok = session.intern_get_value(self.state.string_table, base_id)
      if not ok then errors.raise(TwilicCodec.reference_error(self, "string_id", base_id)) end
      if prefix_len > #base then errors.raise(errors.invalid_data("prefix delta length")) end
      local s = string.sub(base, 1, prefix_len) .. suffix
      session.intern_register(self.state.string_table, s)
      return model.string_value(s)
    end
    if mode == model.STRING_MODE_INLINE_ENUM then
      if not field_identity then errors.raise(errors.invalid_data("inline enum missing field identity")) end
      local enum_vals = self.state.field_enums[field_identity]
      if not enum_vals then errors.raise(errors.invalid_data("inline enum unknown field")) end
      local code = reader:read_varuint()
      if code >= #enum_vals then errors.raise(errors.invalid_data("inline enum code")) end
      return model.string_value(enum_vals[code + 1])
    end
  end
  if tag == M.TAG_BINARY then return model.binary_value(reader:read_bytes()) end
  if tag == M.TAG_ARRAY then
    local n = reader:read_varuint()
    local items = {}
    for i = 1, n do items[i] = TwilicCodec.read_value(self, reader) end
    return model.array_value(items)
  end
  if tag == M.TAG_MAP then
    local n = reader:read_varuint()
    local entries = {}
    for i = 1, n do
      local key_ref = TwilicCodec.read_key_ref(self, reader)
      local v = TwilicCodec.read_value_with_field(self, reader, key_ref.literal)
      entries[i] = model.entry(key_ref.literal, v)
    end
    return model.map_value(entries)
  end
  errors.raise(errors.invalid_tag(tag))
end

function TwilicCodec.read_key_ref(self, reader)
  local mode = reader:read_u8()
  if mode == 1 then
    local ref_id = reader:read_varuint()
    local key, ok = session.intern_get_value(self.state.key_table, ref_id)
    if not ok then errors.raise(TwilicCodec.reference_error(self, "key_id", ref_id)) end
    return model.key_ref_literal(key)
  end
  if mode ~= 0 then errors.raise(errors.invalid_data("key ref mode")) end
  local s = reader:read_string()
  session.intern_register(self.state.key_table, s)
  return model.key_ref_literal(s)
end

function TwilicCodec.read_typed_vector(self, reader, forced_element, expected_codec)
  local elem_type
  if forced_element == nil then
    local elem_byte = reader:read_u8()
    local et, ok = model.element_type_from_byte(elem_byte)
    if not ok then errors.raise(errors.invalid_data("vector element type")) end
    elem_type = et
  else
    elem_type = forced_element
  end
  local expected_len = reader:read_varuint()
  local codec_byte = reader:read_u8()
  local codec_id, ok = model.vector_codec_from_byte(codec_byte)
  if not ok then errors.raise(errors.invalid_data("vector codec")) end
  if expected_codec and codec_id ~= expected_codec then
    errors.raise(errors.invalid_data("column codec mismatch"))
  end
  local data = model.typed_vector_data(elem_type)
  if elem_type == model.ELEMENT_TYPE_BOOL then
    data.bools = reader:read_bitmap()
  elseif elem_type == model.ELEMENT_TYPE_I64 then
    data.i64s = codec_mod.decode_i64_vector(reader, codec_id)
  elseif elem_type == model.ELEMENT_TYPE_U64 then
    data.u64s = codec_mod.decode_u64_vector(reader, codec_id)
  elseif elem_type == model.ELEMENT_TYPE_F64 then
    data.f64s = codec_mod.decode_f64_vector(reader, codec_id)
  elseif elem_type == model.ELEMENT_TYPE_STRING then
    data.strings = TwilicCodec.read_string_vector(self, reader, codec_id)
  end
  if ph.typed_vector_len(data) ~= expected_len then
    errors.raise(errors.invalid_data("typed vector length mismatch"))
  end
  return { element_type = elem_type, codec = codec_id, data = data }
end

function TwilicCodec.read_string_vector(self, reader, codec_id)
  if codec_id == model.VECTOR_CODEC_DICTIONARY then
    local dict_n = reader:read_varuint()
    local dct = {}
    for i = 1, dict_n do dct[i] = reader:read_string() end
    local refs = codec_mod.decode_u64_vector(reader, model.VECTOR_CODEC_DIRECT_BITPACK)
    local out = {}
    for i = 1, #refs do
      if refs[i] >= dict_n then errors.raise(errors.invalid_data("dictionary reference")) end
      out[i] = dct[refs[i] + 1]
    end
    return out
  elseif codec_id == model.VECTOR_CODEC_STRING_REF then
    local n = reader:read_varuint()
    local out = {}
    for i = 1, n do
      local sid = reader:read_varuint()
      local s, ok = session.intern_get_value(self.state.string_table, sid)
      if not ok then errors.raise(TwilicCodec.reference_error(self, "string_id", sid)) end
      out[i] = s
    end
    return out
  elseif codec_id == model.VECTOR_CODEC_PREFIX_DELTA then
    local n = reader:read_varuint()
    local out = {}
    local prev = ""
    for i = 1, n do
      local prefix = reader:read_varuint()
      local suffix = reader:read_string()
      if prefix > #prev then errors.raise(errors.invalid_data("prefix delta in string vector")) end
      out[i] = string.sub(prev, 1, prefix) .. suffix
      prev = out[i]
    end
    return out
  else
    local n = reader:read_varuint()
    local out = {}
    for i = 1, n do out[i] = reader:read_string() end
    return out
  end
end

function TwilicCodec.apply_state_patch(self, base_ref, operations, literals)
  local base
  if base_ref.previous then
    if not self.state.previous_message then
      errors.raise(TwilicCodec.reference_error(self, "previous", 0))
    end
    base = model.clone_message(self.state.previous_message)
  else
    local snap, ok = session.get_base_snapshot(self.state, base_ref.base_id)
    if not ok then errors.raise(TwilicCodec.reference_error(self, "base_id", base_ref.base_id)) end
    base = snap
  end
  local fields = ph.message_fields(base)
  for i = 1, #operations do
    local op = operations[i]
    local idx = op.field_id + 1
    if op.opcode == model.PATCH_OPCODE_KEEP then
    elseif op.opcode == model.PATCH_OPCODE_REPLACE_SCALAR or op.opcode == model.PATCH_OPCODE_INSERT_FIELD then
      if not op.value then errors.raise(errors.invalid_data("patch operation missing value")) end
      if idx <= #fields then
        fields[idx] = model.clone_value(op.value)
      elseif idx == #fields + 1 then
        fields[#fields + 1] = model.clone_value(op.value)
      else
        errors.raise(errors.invalid_data("patch field index out of range"))
      end
    elseif op.opcode == model.PATCH_OPCODE_DELETE_FIELD then
      if idx < 1 or idx > #fields then errors.raise(errors.invalid_data("delete field index out of range")) end
      table.remove(fields, idx)
    end
  end
  return ph.rebuild_message_like(base, fields)
end
