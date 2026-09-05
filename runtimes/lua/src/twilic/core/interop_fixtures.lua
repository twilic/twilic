--- Interop test fixtures (codec/session frames).
local model = require("twilic.core.model")
local protocol = require("twilic.core.protocol")
local session = require("twilic.core.session")
local ph = require("twilic.core.protocol_helpers")

local M = {}

function M.interop_id_name_map(id, name)
  return model.map_value({
    model.entry("id", model.u64_value(id)),
    model.entry("name", model.string_value(name)),
  })
end

function M.interop_id_name_role_map(id, name, role)
  return model.map_value({
    model.entry("id", model.u64_value(id)),
    model.entry("name", model.string_value(name)),
    model.entry("role", model.string_value(role)),
  })
end

function M.interop_make_i64_array(length, start)
  local arr = {}
  for i = 1, length do arr[i] = model.i64_value(start + i - 1) end
  return arr
end

function M.interop_make_user_rows(names)
  local rows = {}
  for i = 1, #names do
    rows[i] = model.map_value({
      model.entry("id", model.u64_value(i)),
      model.entry("name", model.string_value(names[i])),
    })
  end
  return rows
end

function M.interop_bitpack_control_payload()
  local parts = {}
  for i = 0, 511 do parts[i + 1] = string.char(i % 2) end
  return table.concat(parts)
end

function M.interop_huffman_control_payload()
  return string.rep(string.char(7), 512)
end

function M.interop_fse_control_payload()
  local parts = {}
  for i = 0, 511 do parts[i + 1] = string.char(i % 4) end
  return table.concat(parts)
end

function M.reset_encode_shape_observation(codec, keys)
  protocol.reset_encode_shape_observation(codec, keys)
end

function M.emit_interop_frame(out, stream, label, bytes)
  local encoded = {}
  for i = 1, #bytes do
    encoded[i] = string.format("%02x", string.byte(bytes, i))
  end
  local frame = stream .. "|" .. label .. "|" .. table.concat(encoded) .. "\n"
  if type(out) == "table" and out.lines then
    out.lines[#out.lines + 1] = frame
  else
    io.write(frame)
  end
end

function M.emit_interop_value(out, stream, label, codec, value)
  M.emit_interop_frame(out, stream, label, codec:encode_value(value))
end

function M.emit_interop_message(out, stream, label, codec, message)
  M.emit_interop_frame(out, stream, label, codec:encode_message(message))
end

function M.emit_interop_fixtures(out)
  out = out or { lines = {} }
  local codec = protocol.new_twilic_codec()
  M.emit_interop_value(out, "codec", "scalar_string", codec, model.string_value("alpha"))
  local map_two = M.interop_id_name_map(1, "alice")
  M.emit_interop_value(out, "codec", "map_two_fields_first", codec, map_two)
  M.reset_encode_shape_observation(codec, { "id", "name" })
  M.emit_interop_value(out, "codec", "map_two_fields_second", codec, map_two)
  local map_three = M.interop_id_name_role_map(1, "alice", "admin")
  M.emit_interop_value(out, "codec", "map_three_fields_first", codec, map_three)
  M.reset_encode_shape_observation(codec, { "id", "name", "role" })
  M.emit_interop_value(out, "codec", "map_three_fields_second", codec, map_three)
  for i = 0, 7 do
    M.emit_interop_value(out, "codec", "bulk_map_" .. i, codec, M.interop_id_name_map(10 + i, "user-" .. i))
  end
  local scalar = model.i64_value(42)
  local base_snapshot = model.message({
    kind = model.MESSAGE_KIND_BASE_SNAPSHOT,
    base_snapshot = {
      base_id = 77,
      schema_or_shape_ref = 0,
      payload = model.message({ kind = model.MESSAGE_KIND_SCALAR, scalar = scalar }),
    },
  })
  M.emit_interop_message(out, "codec", "base_snapshot", codec, base_snapshot)
  local enc = protocol.new_session_encoder(session.default_session_options())
  local base_array = model.array_value(M.interop_make_i64_array(100, 0))
  M.emit_interop_frame(out, "session", "session_base_array", enc:encode(base_array))
  local one_change_arr = M.interop_make_i64_array(100, 0)
  one_change_arr[1] = model.i64_value(10000)
  M.emit_interop_frame(out, "session", "session_patch_one_change", enc:encode_patch(model.array_value(one_change_arr)))
  for step = 0, 3 do
    local iter_arr = M.interop_make_i64_array(100, 0)
    iter_arr[step + 1] = model.i64_value(20000 + step)
    M.emit_interop_frame(out, "session", "session_patch_iter_" .. step, enc:encode_patch(model.array_value(iter_arr)))
  end
  local many_arr = M.interop_make_i64_array(100, 0)
  for idx = 0, 11 do many_arr[idx + 1] = model.i64_value(10000 + idx) end
  M.emit_interop_frame(out, "session", "session_patch_many_changes", enc:encode_patch(model.array_value(many_arr)))
  M.emit_interop_frame(out, "session", "session_micro_batch_first", enc:encode_micro_batch(M.interop_make_user_rows({ "a", "b", "c", "d" })))
  M.emit_interop_frame(out, "session", "session_micro_batch_second", enc:encode_micro_batch(M.interop_make_user_rows({ "aa", "bb", "cc", "dd" })))
  if out.lines then
    return table.concat(out.lines)
  end
end

function M.interop_hex_nibble(ch)
  local b = string.byte(ch)
  if b >= 48 and b <= 57 then return b - 48 end
  if b >= 97 and b <= 102 then return b - 87 end
  if b >= 65 and b <= 70 then return b - 55 end
  error("invalid hex")
end

function M.decode_interop_hex(hex)
  if #hex % 2 ~= 0 then error("invalid hex length") end
  local out = {}
  for i = 1, #hex, 2 do
    local hi = M.interop_hex_nibble(string.sub(hex, i, i))
    local lo = M.interop_hex_nibble(string.sub(hex, i + 1, i + 1))
    out[#out + 1] = string.char((hi << 4) | lo)
  end
  return table.concat(out)
end

function M.parse_interop_frame_line(line)
  local first = string.find(line, "|", 1, true)
  if not first or first <= 1 then error("invalid frame") end
  local rest = string.sub(line, first + 1)
  local second = string.find(rest, "|", 1, true)
  if not second or second <= 1 then error("invalid frame") end
  return string.sub(line, 1, first - 1), string.sub(rest, 1, second - 1), string.sub(rest, second + 1)
end

function M.parse_interop_frames(input)
  local frames = {}
  local line_no = 0
  for raw_line in string.gmatch(input, "[^\n]+") do
    line_no = line_no + 1
    local line = raw_line:match("^%s*(.-)%s*$")
    if line ~= "" then
      local ok, stream, label, hex = pcall(function()
        local s, l, h = M.parse_interop_frame_line(line)
        return s, l, h
      end)
      if not ok then error("line " .. line_no .. ": " .. tostring(stream)) end
      local bytes = M.decode_interop_hex(hex)
      frames[#frames + 1] = { stream = stream, label = label, hex = hex, bytes = bytes }
    end
  end
  if #frames == 0 then error("no fixture frames found") end
  return frames
end

function M.interop_expect_codec_value(label)
  if label == "scalar_string" then
    return model.string_value("alpha"), true
  end
  if label:sub(1, 15) == "map_two_fields_" then
    return M.interop_id_name_map(1, "alice"), true
  end
  if label:sub(1, 17) == "map_three_fields_" then
    return M.interop_id_name_role_map(1, "alice", "admin"), true
  end
  if label:sub(1, 9) == "bulk_map_" then
    local idx = tonumber(label:sub(10))
    return M.interop_id_name_map(10 + idx, "user-" .. idx), true
  end
  return nil, false
end

function M.interop_expect_codec_value_p(label)
  local _, ok = M.interop_expect_codec_value(label)
  return ok
end

function M.interop_expect_control_stream_codec(label)
  if label == "control_stream_bitpack" then return model.CONTROL_STREAM_CODEC_BITPACK, true end
  if label == "control_stream_huffman" then return model.CONTROL_STREAM_CODEC_HUFFMAN, true end
  if label == "control_stream_fse" then return model.CONTROL_STREAM_CODEC_FSE, true end
  return nil, false
end

function M.interop_expect_control_payload(label)
  if label == "control_stream_bitpack" then return M.interop_bitpack_control_payload(), true end
  if label == "control_stream_huffman" then return M.interop_huffman_control_payload(), true end
  if label == "control_stream_fse" then return M.interop_fse_control_payload(), true end
  return nil, false
end

function M.interop_expect_control_payload_p(label)
  local _, ok = M.interop_expect_control_payload(label)
  return ok
end

function M.assert_interop_codec_decode(codec, label, frame)
  if label == "base_snapshot" then
    local msg = codec:decode_message(frame)
    if msg.kind ~= model.MESSAGE_KIND_BASE_SNAPSHOT or not msg.base_snapshot then
      error("expected base snapshot message")
    end
    if msg.base_snapshot.base_id ~= 77 then
      error("base_id mismatch")
    end
    local payload = msg.base_snapshot.payload
    if payload.kind ~= model.MESSAGE_KIND_SCALAR or payload.scalar.kind ~= model.VALUE_I64 or payload.scalar.i64 ~= 42 then
      error("base snapshot payload mismatch")
    end
    return
  end
  local _, ok = M.interop_expect_control_payload(label)
  if ok then
    local msg = codec:decode_message(frame)
    if msg.kind ~= model.MESSAGE_KIND_CONTROL_STREAM or not msg.control_stream then
      error("expected control stream message")
    end
    if #msg.control_stream.payload == 0 then error("control stream payload empty") end
    return
  end
  local expected, vok = M.interop_expect_codec_value(label)
  if not vok then error("no codec expectation for " .. label) end
  local got = codec:decode_value(frame)
  if not model.equal(got, expected) then error("decoded value mismatch for " .. label) end
end

function M.assert_interop_session_decode(codec, label, frame)
  if label == "session_base_array" then
    local got = codec:decode_value(frame)
    local want = model.array_value(M.interop_make_i64_array(100, 0))
    if not model.equal(got, want) then error("session_base_array value mismatch") end
    return
  end
  if label == "session_patch_one_change" then
    local msg = codec:decode_message(frame)
    if msg.kind == model.MESSAGE_KIND_STATE_PATCH then return end
    if msg.kind == model.MESSAGE_KIND_TYPED_VECTOR then
      local got = ph.typed_vector_to_value(msg.typed_vector)
      local want_arr = M.interop_make_i64_array(100, 0)
      want_arr[1] = model.i64_value(10000)
      if not model.equal(got, model.array_value(want_arr)) then error("typed vector mismatch") end
      return
    end
    if msg.kind == model.MESSAGE_KIND_ARRAY then
      local want_arr = M.interop_make_i64_array(100, 0)
      want_arr[1] = model.i64_value(10000)
      if not model.equal(model.array_value(msg.array), model.array_value(want_arr)) then
        error("array mismatch")
      end
      return
    end
    error("session_patch_one_change unexpected kind")
  end
  if label == "session_patch_many_changes"
      or label:sub(1, 19) == "session_patch_iter_"
      or label == "session_micro_batch_first"
      or label == "session_micro_batch_second" then
    local msg = codec:decode_message(frame)
    if label == "session_micro_batch_first" or label == "session_micro_batch_second" then
      if msg.kind ~= model.MESSAGE_KIND_TEMPLATE_BATCH or not msg.template_batch then
        error("expected template batch")
      end
      if msg.template_batch.count ~= 4 then error("expected 4 rows") end
    end
    return
  end
  error("no session expectation for " .. label)
end

function M.decode_rust_server_frames(input)
  local frames = M.parse_interop_frames(input)
  local codec_stream = protocol.new_twilic_codec()
  local session_stream = protocol.new_twilic_codec()
  local decoded = 0
  for i = 1, #frames do
    local frame = frames[i]
    if frame.stream == "codec" then
      M.assert_interop_codec_decode(codec_stream, frame.label, frame.bytes)
    elseif frame.stream == "session" then
      M.assert_interop_session_decode(session_stream, frame.label, frame.bytes)
    else
      error("unknown stream " .. tostring(frame.stream))
    end
    decoded = decoded + 1
  end
  print(string.format("Lua client decode and value checks passed for %d Rust frames", decoded))
end

function M.replay_codec_state(frames, stop_label)
  local iso = protocol.new_twilic_codec()
  for i = 1, #frames do
    local prior = frames[i]
    if prior.stream == "codec" then
      if prior.label == stop_label then break end
      local _, ok = M.interop_expect_control_payload(prior.label)
      if ok or prior.label == "base_snapshot" then
        iso:decode_message(prior.bytes)
      elseif M.interop_expect_codec_value_p(prior.label) then
        iso:decode_value(prior.bytes)
      end
    end
  end
  return iso
end

return M
