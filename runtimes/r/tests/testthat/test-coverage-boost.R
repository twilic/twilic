I64_CODECS <- list(
  VectorCodecPLAIN,
  VectorCodecDIRECT_BITPACK,
  VectorCodecDELTA_BITPACK,
  VectorCodecFOR_BITPACK,
  VectorCodecDELTA_FOR_BITPACK,
  VectorCodecDELTA_DELTA_BITPACK,
  VectorCodecRLE,
  VectorCodecPATCHED_FOR,
  VectorCodecSIMPLE8B
)

test_that("model from_byte and display branches", {
  expect_false(is.null(message_kind_from_byte(0x0D)[[2]]))
  expect_false(message_kind_from_byte(0xFE)[[2]])
  expect_false(is.null(string_mode_from_byte(4)[[2]]))
  expect_false(string_mode_from_byte(9)[[2]])
  expect_false(is.null(element_type_from_byte(6)[[2]]))
  expect_false(element_type_from_byte(9)[[2]])
  expect_false(is.null(vector_codec_from_byte(12)[[2]]))
  expect_false(vector_codec_from_byte(99)[[2]])
  expect_false(is.null(control_opcode_from_byte(5)[[2]]))
  expect_false(control_opcode_from_byte(7)[[2]])
  expect_false(is.null(patch_opcode_from_byte(8)[[2]]))
  expect_false(patch_opcode_from_byte(42)[[2]])
  expect_false(is.null(control_stream_codec_from_byte(4)[[2]]))
  expect_false(control_stream_codec_from_byte(7)[[2]])
})

test_that("wire reader error branches", {
  r <- twilic:::new_reader(raw())
  expect_twilic_error(r$read_u8(), ERR_UNEXPECTED_EOF)
  too_long <- as.raw(rep(128L, 11L))
  r <- twilic:::new_reader(too_long)
  expect_twilic_error(r$read_varuint(), ERR_INVALID_DATA)
  invalid_utf8 <- as.raw(c(1L, 255L))
  r <- twilic:::new_reader(invalid_utf8)
  expect_twilic_error(r$read_string(), ERR_UTF8)
  bytes <- twilic:::new_buffer()
  bytes <- encode_varuint(9, bytes)
  bytes <- c(bytes, as.raw(c(0x55L, 0x01L)))
  r <- twilic:::new_reader(bytes)
  bits <- r$read_bitmap()
  expect_length(bits, 9L)
  expect_true(bits[[1]])
  expect_true(bits[[9]])
})

test_that("codec variants roundtrip and error path", {
  values <- c(100, 110, 120, 130, 130, 130, 140, 150, 160, 170)
  for (codec in I64_CODECS) {
    out <- twilic:::new_buffer()
    out <- encode_i64_vector(values, codec, out)
    reader <- twilic:::new_reader(out)
    decoded <- decode_i64_vector(reader, codec)
    expect_length(decoded, length(values))
  }
  f_values <- c(1.0, 1.0, 1.5, 1.75, 1.875)
  for (codec in list(VectorCodecXOR_FLOAT, VectorCodecPLAIN)) {
    out <- twilic:::new_buffer()
    out <- encode_f64_vector(f_values, codec, out)
    reader <- twilic:::new_reader(out)
    decoded <- decode_f64_vector(reader, codec)
    expect_length(decoded, length(f_values))
  }
  out <- twilic:::new_buffer()
  out <- encode_u64_vector(c(10, 20, 30, 40), VectorCodecDELTA_BITPACK, out)
  reader <- twilic:::new_reader(out)
  decoded <- decode_u64_vector(reader, VectorCodecDELTA_BITPACK)
  expect_length(decoded, 4L)
})

test_that("protocol error and control branches", {
  codec <- new_twilic_codec()
  reset_tables <- new_message(
    MessageKindCONTROL,
    control = control_message(opcode = ControlOpcodeRESET_TABLES, reset_tables = TRUE)
  )
  codec$decode_message(codec$encode_message(reset_tables))
  reset_state <- new_message(
    MessageKindCONTROL,
    control = control_message(opcode = ControlOpcodeRESET_STATE, reset_state = TRUE)
  )
  codec$decode_message(codec$encode_message(reset_state))
  malformed <- twilic:::new_buffer()
  malformed <- raw_append_byte(malformed, MessageKindSCHEMA_OBJECT)
  malformed <- encode_varuint(1, malformed)
  malformed <- c(malformed, as.raw(c(0, 3, 1, 2, 0, 0)))
  expect_twilic_error(codec$decode_message(malformed), ERR_INVALID_DATA)
})

test_that("typed vector length mismatch is rejected", {
  codec <- new_twilic_codec()
  bytes <- twilic:::new_buffer()
  bytes <- raw_append_byte(bytes, MessageKindTYPED_VECTOR)
  bytes <- raw_append_byte(bytes, ElementTypeU64)
  bytes <- encode_varuint(2, bytes)
  bytes <- raw_append_byte(bytes, VectorCodecPLAIN)
  bytes <- raw_append_byte(bytes, 1L)
  bytes <- encode_varuint(99, bytes)
  expect_twilic_error(codec$decode_message(bytes), ERR_INVALID_DATA)
})

test_that("micro batch falls back when shape is not uniform", {
  enc <- new_session_encoder(default_session_options())
  values <- list(
    new_map(entry("id", new_u64(1))),
    new_map(entry("id", new_u64(2)), entry("x", new_u64(10))),
    new_map(entry("id", new_u64(3))),
    new_map(entry("id", new_u64(4)), entry("x", new_u64(20)))
  )
  decoded <- enc$decode_message(enc$encode_micro_batch(values))
  expect_true(decoded$kind %in% c(MessageKindROW_BATCH, MessageKindCOLUMN_BATCH))
})

test_that("unknown reference stateless retry paths", {
  opts <- default_session_options()
  opts$unknown_reference_policy <- UnknownReferencePolicyStatelessRetry
  codec <- twilic_codec_with_options(opts)
  previous_missing <- twilic:::new_buffer()
  previous_missing <- raw_append_byte(previous_missing, MessageKindSTATE_PATCH)
  previous_missing <- raw_append_byte(previous_missing, 0L)
  previous_missing <- encode_varuint(0, previous_missing)
  previous_missing <- encode_varuint(0, previous_missing)
  expect_twilic_error(codec$decode_message(previous_missing), ERR_STATELESS_RETRY_REQUIRED)
  base_missing <- twilic:::new_buffer()
  base_missing <- raw_append_byte(base_missing, MessageKindSTATE_PATCH)
  base_missing <- raw_append_byte(base_missing, 1L)
  base_missing <- encode_varuint(1000, base_missing)
  base_missing <- encode_varuint(0, base_missing)
  base_missing <- encode_varuint(0, base_missing)
  expect_twilic_error(codec$decode_message(base_missing), ERR_STATELESS_RETRY_REQUIRED)
})

test_that("unknown dict reference fail fast path", {
  encoder <- new_twilic_codec()
  did <- 88L
  msg <- new_message(
    MessageKindCOLUMN_BATCH,
    column_batch = list(
      count = 1L,
      columns = list(list(
        field_id = 0L,
        null_strategy = NullStrategyALL_PRESENT_ELIDED,
        presence = list(),
        has_presence = FALSE,
        codec = VectorCodecDICTIONARY,
        dictionary_id = did,
        values = empty_typed_vector_data(ElementTypeSTRING)
      ))
    )
  )
  msg$column_batch$columns[[1]]$values$strings <- list("x")
  bytes <- encoder$encode_message(msg)
  decoder <- new_twilic_codec()
  err <- expect_twilic_error(decoder$decode_message(bytes), ERR_UNKNOWN_REFERENCE)
  expect_true(is_unknown_reference(err))
})
