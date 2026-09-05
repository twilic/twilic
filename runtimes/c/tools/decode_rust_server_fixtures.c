#include <iostream>
#include <sstream>
#include <string>

#include "twilic/interop_fixtures.h"

int main(void) {
  std::ostringstream input;
  input << std::cin.rdbuf();
  twilic::InteropFixtures::decode_rust_server_frames(input.str());
  return 0;
}
