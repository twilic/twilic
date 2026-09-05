test_that("shape promotes after second three field map", {
  codec <- new_twilic_codec()
  value <- new_map(
    entry("id", new_u64(1)),
    entry("name", new_string("alice")),
    entry("role", new_string("admin"))
  )
  first_msg <- codec$decode_message(codec$encode_value(value))
  expect_equal(first_msg$kind, MessageKindMAP)
  second_msg <- codec$decode_message(codec$encode_value(value))
  expect_equal(second_msg$kind, MessageKindSHAPED_OBJECT)
  third_msg <- codec$decode_message(codec$encode_value(value))
  expect_equal(third_msg$kind, MessageKindSHAPED_OBJECT)
})

test_that("two field map keeps map and uses key ids", {
  codec <- new_twilic_codec()
  value <- new_map(entry("id", new_u64(1)), entry("name", new_string("alice")))
  first_msg <- codec$decode_message(codec$encode_value(value))
  expect_equal(first_msg$kind, MessageKindMAP)
  for (entry_item in first_msg$map) {
    expect_false(entry_item$key$is_id)
  }
  second_msg <- codec$decode_message(codec$encode_value(value))
  expect_true(second_msg$kind %in% c(MessageKindMAP, MessageKindSHAPED_OBJECT))
  if (second_msg$kind == MessageKindMAP) {
    for (entry_item in second_msg$map) {
      expect_true(entry_item$key$is_id)
    }
  }
})

test_that("typed vector threshold is applied", {
  codec <- new_twilic_codec()
  short <- new_array(list(new_i64(1), new_i64(2), new_i64(3)))
  short_msg <- codec$decode_message(codec$encode_value(short))
  expect_equal(short_msg$kind, MessageKindARRAY)
  long_items <- lapply(seq_len(16) - 1L, function(i) new_i64(1000 + i * 10))
  long <- new_array(long_items)
  long_msg <- codec$decode_message(codec$encode_value(long))
  expect_equal(long_msg$kind, MessageKindTYPED_VECTOR)
})

test_that("string modes empty ref and prefix delta are used", {
  codec <- new_twilic_codec()
  empty_bytes <- codec$encode_value(new_string(""))
  expect_equal(scalar_string_mode(empty_bytes), StringModeEMPTY)
  lit_bytes <- codec$encode_value(new_string("alpha"))
  expect_equal(scalar_string_mode(lit_bytes), StringModeLITERAL)
  ref_bytes <- codec$encode_value(new_string("alpha"))
  expect_equal(scalar_string_mode(ref_bytes), StringModeREF)
  codec$encode_value(new_string("prefix_common_aaaa"))
  prefix_delta_bytes <- codec$encode_value(new_string("prefix_common_bbbb"))
  expect_equal(scalar_string_mode(prefix_delta_bytes), StringModePREFIX_DELTA)
})

test_that("reset tables clears string interning", {
  codec <- new_twilic_codec()
  codec$encode_value(new_string("ephemeral"))
  reused_bytes <- codec$encode_value(new_string("ephemeral"))
  expect_equal(scalar_string_mode(reused_bytes), StringModeREF)
  reset <- new_message(
    MessageKindCONTROL,
    control = control_message(opcode = ControlOpcodeRESET_TABLES, reset_tables = TRUE)
  )
  codec$decode_message(codec$encode_message(reset))
  after_bytes <- codec$encode_value(new_string("ephemeral"))
  expect_equal(scalar_string_mode(after_bytes), StringModeLITERAL)
})
