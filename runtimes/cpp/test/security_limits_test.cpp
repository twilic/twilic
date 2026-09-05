#include "twilic/wire.hpp"
#include "twilic/v2.hpp"
#include "twilic/codec.hpp"
#include "twilic/errors.hpp"
#include <cassert>
#include <functional>
using namespace twilic;
static void rejects(const std::function<void()>& action) {
  bool rejected = false;
  try { action(); } catch (const TwilicError&) { rejected = true; }
  assert(rejected);
}
int main() {
  Buffer tiny{0}; Reader reader(tiny);
  reader.claim_output(100);
  rejects([&] { reader.claim_output(100); });
  rejects([&] { reader.read_exact(static_cast<size_t>(-1)); });
  Buffer nested(70, 0xa1); nested.push_back(0xc0);
  rejects([&] { decode_v2(nested); });
  decode_v2(Buffer{0xa0});
  Buffer runs; for (auto n : {1, 0, 100000}) encode_varuint(n, runs);
  Reader rle(runs);
  rejects([&] { decode_u64_vector(rle, VectorCodec::Rle); });
}
