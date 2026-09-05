test_that("encode decode map matches python vector", {
  value <- new_map(entry("x", new_string("y")))
  data <- encode(value)
  expect_equal(paste0(sprintf("%02x", as.integer(data)), collapse = ""), "b181788179")
  expect_true(equal(value, decode(data)))
})

test_that("v2 string roundtrip", {
  value <- new_string("alpha")
  bytes <- twilic:::encode_v2(value)
  decoded <- twilic:::decode_v2(bytes)
  expect_true(equal(decoded, value))
})

test_that("encode and decode via public API", {
  value <- new_map(entry("id", new_u64(1)), entry("name", new_string("alice")))
  bytes <- encode(value)
  decoded <- decode(bytes)
  expect_true(equal(decoded, value))
})
