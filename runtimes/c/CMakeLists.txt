cmake_minimum_required(VERSION 3.16)
project(twilic C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_compile_options(
  "$<$<COMPILE_LANGUAGE:C>:-Wall;-Wextra;-Werror>"
  "$<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Werror>"
)

set(TWILIC_CXX_SOURCES
  src/wire.c
  src/errors.c
  src/model.c
  src/v2.c
  src/session.c
  src/codec.c
  src/protocol_helpers.c
  src/protocol.c
  src/dictionary.c
  src/interop_fixtures.c
  src/twilic.c
)

add_library(twilic ${TWILIC_CXX_SOURCES})
set_source_files_properties(${TWILIC_CXX_SOURCES} PROPERTIES LANGUAGE CXX)
target_compile_options(twilic PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-Wno-deprecated>)
target_include_directories(twilic PUBLIC include)

enable_testing()

set(TWILIC_TEST_SOURCES
  test/security_limits_test.c
  test/test_helpers.c
  test/dynamic_profile_spec_test.c
  test/bound_batch_stateful_spec_test.c
  test/codec_spec_vectors_test.c
  test/control_stream_and_control_spec_test.c
  test/coverage_boost_test.c
  test/interop_fixtures_test.c
)

foreach(test_src ${TWILIC_TEST_SOURCES})
  get_filename_component(test_name ${test_src} NAME_WE)
  add_executable(${test_name} ${test_src})
  set_source_files_properties(${test_src} PROPERTIES LANGUAGE CXX)
  target_compile_options(${test_name} PRIVATE -Wno-deprecated)
  target_link_libraries(${test_name} PRIVATE twilic)
  add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

add_executable(emit_rust_client_fixtures tools/emit_rust_client_fixtures.c)
set_source_files_properties(tools/emit_rust_client_fixtures.c PROPERTIES LANGUAGE CXX)
target_compile_options(emit_rust_client_fixtures PRIVATE -Wno-deprecated)
target_link_libraries(emit_rust_client_fixtures PRIVATE twilic)

add_executable(decode_rust_server_fixtures tools/decode_rust_server_fixtures.c)
set_source_files_properties(tools/decode_rust_server_fixtures.c PROPERTIES LANGUAGE CXX)
target_compile_options(decode_rust_server_fixtures PRIVATE -Wno-deprecated)
target_link_libraries(decode_rust_server_fixtures PRIVATE twilic)
