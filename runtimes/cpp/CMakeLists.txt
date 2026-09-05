cmake_minimum_required(VERSION 3.16)
project(twilic CXX)

set(CMAKE_CXX_STANDARD 17)

add_library(twilic
  src/wire.cpp
  src/errors.cpp
  src/model.cpp
  src/v2.cpp
  src/session.cpp
  src/codec.cpp
  src/protocol_helpers.cpp
  src/protocol.cpp
  src/dictionary.cpp
  src/interop_fixtures.cpp
)
target_include_directories(twilic PUBLIC include)

enable_testing()

add_executable(twilic_smoke_test test/smoke_test.cpp)
target_link_libraries(twilic_smoke_test PRIVATE twilic)
add_test(NAME smoke COMMAND twilic_smoke_test)

add_executable(twilic_interop_fixtures_test test/interop_fixtures_test.cpp)
target_link_libraries(twilic_interop_fixtures_test PRIVATE twilic)
add_test(NAME interop_fixtures COMMAND twilic_interop_fixtures_test)

add_executable(emit_rust_client_fixtures tools/emit_rust_client_fixtures.cpp)
target_link_libraries(emit_rust_client_fixtures PRIVATE twilic)

add_executable(decode_rust_server_fixtures tools/decode_rust_server_fixtures.cpp)
target_link_libraries(decode_rust_server_fixtures PRIVATE twilic)

add_executable(security_limits_test test/security_limits_test.cpp)
target_link_libraries(security_limits_test PRIVATE twilic)
add_test(NAME security_limits COMMAND security_limits_test)
