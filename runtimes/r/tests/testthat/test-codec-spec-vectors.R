test_that("simple8b i64 roundtrip small values", {
  values <- c(1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5)
  out <- twilic:::new_buffer()
  out <- encode_i64_vector(values, VectorCodecSIMPLE8B, out)
  reader <- twilic:::new_reader(out)
  decoded <- decode_i64_vector(reader, VectorCodecSIMPLE8B)
  expect_equal(length(decoded), length(values))
  expect_equal(decoded, values)
})

test_that("simple8b u64 roundtrip with long zero runs", {
  values <- c(rep(0, 130), 1:5, rep(0, 250))
  out <- twilic:::new_buffer()
  out <- encode_u64_vector(values, VectorCodecSIMPLE8B, out)
  reader <- twilic:::new_reader(out)
  decoded <- decode_u64_vector(reader, VectorCodecSIMPLE8B)
  expect_equal(decoded, values)
})

test_that("simple8b u64 falls back for large values", {
  values <- c(2^61, 2^61 + 7, 2^61 + 99)
  out <- twilic:::new_buffer()
  out <- encode_u64_vector(values, VectorCodecSIMPLE8B, out)
  reader <- twilic:::new_reader(out)
  decoded <- decode_u64_vector(reader, VectorCodecSIMPLE8B)
  expect_equal(decoded, values)
})

test_that("direct bitpack invalid width is rejected", {
  out <- twilic:::new_buffer()
  out <- encode_varuint(1, out)
  out <- c(out, as.raw(0))
  reader <- twilic:::new_reader(out)
  expect_twilic_error(decode_i64_vector(reader, VectorCodecDIRECT_BITPACK), ERR_INVALID_DATA, "bitpack width")
})

test_that("for u64 overflow is rejected", {
  # Bytes from Ruby spec: varuint(max u64), varuint(1), mode byte 1, width 0
  out <- as.raw(c(
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01,
    0x01, 0x01, 0x01
  ))
  reader <- twilic:::new_reader(out)
  expect_error(
    decode_u64_vector(reader, VectorCodecFOR_BITPACK),
    "u64 FOR overflow"
  )
})

test_that("xor float roundtrip smooth series", {
  values <- c(1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5)
  out <- twilic:::new_buffer()
  out <- encode_f64_vector(values, VectorCodecXOR_FLOAT, out)
  reader <- twilic:::new_reader(out)
  decoded <- decode_f64_vector(reader, VectorCodecXOR_FLOAT)
  expect_equal(decoded, values)
})
