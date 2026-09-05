#include "test_helpers.h"

#include "test_internal.h"

using namespace twilic;
using namespace twilic_test;

static std::vector<uint8_t> bitpack_payload() {
  std::vector<uint8_t> out(512);
  for (size_t i = 0; i < out.size(); ++i) out[i] = static_cast<uint8_t>(i % 2);
  return out;
}

static int test_control_stream_roundtrips_for_all_declared_codecs(void) {
  TwilicCodec codec;
  const ControlStreamCodec codecs[] = {ControlStreamCodec::Plain, ControlStreamCodec::Rle,
                                       ControlStreamCodec::Bitpack, ControlStreamCodec::Huffman,
                                       ControlStreamCodec::Fse};
  const auto payload = bitpack_payload();
  for (const auto stream_codec : codecs) {
    Message msg;
    msg.kind = MessageKind::ControlStream;
    msg.has_control_stream = true;
    msg.control_stream.codec = stream_codec;
    msg.control_stream.payload = payload;
    const auto bytes = codec.encode_message(msg);
    const auto decoded = codec.decode_message(bytes);
    TEST_ASSERT(decoded.kind == MessageKind::ControlStream && decoded.has_control_stream, "control stream kind");
    TEST_ASSERT(decoded.control_stream.codec == stream_codec, "codec mismatch");
    TEST_ASSERT(!decoded.control_stream.payload.empty(), "payload non-empty");
  }
  return 0;
}

static int test_register_shape_with_key_ids_roundtrips(void) {
  TwilicCodec codec;
  codec.state.key_table.register_value("id");
  codec.state.key_table.register_value("name");
  codec.state.shape_table.register_keys({"id", "name"});

  const Value value = new_map({entry("id", new_u64(1)), entry("name", new_string("alice"))});
  const auto bytes = codec.encode_value(value);
  const auto msg = codec.decode_message(bytes);
  TEST_ASSERT(msg.kind == MessageKind::ShapedObject || msg.kind == MessageKind::Map, "shaped or map");
  return 0;
}

static int test_reset_state_clears_session_tables(void) {
  TwilicCodec codec;
  const Value value = id_name_map(1, "alice");
  (void)codec.encode_value(value);
  const auto second_before = codec.encode_value(value);
  for (const auto &e : codec.decode_message(second_before).map) {
    TEST_ASSERT(e.key.is_id, "key refs before reset");
  }

  reset_state(codec.state);
  const auto after_reset = codec.encode_value(value);
  for (const auto &e : codec.decode_message(after_reset).map) {
    TEST_ASSERT(!e.key.is_id, "literal keys after reset");
  }
  return 0;
}

int main(void) {
  TEST_RUN(test_control_stream_roundtrips_for_all_declared_codecs);
  TEST_RUN(test_register_shape_with_key_ids_roundtrips);
  TEST_RUN(test_reset_state_clears_session_tables);
  return 0;
}
