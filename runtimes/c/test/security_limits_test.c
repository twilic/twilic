#include "twilic/wire.h"
#include "twilic/v2.h"
#include "twilic/codec.h"
#include "twilic/errors.h"
#include <cstdlib>
#include <functional>
using namespace twilic;
static void rejects(const std::function<void()>& action) {
  bool rejected = false;
  try { action(); } catch (const TwilicError&) { rejected = true; }
  if (!rejected) std::abort();
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
