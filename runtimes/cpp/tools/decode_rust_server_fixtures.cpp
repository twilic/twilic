#include <iostream>
#include <sstream>
#include <string>

#include "twilic/interop_fixtures.hpp"

int main() {
  try {
    std::ostringstream input;
    input << std::cin.rdbuf();
    twilic::InteropFixtures::decode_rust_server_frames(input.str());
    std::cout << "C++ client decode and value checks passed for Rust frames\n";
    return 0;
  } catch (const std::exception& ex) {
    std::cerr << "decode fixtures: " << ex.what() << '\n';
    return 1;
  }
}
