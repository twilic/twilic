CONTROL_STREAM_CODECS <- list(
  ControlStreamCodecPLAIN,
  ControlStreamCodecRLE,
  ControlStreamCodecBITPACK,
  ControlStreamCodecHUFFMAN,
  ControlStreamCodecFSE
)

test_that("control stream roundtrips for all declared codecs", {
  codec <- new_twilic_codec()
  payload <- as.raw(c(0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4))
  for (stream_codec in CONTROL_STREAM_CODECS) {
    msg <- new_message(
      MessageKindCONTROL_STREAM,
      control_stream = list(codec = stream_codec, payload = payload)
    )
    bytes <- codec$encode_message(msg)
    decoded <- codec$decode_message(bytes)
    expect_true(equal_message(decoded, msg), info = sprintf("codec %s", stream_codec))
  }
})

test_that("control stream bitpack huffman fse compact repetitive payloads", {
  binary_payload <- as.raw((seq_len(512) - 1L) %% 2L)
  plain_binary_len <- encoded_control_stream_len(ControlStreamCodecPLAIN, binary_payload)
  bitpack_len <- encoded_control_stream_len(ControlStreamCodecBITPACK, binary_payload)
  expect_lte(bitpack_len, plain_binary_len)

  rle_friendly <- as.raw(rep(7L, 512L))
  plain_rle_len <- encoded_control_stream_len(ControlStreamCodecPLAIN, rle_friendly)
  huffman_len <- encoded_control_stream_len(ControlStreamCodecHUFFMAN, rle_friendly)
  expect_lte(huffman_len, plain_rle_len)

  low_card <- as.raw((seq_len(512) - 1L) %% 4L)
  plain_low_card_len <- encoded_control_stream_len(ControlStreamCodecPLAIN, low_card)
  fse_len <- encoded_control_stream_len(ControlStreamCodecFSE, low_card)
  expect_lte(fse_len, plain_low_card_len)
})

test_that("control stream fse uses fse frame mode", {
  codec <- new_twilic_codec()
  payload <- as.raw((seq_len(512) - 1L) %% 4L)
  msg <- new_message(
    MessageKindCONTROL_STREAM,
    control_stream = list(codec = ControlStreamCodecFSE, payload = payload)
  )
  data <- codec$encode_message(msg)
  reader <- twilic:::new_reader(data)
  expect_equal(reader$read_u8(), MessageKindCONTROL_STREAM)
  expect_equal(reader$read_u8(), ControlStreamCodecFSE)
  framed <- reader$read_bytes()
  expect_gt(length(framed), 0L)
})

test_that("register shape with key ids roundtrips", {
  codec <- new_twilic_codec()
  reg_keys <- new_message(
    MessageKindCONTROL,
    control = control_message(
      opcode = ControlOpcodeREGISTER_KEYS,
      register_keys = c("id", "name")
    )
  )
  codec$decode_message(codec$encode_message(reg_keys))
  reg_shape <- new_message(
    MessageKindCONTROL,
    control = control_message(
      opcode = ControlOpcodeREGISTER_SHAPE,
      register_shape = list(
        shape_id = 99L,
        keys = list(key_ref_id(0L), key_ref_id(1L))
      )
    )
  )
  decoded <- codec$decode_message(codec$encode_message(reg_shape))
  expect_equal(decoded$kind, MessageKindCONTROL)
  expect_false(is.null(decoded$control$register_shape))
  shaped <- new_message(
    MessageKindSHAPED_OBJECT,
    shaped_object = list(
      shape_id = 99L,
      presence = NULL,
      has_presence = FALSE,
      values = list(new_u64(1), new_string("alice"))
    )
  )
  value <- codec$decode_value(codec$encode_message(shaped))
  expect_equal(value$kind, ValueKindMAP)
})

test_that("reset state clears shape resolution", {
  codec <- new_twilic_codec()
  reg_shape <- new_message(
    MessageKindCONTROL,
    control = control_message(
      opcode = ControlOpcodeREGISTER_SHAPE,
      register_shape = list(
        shape_id = 7L,
        keys = list(key_ref_literal("id"), key_ref_literal("name"))
      )
    )
  )
  codec$decode_message(codec$encode_message(reg_shape))
  reset <- new_message(
    MessageKindCONTROL,
    control = control_message(opcode = ControlOpcodeRESET_STATE, reset_state = TRUE)
  )
  codec$decode_message(codec$encode_message(reset))
  shaped <- new_message(
    MessageKindSHAPED_OBJECT,
    shaped_object = list(
      shape_id = 7L,
      presence = NULL,
      has_presence = FALSE,
      values = list(new_u64(1), new_string("alice"))
    )
  )
  err <- expect_twilic_error(codec$decode_value(codec$encode_message(shaped)), ERR_UNKNOWN_REFERENCE)
  expect_equal(err$ref_kind, "shape_id")
  expect_equal(err$ref_id, 7)
})
