#include "test_helpers.h"

#include "test_internal.h"
#include "twilic/v2.h"

using namespace twilic;

static int test_public_api_wrappers_are_covered(void) {
  twilic_map_entry_t entries[] = {
      twilic_entry("id", twilic_u64(1001)),
      twilic_entry("name", twilic_string("alice")),
  };
  twilic_value_t value = twilic_map(entries, 2);

  twilic_buffer_t encoded{};
  twilic_error_t err{};
  TEST_ASSERT(twilic_encode(&value, &encoded, &err) == 0, "encode");

  twilic_value_t decoded = twilic_null();
  TEST_ASSERT(twilic_decode(encoded.data, encoded.len, &decoded, &err) == 0, "decode");
  TEST_ASSERT(values_equal(&value, &decoded), "roundtrip equal");

  twilic_schema_field_t fields[] = {
      {1, const_cast<char *>("id"), const_cast<char *>("u64"), true, nullptr, 0},
      {2, const_cast<char *>("name"), const_cast<char *>("string"), true, nullptr, 0},
  };
  twilic_schema_t schema{41, const_cast<char *>("User"), fields, 2};
  twilic_buffer_t schema_encoded{};
  TEST_ASSERT(twilic_encode_with_schema(&schema, &value, &schema_encoded, &err) == 0, "encode with schema");

  twilic_value_t batch_values[] = {value, value};
  twilic_buffer_t batch_encoded{};
  TEST_ASSERT(twilic_encode_batch(batch_values, 2, &batch_encoded, &err) == 0, "encode batch");

  twilic_value_free(&decoded);
  twilic_value_free(&value);
  twilic_buffer_free(&encoded);
  twilic_buffer_free(&schema_encoded);
  twilic_buffer_free(&batch_encoded);
  return 0;
}

static int test_v2_roundtrip_dynamic_value(void) {
  const Value value = new_map({
      entry("id", new_u64(1001)),
      entry("name", new_string("alice")),
      entry("active", new_bool(true)),
  });
  const auto encoded = encode_v2(value);
  const auto decoded = decode_v2(encoded);
  TEST_ASSERT(equal(decoded, value), "v2 roundtrip");
  return 0;
}

static int test_smoke_session_encoder(void) {
  SessionEncoder enc;
  const Value value = new_map({entry("id", new_u64(1)), entry("name", new_string("alice"))});
  const auto bytes = enc.encode(value);
  TEST_ASSERT(!bytes.empty(), "session encode non-empty");
  const std::vector<Value> batch = {value, value};
  const auto batch_bytes = enc.encode_batch(batch);
  TEST_ASSERT(!batch_bytes.empty(), "batch encode non-empty");
  return 0;
}

int main(void) {
  TEST_RUN(test_public_api_wrappers_are_covered);
  TEST_RUN(test_v2_roundtrip_dynamic_value);
  TEST_RUN(test_smoke_session_encoder);
  return 0;
}
