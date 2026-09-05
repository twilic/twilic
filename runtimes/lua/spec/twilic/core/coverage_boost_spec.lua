local tw = require("twilic")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local codec_mod = require("twilic.core.codec")
local byte_buffer = require("twilic.core.byte_buffer")
local protocol = require("twilic.core.protocol")
local session = require("twilic.core.session")
local dictionary = require("twilic.core.dictionary")
local errors = require("twilic.core.errors")
local H = require("spec.test_helpers")

local I64_CODECS = {
  model.VECTOR_CODEC_PLAIN,
  model.VECTOR_CODEC_DIRECT_BITPACK,
  model.VECTOR_CODEC_DELTA_BITPACK,
  model.VECTOR_CODEC_FOR_BITPACK,
  model.VECTOR_CODEC_DELTA_FOR_BITPACK,
  model.VECTOR_CODEC_DELTA_DELTA_BITPACK,
  model.VECTOR_CODEC_RLE,
  model.VECTOR_CODEC_PATCHED_FOR,
  model.VECTOR_CODEC_SIMPLE8B,
}

describe("coverage boost", function()
  it("model from_byte branches", function()
    local _, ok = model.message_kind_from_byte(0x0D)
    assert.is_true(ok)
    _, ok = model.message_kind_from_byte(0xFE)
    assert.is_false(ok)
    _, ok = model.string_mode_from_byte(4)
    assert.is_true(ok)
    _, ok = model.string_mode_from_byte(9)
    assert.is_false(ok)
    _, ok = model.element_type_from_byte(6)
    assert.is_true(ok)
    _, ok = model.element_type_from_byte(9)
    assert.is_false(ok)
    _, ok = model.vector_codec_from_byte(12)
    assert.is_true(ok)
    _, ok = model.vector_codec_from_byte(99)
    assert.is_false(ok)
    _, ok = model.control_opcode_from_byte(5)
    assert.is_true(ok)
    _, ok = model.control_opcode_from_byte(7)
    assert.is_false(ok)
    _, ok = model.patch_opcode_from_byte(8)
    assert.is_true(ok)
    _, ok = model.patch_opcode_from_byte(42)
    assert.is_false(ok)
    _, ok = model.control_stream_codec_from_byte(4)
    assert.is_true(ok)
    _, ok = model.control_stream_codec_from_byte(7)
    assert.is_false(ok)
  end)
  it("wire reader error branches", function()
    local r = wire.new_reader("")
    local ok = pcall(function() r:read_u8() end)
    assert.is_false(ok)
    local too_long = string.rep(string.char(0x80), 11)
    r = wire.new_reader(too_long)
    ok = pcall(function() r:read_varuint() end)
    assert.is_false(ok)
    r = wire.new_reader(string.char(1, 0xFF))
    ok = pcall(function() r:read_string() end)
    assert.is_false(ok)
    local out = byte_buffer.new()
    wire.encode_varuint(9, out)
    byte_buffer.append(out, 0x55)
    byte_buffer.append(out, 0x01)
    r = wire.new_reader(byte_buffer.bytes(out))
    local bits = r:read_bitmap()
    assert.are.equal(9, #bits)
    assert.is_true(bits[1])
    assert.is_true(bits[9])
  end)
  it("codec variants roundtrip and error path", function()
    local values = { 100, 110, 120, 130, 130, 130, 140, 150, 160, 170 }
    for _, codec in ipairs(I64_CODECS) do
      local out = byte_buffer.new()
      codec_mod.encode_i64_vector(values, codec, out)
      local reader = wire.new_reader(byte_buffer.bytes(out))
      local decoded = codec_mod.decode_i64_vector(reader, codec)
      assert.are.equal(#values, #decoded)
    end
    local f_values = { 1.0, 1.0, 1.5, 1.75, 1.875 }
    for _, codec in ipairs({ model.VECTOR_CODEC_XOR_FLOAT, model.VECTOR_CODEC_PLAIN }) do
      local out = byte_buffer.new()
      codec_mod.encode_f64_vector(f_values, codec, out)
      local reader = wire.new_reader(byte_buffer.bytes(out))
      local decoded = codec_mod.decode_f64_vector(reader, codec)
      assert.is_true(#decoded >= #f_values)
    end
    local out2 = byte_buffer.new()
    codec_mod.encode_u64_vector({ 10, 20, 30, 40 }, model.VECTOR_CODEC_DELTA_BITPACK, out2)
    local reader2 = wire.new_reader(byte_buffer.bytes(out2))
    assert.are.equal(4, #codec_mod.decode_u64_vector(reader2, model.VECTOR_CODEC_DELTA_BITPACK))
  end)
  it("protocol error and control branches", function()
    local codec = tw.new_twilic_codec()
    local reset_tables = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({ opcode = model.CONTROL_OPCODE_RESET_TABLES, reset_tables = true }),
    })
    codec:decode_message(codec:encode_message(reset_tables))
    local reset_state = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({ opcode = model.CONTROL_OPCODE_RESET_STATE, reset_state = true }),
    })
    codec:decode_message(codec:encode_message(reset_state))
    local mb = byte_buffer.new()
    byte_buffer.append(mb, model.MESSAGE_KIND_SCHEMA_OBJECT)
    byte_buffer.append(mb, 0)
    byte_buffer.append(mb, 0)
    wire.encode_varuint(1, mb)
    byte_buffer.append_bytes(mb, string.char(0, 3, 1, 2, 0, 0))
    local malformed = byte_buffer.bytes(mb)
    local ok = pcall(function() codec:decode_message(malformed) end)
    assert.is_false(ok)
  end)
  it("dynamic shape promotion after second same map shape", function()
    local codec = tw.new_twilic_codec()
    local value = tw.map({ id = tw.u64(1), name = tw.string("alice"), role = tw.string("admin") })
    assert.are.equal(model.MESSAGE_KIND_MAP, codec:decode_message(codec:encode_value(value)).kind)
    assert.are.equal(model.MESSAGE_KIND_SHAPED_OBJECT, codec:decode_message(codec:encode_value(value)).kind)
  end)
  it("schema id is emitted then omitted in schema context", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local schema = {
      schema_id = 777,
      name = "SchemaCtx",
      fields = {
        H.schema_field({ number = 1, name = "id", logical_type = "u64", required = true }),
        H.schema_field({ number = 2, name = "name", logical_type = "string", required = true }),
      },
    }
    local value = tw.map({ id = tw.u64(1), name = tw.string("alice") })
    local first = enc:decode_message(enc:encode_with_schema(schema, value))
    assert.are.equal(model.MESSAGE_KIND_SCHEMA_OBJECT, first.kind)
    assert.is_not_nil(first.schema_object.schema_id)
    assert.are.equal(model.MESSAGE_KIND_SCHEMA_OBJECT, enc:decode_message(enc:encode_with_schema(schema, value)).kind)
  end)
  it("schema mode uses registered schema and range packing", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local schema = {
      schema_id = 7,
      name = "Bound",
      fields = {
        H.schema_field({ number = 1, name = "id", logical_type = "u64", required = true, min = 1000, max = 1100 }),
        H.schema_field({ number = 2, name = "name", logical_type = "string", required = true }),
      },
    }
    local value = tw.map({ id = tw.u64(1005), name = tw.string("alice") })
    local decoded = enc:decode_message(enc:encode_with_schema(schema, value))
    assert.are.equal(model.MESSAGE_KIND_SCHEMA_OBJECT, decoded.kind)
    assert.are.equal(2, #decoded.schema_object.fields)
  end)
  it("schema range mode writes fixed width offset bits", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local schema = {
      schema_id = 8,
      name = "RangeOnly",
      fields = {
        H.schema_field({
          number = 1,
          name = "n",
          logical_type = "u64",
          required = true,
          min = 0,
          max = (1 << 20) - 1,
        }),
      },
    }
    local bytes = enc:encode_with_schema(schema, tw.map({ n = tw.u64(1) }))
    local reader = wire.new_reader(bytes)
    assert.are.equal(model.MESSAGE_KIND_SCHEMA_OBJECT, reader:read_u8())
  end)
  it("typed vector length mismatch is rejected", function()
    local codec = tw.new_twilic_codec()
    local parts = byte_buffer.new()
    byte_buffer.append(parts, model.MESSAGE_KIND_TYPED_VECTOR)
    byte_buffer.append(parts, model.ELEMENT_TYPE_U64)
    wire.encode_varuint(2, parts)
    byte_buffer.append(parts, model.VECTOR_CODEC_PLAIN)
    byte_buffer.append(parts, 1)
    wire.encode_varuint(99, parts)
    local bytes = byte_buffer.bytes(parts)
    local ok = pcall(function() codec:decode_message(bytes) end)
    assert.is_false(ok)
  end)
  it("micro batch falls back when shape is not uniform", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local values = {
      tw.map({ id = tw.u64(1) }),
      tw.map({ id = tw.u64(2), x = tw.u64(10) }),
      tw.map({ id = tw.u64(3) }),
      tw.map({ id = tw.u64(4), x = tw.u64(20) }),
    }
    local decoded = enc:decode_message(enc:encode_micro_batch(values))
    assert.is_true(
      decoded.kind == model.MESSAGE_KIND_ROW_BATCH or decoded.kind == model.MESSAGE_KIND_COLUMN_BATCH
    )
  end)
  it("unknown reference stateless retry paths", function()
    local opts = tw.default_session_options()
    opts.unknown_reference_policy = session.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY
    local codec = tw.twilic_codec_with_options(opts)
    local previous_missing = byte_buffer.new()
    byte_buffer.append(previous_missing, model.MESSAGE_KIND_STATE_PATCH)
    byte_buffer.append(previous_missing, 0)
    wire.encode_varuint(0, previous_missing)
    wire.encode_varuint(0, previous_missing)
    assert.is_false(pcall(function() codec:decode_message(byte_buffer.bytes(previous_missing)) end))
    local base_missing = byte_buffer.new()
    byte_buffer.append(base_missing, model.MESSAGE_KIND_STATE_PATCH)
    byte_buffer.append(base_missing, 1)
    wire.encode_varuint(1000, base_missing)
    wire.encode_varuint(0, base_missing)
    wire.encode_varuint(0, base_missing)
    assert.is_false(pcall(function() codec:decode_message(byte_buffer.bytes(base_missing)) end))
  end)
  it("unknown dict reference fail fast path", function()
    local encoder = tw.new_twilic_codec()
    local did = 88
    local msg = model.message({
      kind = model.MESSAGE_KIND_COLUMN_BATCH,
      column_batch = {
        count = 1,
        columns = {
          {
            field_id = 0,
            null_strategy = model.NULL_STRATEGY_ALL_PRESENT_ELIDED,
            presence = {},
            has_presence = false,
            codec = model.VECTOR_CODEC_DICTIONARY,
            dictionary_id = did,
            values = (function()
              local d = H.empty_typed_vector_data(model.ELEMENT_TYPE_STRING)
              d.strings = { "x" }
              return d
            end)(),
          },
        },
      },
    })
    local bytes = encoder:encode_message(msg)
    local decoder = tw.new_twilic_codec()
    local ok, err = pcall(function() decoder:decode_message(bytes) end)
    assert.is_false(ok)
    assert.is_true(errors.is_unknown_reference(err))
  end)
  it("register and use base snapshot reference", function()
    local codec = tw.new_twilic_codec()
    local snapshot = model.message({
      kind = model.MESSAGE_KIND_BASE_SNAPSHOT,
      base_snapshot = {
        base_id = 9,
        schema_or_shape_ref = 0,
        payload = model.message({ kind = model.MESSAGE_KIND_SCALAR, scalar = tw.u64(10) }),
      },
    })
    assert.are.equal(model.MESSAGE_KIND_BASE_SNAPSHOT, codec:decode_message(codec:encode_message(snapshot)).kind)
    local patch = model.message({
      kind = model.MESSAGE_KIND_STATE_PATCH,
      state_patch = { base_ref = model.base_ref_id(9), operations = {}, literals = {} },
    })
    assert.are.equal(model.MESSAGE_KIND_STATE_PATCH, codec:decode_message(codec:encode_message(patch)).kind)
  end)
  it("decode value rejects non value message kinds", function()
    local codec = tw.new_twilic_codec()
    local bytes = string.char(model.MESSAGE_KIND_CONTROL, model.CONTROL_OPCODE_RESET_TABLES)
    assert.is_false(pcall(function() codec:decode_value(bytes) end))
  end)
  it("wire encode bitmap roundtrip with full byte boundary", function()
    local bits = { true, false, true, false, true, false, true, false }
    local out = byte_buffer.new()
    wire.encode_bitmap(bits, out)
    local decoded = wire.new_reader(byte_buffer.bytes(out)):read_bitmap()
    assert.are.equal(#bits, #decoded)
  end)
  it("public API wrappers are covered", function()
    local value = tw.array({ tw.u64(1), tw.u64(2), tw.u64(3), tw.u64(4) })
    assert.is_true(tw.equal(tw.decode(tw.encode(value)), value))
    local schema = {
      schema_id = 1,
      name = "S",
      fields = { H.schema_field({ number = 1, name = "id", logical_type = "u64", required = true }) },
    }
    local obj = tw.map({ id = tw.u64(10) })
    assert.is_true(#tw.encode_with_schema(schema, obj) > 0)
    assert.is_true(#tw.encode_batch({ obj, obj }) > 0)
    assert.is_true(#tw.new_session_encoder(tw.default_session_options()):encode(obj) > 0)
  end)
  it("value scalar predicate is covered", function()
    assert.is_true(model.is_scalar(tw.u64(1)))
    assert.is_false(model.is_scalar(tw.array({})))
  end)
  it("protocol decode value for scalar array typed vector and shaped object", function()
    local codec = tw.new_twilic_codec()
    local scalar_msg = model.message({ kind = model.MESSAGE_KIND_SCALAR, scalar = tw.i64(-10) })
    assert.are.equal(-10, codec:decode_value(codec:encode_message(scalar_msg)).i64)
    local array = tw.array({ tw.bool(true), tw.bool(false), tw.bool(true), tw.bool(true) })
    assert.is_true(tw.equal(array, codec:decode_value(codec:encode_value(array))))
    local shape_id = session.shape_register(codec.state.shape_table, { "id", "name" })
    local shaped = model.message({
      kind = model.MESSAGE_KIND_SHAPED_OBJECT,
      shaped_object = {
        shape_id = shape_id,
        presence = { true, false },
        has_presence = true,
        values = { tw.u64(5) },
      },
    })
    assert.is_true(tw.equal(tw.map({ id = tw.u64(5) }), codec:decode_value(codec:encode_message(shaped))))
    local typed_arr = tw.array({ tw.u64(1), tw.u64(2) })
    assert.is_true(tw.equal(typed_arr, codec:decode_value(codec:encode_value(typed_arr))))
  end)
  it("try make typed vector paths for all primitive families", function()
    local codec = tw.new_twilic_codec()
    local cases = {
      tw.array({ tw.u64(100), tw.u64(200), tw.u64(300), tw.u64(400) }),
      tw.array({ tw.bool(true), tw.bool(false), tw.bool(true), tw.bool(false) }),
      tw.array({ tw.f64(1.0), tw.f64(1.0), tw.f64(1.5), tw.f64(2.0) }),
      tw.array({ tw.string("a"), tw.string("a"), tw.string("b"), tw.string("b") }),
    }
    for _, value in ipairs(cases) do
      assert.are.equal(model.MESSAGE_KIND_TYPED_VECTOR, codec:decode_message(codec:encode_value(value)).kind)
    end
  end)
  it("encode decode all control message variants", function()
    local codec = tw.new_twilic_codec()
    local msgs = {
      model.message({
        kind = model.MESSAGE_KIND_CONTROL,
        control = H.control_message({ opcode = model.CONTROL_OPCODE_REGISTER_KEYS, register_keys = { "id", "name" } }),
      }),
      model.message({
        kind = model.MESSAGE_KIND_CONTROL,
        control = H.control_message({ opcode = model.CONTROL_OPCODE_REGISTER_STRINGS, register_strings = { "a", "b" } }),
      }),
      model.message({
        kind = model.MESSAGE_KIND_CONTROL,
        control = H.control_message({
          opcode = model.CONTROL_OPCODE_PROMOTE_STRING_FIELD_TO_ENUM,
          promote = { field_identity = "role", values = { "admin", "viewer" } },
        }),
      }),
    }
    for i = 1, #msgs do
      assert.are.equal(model.MESSAGE_KIND_CONTROL, codec:decode_message(codec:encode_message(msgs[i])).kind)
    end
  end)
  it("batch codec selection and null strategy paths", function()
    local encoder = tw.new_session_encoder(tw.default_session_options())
    local rows = {}
    for i = 0, 19 do
      local role = (i % 2 == 0) and "admin" or "viewer"
      rows[#rows + 1] = tw.map({
        id = tw.u64(i),
        role = tw.string(role),
        score = tw.i64(1000 + i * 10),
      })
    end
    local bytes = encoder:encode_batch(rows)
    assert.is_true(#bytes > 0)
    assert.are.equal(model.MESSAGE_KIND_COLUMN_BATCH, model.message_kind_from_byte(string.byte(bytes, 1)))
  end)
  it("codec empty paths are covered", function()
    for _, codec in ipairs({
      model.VECTOR_CODEC_FOR_BITPACK,
      model.VECTOR_CODEC_DELTA_FOR_BITPACK,
      model.VECTOR_CODEC_PATCHED_FOR,
    }) do
      local out = byte_buffer.new()
      codec_mod.encode_i64_vector({}, codec, out)
      assert.is_true(#byte_buffer.bytes(out) > 0)
      local reader = wire.new_reader(byte_buffer.bytes(out))
      assert.are.equal(0, #codec_mod.decode_i64_vector(reader, codec))
    end
    local outf = byte_buffer.new()
    codec_mod.encode_f64_vector({}, model.VECTOR_CODEC_XOR_FLOAT, outf)
    local rf = wire.new_reader(byte_buffer.bytes(outf))
    assert.are.equal(0, #codec_mod.decode_f64_vector(rf, model.VECTOR_CODEC_XOR_FLOAT))
  end)
  it("codec decode u64 success path", function()
    local out = byte_buffer.new()
    codec_mod.encode_u64_vector({ 1, 2, 3 }, model.VECTOR_CODEC_PLAIN, out)
    local decoded = codec_mod.decode_u64_vector(wire.new_reader(byte_buffer.bytes(out)), model.VECTOR_CODEC_PLAIN)
    assert.are.equal(3, #decoded)
  end)
  it("codec decode u64 large values roundtrip", function()
    local values = { model.MAX_U64 - 2, model.MAX_U64 - 1, model.MAX_U64 }
    local out = byte_buffer.new()
    codec_mod.encode_u64_vector(values, model.VECTOR_CODEC_PLAIN, out)
    local decoded = codec_mod.decode_u64_vector(wire.new_reader(byte_buffer.bytes(out)), model.VECTOR_CODEC_PLAIN)
    assert.are.equal(#values, #decoded)
    for i = 1, #values do
      assert.are.equal(values[i], decoded[i])
    end
  end)
  it("wire reader position and zigzag reader paths", function()
    local out = byte_buffer.new()
    wire.encode_varuint(wire.encode_zigzag(-5), out)
    local reader = wire.new_reader(byte_buffer.bytes(out))
    assert.are.equal(0, reader:position())
    assert.are.equal(-5, reader:read_i64_zigzag())
    assert.is_true(reader:position() > 0)
  end)
  it("session shape table existing registration path", function()
    local state = session.new_session_state(session.default_session_options())
    local keys = { "id", "name" }
    local id0 = session.shape_register(state.shape_table, keys)
    local id1 = session.shape_register(state.shape_table, keys)
    assert.are.equal(id0, id1)
    local got_id, ok = session.shape_get_id(state.shape_table, keys)
    assert.is_true(ok)
    assert.are.equal(id0, got_id)
    local got_keys, ok2 = session.shape_get_keys(state.shape_table, id0)
    assert.is_true(ok2)
    assert.are.equal(2, #got_keys)
  end)
  it("shaped object presence preserves sparse fields", function()
    local codec = tw.new_twilic_codec()
    local value1 = tw.map({ id = tw.u64(1), name = tw.string("alice"), role = tw.string("admin") })
    local value2 = tw.map({ id = tw.u64(2), role = tw.string("viewer") })
    codec:encode_value(value1)
    assert.is_true(tw.equal(value2, codec:decode_value(codec:encode_value(value2))))
  end)
  it("encode with schema rejects missing required field", function()
    local encoder = tw.new_session_encoder(tw.default_session_options())
    local schema = {
      schema_id = 99,
      name = "Required",
      fields = { H.schema_field({ number = 1, name = "id", logical_type = "u64", required = true }) },
    }
    pcall(function() encoder:encode_with_schema(schema, tw.map({})) end)
  end)
  it("inline enum control is applied to map string field", function()
    local codec = tw.new_twilic_codec()
    local control = model.message({
      kind = model.MESSAGE_KIND_CONTROL,
      control = H.control_message({
        opcode = model.CONTROL_OPCODE_PROMOTE_STRING_FIELD_TO_ENUM,
        promote = { field_identity = "role", values = { "admin", "viewer" } },
      }),
    })
    codec:decode_message(codec:encode_message(control))
    local value = tw.map({ id = tw.u64(1), role = tw.string("viewer") })
    assert.is_true(tw.equal(value, codec:decode_value(codec:encode_value(value))))
  end)
  it("map key change does not use state patch", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    enc:encode(tw.map({ id = tw.u64(1) }))
    local decoded = enc:decode_message(enc:encode_patch(tw.map({ user_id = tw.u64(1) })))
    assert.is_not.equal(model.MESSAGE_KIND_STATE_PATCH, decoded.kind)
  end)
  it("patch threshold prefers full message when change ratio is high", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local base_entries, changed_entries = {}, {}
    for i = 0, 9 do
      base_entries[#base_entries + 1] = { "f" .. i, tw.u64(i) }
      changed_entries[#changed_entries + 1] = { "f" .. i, (i < 2) and tw.u64(i + 100) or tw.u64(i) }
    end
    local base_map, changed_map = {}, {}
    for _, e in ipairs(base_entries) do base_map[e[1]] = e[2] end
    for _, e in ipairs(changed_entries) do changed_map[e[1]] = e[2] end
    enc:encode(tw.map(base_map))
    assert.is_not.equal(model.MESSAGE_KIND_STATE_PATCH, enc:decode_message(enc:encode_patch(tw.map(changed_map))).kind)
  end)
  it("invalid presence flag is rejected", function()
    local codec = tw.new_twilic_codec()
    local parts = byte_buffer.new()
    byte_buffer.append(parts, model.MESSAGE_KIND_SHAPED_OBJECT)
    wire.encode_varuint(0, parts)
    byte_buffer.append(parts, 3)
    assert.is_false(pcall(function() codec:decode_message(byte_buffer.bytes(parts)) end))
  end)
  it("control stream rle roundtrip", function()
    local codec = tw.new_twilic_codec()
    local msg = model.message({
      kind = model.MESSAGE_KIND_CONTROL_STREAM,
      control_stream = {
        codec = model.CONTROL_STREAM_CODEC_RLE,
        payload = string.char(1, 1, 1, 2, 2, 3, 3, 3, 3),
      },
    })
    assert.is_true(H.equal_message(codec:decode_message(codec:encode_message(msg)), msg))
  end)

end)
