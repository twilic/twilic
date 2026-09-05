#include <cassert>
#include <vector>

#include "twilic/twilic.hpp"

using namespace twilic;

static Value sample_value() {
  return new_map({
      entry("id", new_u64(1001)),
      entry("name", new_string("alice")),
      entry("admin", new_bool(false)),
      entry("scores", new_array({new_u64(12), new_u64(15), new_u64(18), new_u64(21)})),
  });
}

int main() {
  const auto value = sample_value();

  const auto encoded_v2 = encode(value);
  const auto decoded_v2 = decode(encoded_v2);
  assert(equal(decoded_v2, value));

  TwilicCodec codec = new_twilic_codec();
  const auto encoded_codec = codec.encode_value(value);
  const auto decoded_codec = codec.decode_value(encoded_codec);
  assert(equal(decoded_codec, value));

  SessionEncoder enc;
  assert(!enc.encode(value).empty());
  assert(!enc.encode_batch({value, value}).empty());

  return 0;
}
