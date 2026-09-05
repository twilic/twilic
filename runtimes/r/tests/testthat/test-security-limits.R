test_that("decode limits reject invalid input before expansion", {
  reader <- new_reader(as.raw(0))
  reader$claim_output(100)
  expect_error(reader$claim_output(100), "output ratio")
  expect_error(reader$read_exact(-1))
  expect_error(decode_v2(as.raw(c(rep(0xa1, 70), 0xc0))), "depth limit")
})

test_that("an empty shape is accepted without table growth loops", {
  value <- decode_v2(as.raw(c(0xa1, 0xd6, 0, 0)))
  expect_length(value$arr, 1L)
})
