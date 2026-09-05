test_that("v2 roundtrip dynamic value", {
  value <- new_map(
    entry("id", new_u64(1001)),
    entry("name", new_string("alice")),
    entry("admin", new_bool(FALSE)),
    entry("scores", new_array(list(
      new_u64(12), new_u64(15), new_u64(18), new_u64(21)
    )))
  )
  encoded <- encode(value)
  decoded <- decode(encoded)
  expect_true(equal(value, decoded))
})

test_that("codec roundtrip dynamic value", {
  value <- new_map(
    entry("id", new_u64(1001)),
    entry("name", new_string("alice")),
    entry("admin", new_bool(FALSE)),
    entry("scores", new_array(list(
      new_u64(12), new_u64(15), new_u64(18), new_u64(21)
    )))
  )
  codec <- new_twilic_codec()
  encoded <- codec$encode_value(value)
  decoded <- codec$decode_value(encoded)
  expect_true(equal(value, decoded))
})

test_that("session patch and micro batch", {
  enc <- new_session_encoder()
  base <- new_map(entry("id", new_u64(1)), entry("name", new_string("alice")))
  nxt <- new_map(entry("id", new_u64(1)), entry("name", new_string("alicia")))
  expect_gt(length(enc$encode(base)), 0L)
  expect_gt(length(enc$encode_patch(nxt)), 0L)
  expect_gt(length(enc$encode_micro_batch(list(base, nxt, base, nxt))), 0L)
})

test_that("unknown reference policy supports stateless retry", {
  opts <- default_session_options()
  opts$unknown_reference_policy <- UnknownReferencePolicyStatelessRetry
  codec <- twilic_codec_with_options(opts)
  patch <- new_message(
    MessageKindSTATE_PATCH,
    state_patch = list(
      base_ref = base_ref_id(777),
      operations = list(),
      literals = list()
    )
  )
  raw <- codec$encode_message(patch)
  decode_codec <- twilic_codec_with_options(opts)
  err <- expect_twilic_error(decode_codec$decode_message(raw), ERR_STATELESS_RETRY_REQUIRED)
  expect_equal(err$ref_kind, "base_id")
  expect_equal(err$ref_id, 777)
})
