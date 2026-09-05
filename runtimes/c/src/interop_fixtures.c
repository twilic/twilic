#include "twilic/interop_fixtures.h"

#include <cctype>
#include <memory>
#include <sstream>
#include <stdexcept>

#include "twilic/session.h"

namespace twilic {

namespace {

std::string encode_hex(const std::vector<uint8_t>& bytes) {
  static const char* hex = "0123456789abcdef";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (const auto b : bytes) {
    out.push_back(hex[b >> 4]);
    out.push_back(hex[b & 0x0f]);
  }
  return out;
}

void emit_frame(std::string& out, const std::string& stream, const std::string& label,
                const std::vector<uint8_t>& bytes) {
  out += stream + '|' + label + '|' + encode_hex(bytes) + '\n';
}

std::vector<uint8_t> decode_interop_hex(const std::string& hex) {
  if (hex.size() % 2 != 0) throw std::invalid_argument("invalid hex length");
  std::vector<uint8_t> out(hex.size() / 2);
  for (size_t i = 0; i < out.size(); ++i) {
    const auto hi = hex[i * 2];
    const auto lo = hex[i * 2 + 1];
    auto nibble = [](char ch) -> int {
      if (ch >= '0' && ch <= '9') return ch - '0';
      if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
      if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
      throw std::invalid_argument("invalid hex");
    };
    out[i] = static_cast<uint8_t>((nibble(hi) << 4) | nibble(lo));
  }
  return out;
}

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

}  // namespace

Value InteropFixtures::interop_id_name_map(uint64_t id, const std::string& name) {
  return new_map({entry("id", new_u64(id)), entry("name", new_string(name))});
}

Value InteropFixtures::interop_id_name_role_map(uint64_t id, const std::string& name, const std::string& role) {
  return new_map({entry("id", new_u64(id)), entry("name", new_string(name)), entry("role", new_string(role))});
}

std::vector<Value> InteropFixtures::interop_make_i64_array(int length, int64_t start) {
  std::vector<Value> out;
  out.reserve(static_cast<size_t>(length));
  for (int i = 0; i < length; ++i) out.push_back(new_i64(start + i));
  return out;
}

std::vector<Value> InteropFixtures::interop_make_user_rows(const std::vector<std::string>& names) {
  std::vector<Value> rows;
  rows.reserve(names.size());
  for (size_t i = 0; i < names.size(); ++i) {
    rows.push_back(new_map({entry("id", new_u64(i + 1)), entry("name", new_string(names[i]))}));
  }
  return rows;
}

std::string InteropFixtures::emit_interop_fixtures() {
  std::string out;
  TwilicCodec codec;

  emit_frame(out, "codec", "scalar_string", codec.encode_value(new_string("alpha")));

  const auto map_two = interop_id_name_map(1, "alice");
  emit_frame(out, "codec", "map_two_fields_first", codec.encode_value(map_two));
  reset_encode_shape_observation(codec.state, {"id", "name"});
  emit_frame(out, "codec", "map_two_fields_second", codec.encode_value(map_two));

  const auto map_three = interop_id_name_role_map(1, "alice", "admin");
  emit_frame(out, "codec", "map_three_fields_first", codec.encode_value(map_three));
  reset_encode_shape_observation(codec.state, {"id", "name", "role"});
  emit_frame(out, "codec", "map_three_fields_second", codec.encode_value(map_three));

  for (int i = 0; i < 8; ++i) {
    emit_frame(out, "codec", "bulk_map_" + std::to_string(i),
               codec.encode_value(interop_id_name_map(static_cast<uint64_t>(10 + i), "user-" + std::to_string(i))));
  }

  Message base_snapshot_msg;
  base_snapshot_msg.kind = MessageKind::BaseSnapshot;
  base_snapshot_msg.has_base_snapshot = true;
  base_snapshot_msg.base_snapshot = std::make_unique<BaseSnapshotMessage>();
  base_snapshot_msg.base_snapshot->base_id = 77;
  base_snapshot_msg.base_snapshot->schema_or_shape_ref = 0;
  base_snapshot_msg.base_snapshot->payload.kind = MessageKind::Scalar;
  base_snapshot_msg.base_snapshot->payload.has_scalar = true;
  base_snapshot_msg.base_snapshot->payload.scalar = new_i64(42);
  emit_frame(out, "codec", "base_snapshot", codec.encode_message(base_snapshot_msg));

  SessionEncoder enc;
  emit_frame(out, "session", "session_base_array", enc.encode(new_array(interop_make_i64_array(100, 0))));

  auto one_change_arr = interop_make_i64_array(100, 0);
  one_change_arr[0] = new_i64(10'000);
  emit_frame(out, "session", "session_patch_one_change", enc.encode_patch(new_array(std::move(one_change_arr))));

  for (int step = 0; step < 4; ++step) {
    auto iter_arr = interop_make_i64_array(100, 0);
    iter_arr[static_cast<size_t>(step)] = new_i64(20'000 + step);
    emit_frame(out, "session", "session_patch_iter_" + std::to_string(step),
               enc.encode_patch(new_array(std::move(iter_arr))));
  }

  auto many_arr = interop_make_i64_array(100, 0);
  for (int i = 0; i < 12; ++i) many_arr[static_cast<size_t>(i)] = new_i64(10'000 + i);
  emit_frame(out, "session", "session_patch_many_changes", enc.encode_patch(new_array(std::move(many_arr))));

  emit_frame(out, "session", "session_micro_batch_first",
             enc.encode_micro_batch(interop_make_user_rows({"a", "b", "c", "d"})));
  emit_frame(out, "session", "session_micro_batch_second",
             enc.encode_micro_batch(interop_make_user_rows({"aa", "bb", "cc", "dd"})));

  return out;
}

std::vector<InteropFrame> InteropFixtures::parse_interop_frames(const std::string& input) {
  std::vector<InteropFrame> frames;
  std::istringstream stream(input);
  std::string line;
  int line_no = 0;
  while (std::getline(stream, line)) {
    ++line_no;
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
    if (line.empty()) continue;
    const auto first = line.find('|');
    const auto second = line.find('|', first + 1);
    if (first == std::string::npos || second == std::string::npos || first == 0 || second <= first + 1) {
      throw std::invalid_argument("line " + std::to_string(line_no) + ": invalid frame");
    }
    InteropFrame frame;
    frame.stream = line.substr(0, first);
    frame.label = line.substr(first + 1, second - first - 1);
    frame.hex = line.substr(second + 1);
    frame.bytes = decode_interop_hex(frame.hex);
    frames.push_back(std::move(frame));
  }
  if (frames.empty()) throw std::invalid_argument("no fixture frames found");
  return frames;
}

void InteropFixtures::assert_interop_codec_decode(TwilicCodec& codec, const std::string& label,
                                                  const std::vector<uint8_t>& frame) {
  if (label == "base_snapshot") {
    const auto msg = codec.decode_message(frame);
    require(msg.kind == MessageKind::BaseSnapshot && msg.has_base_snapshot && msg.base_snapshot,
            "expected base snapshot");
    require(msg.base_snapshot->base_id == 77, "base_id mismatch");
    require(msg.base_snapshot->payload.kind == MessageKind::Scalar && msg.base_snapshot->payload.has_scalar,
            "payload kind mismatch");
    require(msg.base_snapshot->payload.scalar.kind == ValueKind::I64 && msg.base_snapshot->payload.scalar.i64 == 42,
            "payload mismatch");
    return;
  }

  if (label.rfind("control_stream_", 0) == 0) {
    const auto msg = codec.decode_message(frame);
    require(msg.kind == MessageKind::ControlStream && msg.has_control_stream, "expected control stream");
    require(!msg.control_stream.payload.empty(), "control stream payload empty for " + label);
    return;
  }

  Value expected;
  if (label == "scalar_string") {
    expected = new_string("alpha");
  } else if (label.rfind("map_two_fields_", 0) == 0) {
    expected = interop_id_name_map(1, "alice");
  } else if (label.rfind("map_three_fields_", 0) == 0) {
    expected = interop_id_name_role_map(1, "alice", "admin");
  } else if (label.rfind("bulk_map_", 0) == 0) {
    const auto idx = std::stoul(label.substr(9));
    expected = interop_id_name_map(10 + idx, "user-" + std::to_string(idx));
  } else {
    throw std::invalid_argument("no codec expectation for label " + label);
  }

  const auto got = codec.decode_value(frame);
  require(equal(got, expected), "decoded value mismatch for " + label);
}

void InteropFixtures::assert_interop_session_decode(TwilicCodec& codec, const std::string& label,
                                                    const std::vector<uint8_t>& frame) {
  if (label == "session_base_array") {
    const auto got = codec.decode_value(frame);
    require(equal(got, new_array(interop_make_i64_array(100, 0))), "session_base_array value mismatch");
    return;
  }

  const auto msg = codec.decode_message(frame);
  if (label == "session_patch_one_change") {
    require(msg.kind == MessageKind::StatePatch || msg.kind == MessageKind::TypedVector ||
                msg.kind == MessageKind::Array,
            "unexpected message kind for session_patch_one_change");
    return;
  }
  if (label == "session_patch_many_changes") {
    require(msg.kind == MessageKind::StatePatch || msg.kind == MessageKind::TypedVector ||
                msg.kind == MessageKind::Array,
            "expected patch or array message");
    return;
  }
  if (label.rfind("session_patch_iter_", 0) == 0) {
    require(msg.kind == MessageKind::StatePatch || msg.kind == MessageKind::TypedVector ||
                msg.kind == MessageKind::Array,
            "expected patch or array message");
    return;
  }
  if (label == "session_micro_batch_first" || label == "session_micro_batch_second") {
    require(msg.kind == MessageKind::TemplateBatch && msg.has_template_batch, "expected template batch");
    require(msg.template_batch.count == 4, "expected template batch with 4 rows");
    return;
  }
  throw std::invalid_argument("no session expectation for label " + label);
}

void InteropFixtures::decode_rust_server_frames(const std::string& input) {
  const auto frames = parse_interop_frames(input);
  TwilicCodec codec_stream;
  TwilicCodec session_stream;
  for (const auto& frame : frames) {
    if (frame.stream == "codec") {
      assert_interop_codec_decode(codec_stream, frame.label, frame.bytes);
    } else if (frame.stream == "session") {
      assert_interop_session_decode(session_stream, frame.label, frame.bytes);
    } else {
      throw std::invalid_argument("unknown stream " + frame.stream);
    }
  }
}

}  // namespace twilic
