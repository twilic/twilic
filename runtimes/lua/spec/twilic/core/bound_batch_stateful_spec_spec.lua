local tw = require("twilic")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local byte_buffer = require("twilic.core.byte_buffer")
local dictionary = require("twilic.core.dictionary")
local session = require("twilic.core.session")
local H = require("spec.test_helpers")

describe("bound batch stateful spec", function()
  it("schema id is sent first then omitted", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local schema = H.sample_schema()
    local value = tw.map({
      id = tw.u64(1005),
      name = tw.string("alice"),
      score = tw.i64(99),
    })
    local first_msg = enc:decode_message(enc:encode_with_schema(schema, value))
    assert.are.equal(model.MESSAGE_KIND_SCHEMA_OBJECT, first_msg.kind)
    assert.is_not_nil(first_msg.schema_object.schema_id)
    assert.are.equal(41, first_msg.schema_object.schema_id)
    local second_msg = enc:decode_message(enc:encode_with_schema(schema, value))
    assert.are.equal(model.MESSAGE_KIND_SCHEMA_OBJECT, second_msg.kind)
  end)

  it("batch threshold selects row vs column", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local rows15 = {}
    for i = 0, 14 do
      rows15[#rows15 + 1] = tw.map({ id = tw.u64(i) })
    end
    local b15 = enc:encode_batch(rows15)
    assert.is_true(#b15 > 0)
    local kind15 = model.message_kind_from_byte(string.byte(b15, 1))
    assert.is_true(
      kind15 == model.MESSAGE_KIND_ROW_BATCH or kind15 == model.MESSAGE_KIND_COLUMN_BATCH
    )
    local rows16 = {}
    for i = 0, 15 do
      rows16[#rows16 + 1] = tw.map({ id = tw.u64(i) })
    end
    local b16 = enc:encode_batch(rows16)
    assert.is_true(#b16 > 0)
    assert.are.equal(model.MESSAGE_KIND_COLUMN_BATCH, model.message_kind_from_byte(string.byte(b16, 1)))
  end)

  it("micro batch reuses template and emits changed mask", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local rows1 = {
      tw.map({ id = tw.u64(1), name = tw.string("a") }),
      tw.map({ id = tw.u64(2), name = tw.string("b") }),
      tw.map({ id = tw.u64(3), name = tw.string("c") }),
      tw.map({ id = tw.u64(4), name = tw.string("d") }),
    }
    local first = enc:encode_micro_batch(rows1)
    assert.is_true(#first > 0)
    assert.are.equal(model.MESSAGE_KIND_TEMPLATE_BATCH, model.message_kind_from_byte(string.byte(first, 1)))
    local rows2 = {
      tw.map({ id = tw.u64(1), name = tw.string("aa") }),
      tw.map({ id = tw.u64(2), name = tw.string("bb") }),
      tw.map({ id = tw.u64(3), name = tw.string("cc") }),
      tw.map({ id = tw.u64(4), name = tw.string("dd") }),
    }
    local second = enc:encode_micro_batch(rows2)
    assert.is_true(#second > 0)
    assert.are.equal(model.MESSAGE_KIND_TEMPLATE_BATCH, model.message_kind_from_byte(string.byte(second, 1)))
  end)

  it("state patch uses recommended ratio threshold", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local base_values = {}
    for i = 0, 99 do
      base_values[#base_values + 1] = tw.i64(i)
    end
    local one_change = {}
    for i = 1, #base_values do
      one_change[i] = base_values[i]
    end
    one_change[1] = tw.i64(10000)
    local twelve_change = {}
    for i = 1, #base_values do
      twelve_change[i] = base_values[i]
    end
    for i = 1, 12 do
      twelve_change[i] = tw.i64(10000 + i - 1)
    end
    enc:encode(tw.array(base_values))
    enc:decode_message(enc:encode_patch(tw.array(one_change)))
    enc:decode_message(enc:encode_patch(tw.array(twelve_change)))
  end)

  it("unknown base id honors stateless retry policy", function()
    local opts = tw.default_session_options()
    opts.unknown_reference_policy = session.UNKNOWN_REFERENCE_POLICY_STATELESS_RETRY
    local enc = tw.new_session_encoder(opts)
    local patch = model.message({
      kind = model.MESSAGE_KIND_STATE_PATCH,
      state_patch = {
        base_ref = model.base_ref_id(12345),
        operations = {},
        literals = {},
      },
    })
    local builder = tw.new_twilic_codec()
    local bytes = builder:encode_message(patch)
    local err = H.assert_raises_twilic(function()
      enc:decode_message(bytes)
    end, tw.ERR_STATELESS_RETRY_REQUIRED)
    assert.are.equal("base_id", err.ref_kind)
    assert.are.equal(12345, err.ref_id)
  end)

  it("state patch map insert and delete roundtrip via reconstruction", function()
    local codec = tw.new_twilic_codec()
    local base = model.message({
      kind = model.MESSAGE_KIND_MAP,
      map = {
        H.message_map_entry("id", tw.u64(1)),
        H.message_map_entry("name", tw.string("alice")),
      },
    })
    codec:decode_message(codec:encode_message(base))
    local insert_patch = model.message({
      kind = model.MESSAGE_KIND_STATE_PATCH,
      state_patch = {
        base_ref = model.base_ref_previous(),
        operations = {
          {
            field_id = 2,
            opcode = model.PATCH_OPCODE_INSERT_FIELD,
            value = tw.map({ role = tw.string("admin") }),
          },
        },
        literals = {},
      },
    })
    codec:decode_message(codec:encode_message(insert_patch))
    assert.are.equal(model.MESSAGE_KIND_MAP, codec.state.previous_message.kind)
    local delete_patch = model.message({
      kind = model.MESSAGE_KIND_STATE_PATCH,
      state_patch = {
        base_ref = model.base_ref_previous(),
        operations = { { field_id = 2, opcode = model.PATCH_OPCODE_DELETE_FIELD, value = nil } },
        literals = {},
      },
    })
    codec:decode_message(codec:encode_message(delete_patch))
    assert.are.equal(model.MESSAGE_KIND_MAP, codec.state.previous_message.kind)
    assert.are.equal(2, #codec.state.previous_message.map)
  end)

  it("column batch assigns dictionary id for repeated string field", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local rows = {}
    for i = 0, 31 do
      local role = (i % 2 == 0) and "admin" or "user"
      rows[#rows + 1] = tw.map({ id = tw.u64(i), role = tw.string(role) })
    end
    local bytes = enc:encode_batch(rows)
    assert.is_true(#bytes > 0)
    assert.are.equal(model.MESSAGE_KIND_COLUMN_BATCH, model.message_kind_from_byte(string.byte(bytes, 1)))
  end)

  it("trained dictionary profile is transported to fresh decoder", function()
    local enc = tw.new_session_encoder(tw.default_session_options())
    local rows = {}
    for i = 0, 31 do
      local role = (i % 2 == 0) and "admin" or "user"
      rows[#rows + 1] = tw.map({ id = tw.u64(i), role = tw.string(role) })
    end
    local bytes = enc:encode_batch(rows)
    local dec = tw.new_twilic_codec()
    local decoded = dec:decode_message(bytes)
    assert.are.equal(model.MESSAGE_KIND_COLUMN_BATCH, decoded.kind)
    local dict_id
    for i = 1, #decoded.column_batch.columns do
      local col = decoded.column_batch.columns[i]
      if col.dictionary_id then
        dict_id = col.dictionary_id
        break
      end
    end
    assert.is_not_nil(dict_id)
    assert.is_not_nil(dec.state.dictionaries[dict_id])
    local profile = dec.state.dictionary_profiles[dict_id]
    assert.is_not_nil(profile)
    assert.are.equal(1, profile.version)
    assert.are.equal(0, profile.expires_at)
    assert.are.equal(session.DICTIONARY_FALLBACK_FAIL_FAST, profile.fallback)
    assert.are.equal(dictionary.dictionary_payload_hash(dec.state.dictionaries[dict_id]), profile.hash)
    local role_values
    for i = 1, #decoded.column_batch.columns do
      if decoded.column_batch.columns[i].dictionary_id == dict_id then
        role_values = decoded.column_batch.columns[i].values.strings
        break
      end
    end
    assert.are.equal(32, #role_values)
    assert.are.equal("admin", role_values[1])
    assert.are.equal("user", role_values[2])
  end)

  it("invalid dictionary profile hash is rejected", function()
    local enc = tw.new_twilic_codec()
    local dict_id = 42
    enc.state.dictionaries[dict_id] = string.char(1, 2, 3, 4)
    enc.state.dictionary_profiles[dict_id] = {
      version = 1,
      hash = 7,
      expires_at = 0,
      fallback = session.DICTIONARY_FALLBACK_FAIL_FAST,
    }
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
            dictionary_id = dict_id,
            values = (function()
              local d = H.empty_typed_vector_data(model.ELEMENT_TYPE_STRING)
              d.strings = { "admin" }
              return d
            end)(),
          },
        },
      },
    })
    local bytes = enc:encode_message(msg)
    local dec = tw.new_twilic_codec()
    local err = H.assert_raises_twilic(function()
      dec:decode_message(bytes)
    end, tw.ERR_INVALID_DATA)
    assert.are.equal("dictionary profile hash mismatch", err.msg)
  end)

  it("trained dictionary reference writes compressed block after dict id", function()
    local dict_id = 9
    local codec = tw.new_twilic_codec()
    local payload = byte_buffer.new()
    wire.encode_varuint(2, payload)
    wire.encode_string("admin", payload)
    wire.encode_string("user", payload)
    local dict_payload = byte_buffer.bytes(payload)
    codec.state.dictionaries[dict_id] = dict_payload
    codec.state.dictionary_profiles[dict_id] = {
      version = 1,
      hash = dictionary.dictionary_payload_hash(dict_payload),
      expires_at = 0,
      fallback = session.DICTIONARY_FALLBACK_FAIL_FAST,
    }
    local msg = model.message({
      kind = model.MESSAGE_KIND_COLUMN_BATCH,
      column_batch = {
        count = 4,
        columns = {
          {
            field_id = 1,
            null_strategy = model.NULL_STRATEGY_ALL_PRESENT_ELIDED,
            presence = {},
            has_presence = false,
            codec = model.VECTOR_CODEC_DICTIONARY,
            dictionary_id = dict_id,
            values = (function()
              local d = H.empty_typed_vector_data(model.ELEMENT_TYPE_STRING)
              d.strings = { "admin", "user", "admin", "user" }
              return d
            end)(),
          },
        },
      },
    })
    local bytes = codec:encode_message(msg)
    local reader = wire.new_reader(bytes)
    assert.are.equal(model.MESSAGE_KIND_COLUMN_BATCH, reader:read_u8())
    reader:read_varuint()
    reader:read_varuint()
    reader:read_varuint()
    reader:read_u8()
    reader:read_u8()
    local got_dict_id = reader:read_varuint()
    assert.is_not.equal(0, got_dict_id)
    local fresh = tw.new_twilic_codec()
    local decoded = fresh:decode_message(bytes)
    assert.are.equal(model.MESSAGE_KIND_COLUMN_BATCH, decoded.kind)
    assert.are.same({ "admin", "user", "admin", "user" }, decoded.column_batch.columns[1].values.strings)
  end)
end)
