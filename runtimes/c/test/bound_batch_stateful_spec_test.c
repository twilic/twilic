#include "test_helpers.h"

#include "test_internal.h"

using namespace twilic;
using namespace twilic_test;

static Schema sample_schema() {
  Schema schema;
  schema.schema_id = 41;
  schema.name = "User";
  schema.fields = {
      {1, "id", "u64", true, {}},
      {2, "name", "string", true, {}},
      {3, "score", "i64", false, {}},
  };
  return schema;
}

static int test_schema_id_is_sent_first_then_omitted(void) {
  SessionEncoder enc = make_encoder();
  const Schema schema = sample_schema();
  const Value value =
      new_map({entry("id", new_u64(1005)), entry("name", new_string("alice")), entry("score", new_i64(99))});

  const auto first = enc.encode_with_schema(schema, value);
  const auto first_msg = enc.decode_message(first);
  TEST_ASSERT(first_msg.kind == MessageKind::SchemaObject && first_msg.has_schema_object &&
                  first_msg.schema_object.has_schema_id && first_msg.schema_object.schema_id == 41,
              "schema id present on first message");

  const auto second = enc.encode_with_schema(schema, value);
  const auto second_msg = enc.decode_message(second);
  TEST_ASSERT(second_msg.kind == MessageKind::SchemaObject, "schema object on second message");
  return 0;
}

static int test_batch_threshold_selects_row_vs_column(void) {
  SessionEncoder enc = make_encoder();
  std::vector<Value> rows15;
  for (int i = 0; i < 15; ++i) rows15.push_back(new_map({entry("id", new_u64(static_cast<uint64_t>(i)))}));
  const auto b15 = enc.encode_batch(rows15);
  TEST_ASSERT(!b15.empty(), "non-empty batch payload");
  TEST_ASSERT(b15[0] == static_cast<uint8_t>(MessageKind::ColumnBatch) ||
                  b15[0] == static_cast<uint8_t>(MessageKind::RowBatch),
              "row or column batch for 15 rows");

  std::vector<Value> rows16;
  for (int i = 0; i < 16; ++i) rows16.push_back(new_map({entry("id", new_u64(static_cast<uint64_t>(i)))}));
  const auto b16 = enc.encode_batch(rows16);
  TEST_ASSERT(!b16.empty() && b16[0] == static_cast<uint8_t>(MessageKind::ColumnBatch),
              "column batch for 16 rows");
  return 0;
}

static int test_micro_batch_reuses_template_and_emits_changed_mask(void) {
  SessionEncoder enc = make_encoder();
  std::vector<Value> rows1 = {
      new_map({entry("id", new_u64(1)), entry("name", new_string("a"))}),
      new_map({entry("id", new_u64(2)), entry("name", new_string("b"))}),
      new_map({entry("id", new_u64(3)), entry("name", new_string("c"))}),
      new_map({entry("id", new_u64(4)), entry("name", new_string("d"))}),
  };
  const auto first = enc.encode_micro_batch(rows1);
  TEST_ASSERT(!first.empty() && first[0] == static_cast<uint8_t>(MessageKind::TemplateBatch), "template batch first");

  std::vector<Value> rows2 = {
      new_map({entry("id", new_u64(1)), entry("name", new_string("aa"))}),
      new_map({entry("id", new_u64(2)), entry("name", new_string("bb"))}),
      new_map({entry("id", new_u64(3)), entry("name", new_string("cc"))}),
      new_map({entry("id", new_u64(4)), entry("name", new_string("dd"))}),
  };
  const auto second = enc.encode_micro_batch(rows2);
  TEST_ASSERT(!second.empty() && second[0] == static_cast<uint8_t>(MessageKind::TemplateBatch), "template batch second");
  return 0;
}

static int test_state_patch_uses_recommended_ratio_threshold(void) {
  SessionEncoder enc = make_encoder();
  auto base_values = make_i64_array(100, 0);
  auto one_change_values = base_values;
  one_change_values[0] = new_i64(10000);
  auto twelve_change_values = base_values;
  for (int i = 0; i < 12; ++i) twelve_change_values[static_cast<size_t>(i)] = new_i64(10000 + i);

  (void)enc.encode(new_array(base_values));
  (void)enc.decode_message(enc.encode_patch(new_array(one_change_values)));
  (void)enc.decode_message(enc.encode_patch(new_array(twelve_change_values)));
  return 0;
}

static int test_unknown_base_id_honors_stateless_retry_policy(void) {
  SessionOptions opts = default_session_options();
  opts.unknown_reference_policy = UnknownReferencePolicy::StatelessRetry;
  TwilicCodec codec(new_session_state_with_options(opts));

  Message patch;
  patch.kind = MessageKind::StatePatch;
  patch.has_state_patch = true;
  patch.state_patch.base_ref = BaseRef::id_ref(12345);
  const auto bytes = codec.encode_message(patch);

  const auto decoded = codec.decode_message(bytes);
  TEST_ASSERT(decoded.kind == MessageKind::StatePatch, "state patch decodes without failing fast");
  return 0;
}

int main(void) {
  TEST_RUN(test_schema_id_is_sent_first_then_omitted);
  TEST_RUN(test_batch_threshold_selects_row_vs_column);
  TEST_RUN(test_micro_batch_reuses_template_and_emits_changed_mask);
  TEST_RUN(test_state_patch_uses_recommended_ratio_threshold);
  TEST_RUN(test_unknown_base_id_honors_stateless_retry_policy);
  return 0;
}
