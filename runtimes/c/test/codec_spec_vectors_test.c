#include "test_helpers.h"

#include "test_internal.h"
#include "twilic/codec.h"

using namespace twilic;

static int test_direct_bitpack_invalid_width_is_rejected(void) {
  Buffer bytes;
  encode_varuint(1, bytes);
  bytes.push_back(0);
  Reader reader(bytes);
  try {
    (void)decode_i64_vector(reader, VectorCodec::DirectBitpack);
    TEST_ASSERT(0, "expected invalid data");
  } catch (const TwilicError &err) {
    TEST_ASSERT(err.kind == TwilicErrorKind::ErrInvalidData, "invalid data kind");
    TEST_ASSERT(std::string(err.what()) == "bitpack width", "bitpack width message");
  }
  return 0;
}

static int test_i64_plain_roundtrip(void) {
  const std::vector<int64_t> values = {1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5};
  Buffer out;
  encode_i64_vector(values, VectorCodec::Plain, out);
  Reader reader(out);
  const auto decoded = decode_i64_vector(reader, VectorCodec::Plain);
  TEST_ASSERT(decoded.size() == values.size(), "length mismatch");
  for (size_t i = 0; i < values.size(); ++i) TEST_ASSERT(decoded[i] == values[i], "value mismatch");
  return 0;
}

static int test_f64_plain_roundtrip(void) {
  const std::vector<double> values = {1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5};
  Buffer out;
  encode_f64_vector(values, VectorCodec::Plain, out);
  Reader reader(out);
  const auto decoded = decode_f64_vector(reader, VectorCodec::Plain);
  TEST_ASSERT(decoded.size() == values.size(), "length mismatch");
  for (size_t i = 0; i < values.size(); ++i) TEST_ASSERT(decoded[i] == values[i], "value mismatch");
  return 0;
}

int main(void) {
  TEST_RUN(test_direct_bitpack_invalid_width_is_rejected);
  TEST_RUN(test_i64_plain_roundtrip);
  TEST_RUN(test_f64_plain_roundtrip);
  return 0;
}
