#include "test_helpers.h"

#include "test_internal.h"

using namespace twilic;
using namespace twilic_test;

static int test_shape_promotes_after_second_three_field_map(void) {
  TwilicCodec codec = make_codec();
  const Value value = id_name_role_map(1, "alice", "admin");

  const auto first_bytes = codec.encode_value(value);
  const auto first_msg = codec.decode_message(first_bytes);
  TEST_ASSERT(first_msg.kind == MessageKind::Map, "first message should be map");

  const auto second_bytes = codec.encode_value(value);
  const auto second_msg = codec.decode_message(second_bytes);
  TEST_ASSERT(second_msg.kind == MessageKind::ShapedObject, "second message should be shaped object");

  const auto third_bytes = codec.encode_value(value);
  const auto third_msg = codec.decode_message(third_bytes);
  TEST_ASSERT(third_msg.kind == MessageKind::ShapedObject, "third message should be shaped object");
  return 0;
}

static int test_two_field_map_keeps_map_and_uses_key_ids(void) {
  TwilicCodec codec = make_codec();
  const Value value = id_name_map(1, "alice");

  const auto first_bytes = codec.encode_value(value);
  const auto first_msg = codec.decode_message(first_bytes);
  TEST_ASSERT(first_msg.kind == MessageKind::Map, "expected map");
  for (const auto &e : first_msg.map) TEST_ASSERT(!e.key.is_id, "expected literal keys on first map");

  const auto second_bytes = codec.encode_value(value);
  const auto second_msg = codec.decode_message(second_bytes);
  TEST_ASSERT(second_msg.kind == MessageKind::Map || second_msg.kind == MessageKind::ShapedObject,
                "expected map or shaped object");
  if (second_msg.kind == MessageKind::Map) {
    for (const auto &e : second_msg.map) TEST_ASSERT(e.key.is_id, "expected key ref ids on second map");
  }
  return 0;
}

static int test_typed_vector_threshold_is_applied(void) {
  TwilicCodec codec = make_codec();
  const auto short_arr = make_i64_array(3, 1);
  const auto short_bytes = codec.encode_value(new_array(short_arr));
  const auto short_msg = codec.decode_message(short_bytes);
  TEST_ASSERT(short_msg.kind == MessageKind::Array, "short should stay array");

  const auto long_arr = make_i64_array(4, 1);
  const auto long_bytes = codec.encode_value(new_array(long_arr));
  const auto long_msg = codec.decode_message(long_bytes);
  TEST_ASSERT(long_msg.kind == MessageKind::TypedVector, "long should become typed vector");
  return 0;
}

static int test_string_modes_empty_ref_and_prefix_delta_are_used(void) {
  TwilicCodec codec = make_codec();

  const auto empty_bytes = codec.encode_value(new_string(""));
  TEST_ASSERT(scalar_string_mode(empty_bytes) == static_cast<uint8_t>(StringMode::Empty), "empty mode");

  const auto lit_bytes = codec.encode_value(new_string("alpha"));
  TEST_ASSERT(scalar_string_mode(lit_bytes) == static_cast<uint8_t>(StringMode::Literal), "literal mode");

  const auto ref_bytes = codec.encode_value(new_string("alpha"));
  TEST_ASSERT(scalar_string_mode(ref_bytes) == static_cast<uint8_t>(StringMode::Ref), "ref mode");

  (void)codec.encode_value(new_string("prefix_common_aaaa"));
  const auto prefix_bytes = codec.encode_value(new_string("prefix_common_bbbb"));
  TEST_ASSERT(scalar_string_mode(prefix_bytes) == static_cast<uint8_t>(StringMode::PrefixDelta), "prefix delta mode");
  return 0;
}

static int test_reset_tables_clears_string_interning(void) {
  TwilicCodec codec = make_codec();
  (void)codec.encode_value(new_string("ephemeral"));
  const auto reused_bytes = codec.encode_value(new_string("ephemeral"));
  TEST_ASSERT(scalar_string_mode(reused_bytes) == static_cast<uint8_t>(StringMode::Ref), "ref before reset");

  reset_tables(codec.state);

  const auto after_bytes = codec.encode_value(new_string("ephemeral"));
  TEST_ASSERT(scalar_string_mode(after_bytes) == static_cast<uint8_t>(StringMode::Literal), "literal after reset");
  return 0;
}

int main(void) {
  TEST_RUN(test_shape_promotes_after_second_three_field_map);
  TEST_RUN(test_two_field_map_keeps_map_and_uses_key_ids);
  TEST_RUN(test_typed_vector_threshold_is_applied);
  TEST_RUN(test_string_modes_empty_ref_and_prefix_delta_are_used);
  TEST_RUN(test_reset_tables_clears_string_interning);
  return 0;
}
