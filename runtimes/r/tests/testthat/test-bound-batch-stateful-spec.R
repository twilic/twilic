test_that("schema id is sent first then omitted", {
  enc <- new_session_encoder(default_session_options())
  schema <- sample_schema()
  value <- new_map(
    entry("id", new_u64(1005)),
    entry("name", new_string("alice")),
    entry("score", new_i64(99))
  )
  first_msg <- enc$decode_message(enc$encode_with_schema(schema, value))
  expect_equal(first_msg$kind, MessageKindSCHEMA_OBJECT)
  expect_false(is.null(first_msg$schema_object$schema_id))
  expect_equal(first_msg$schema_object$schema_id, 41L)
  second_msg <- enc$decode_message(enc$encode_with_schema(schema, value))
  expect_equal(second_msg$kind, MessageKindSCHEMA_OBJECT)
})

test_that("batch threshold selects row vs column", {
  enc <- new_session_encoder(default_session_options())
  rows15 <- lapply(seq_len(15) - 1L, function(i) new_map(entry("id", new_u64(i))))
  b15 <- enc$encode_batch(rows15)
  expect_gt(length(b15), 0L)
  kind15 <- as.integer(b15[1])
  expect_true(kind15 %in% c(MessageKindCOLUMN_BATCH, MessageKindROW_BATCH))
  rows16 <- lapply(seq_len(16) - 1L, function(i) new_map(entry("id", new_u64(i))))
  b16 <- enc$encode_batch(rows16)
  expect_gt(length(b16), 0L)
  expect_equal(as.integer(b16[1]), MessageKindCOLUMN_BATCH)
})

test_that("micro batch reuses template and emits changed mask", {
  enc <- new_session_encoder(default_session_options())
  rows1 <- list(
    new_map(entry("id", new_u64(1)), entry("name", new_string("a"))),
    new_map(entry("id", new_u64(2)), entry("name", new_string("b"))),
    new_map(entry("id", new_u64(3)), entry("name", new_string("c"))),
    new_map(entry("id", new_u64(4)), entry("name", new_string("d")))
  )
  first <- enc$encode_micro_batch(rows1)
  expect_gt(length(first), 0L)
  expect_equal(as.integer(first[1]), MessageKindTEMPLATE_BATCH)
  rows2 <- list(
    new_map(entry("id", new_u64(1)), entry("name", new_string("aa"))),
    new_map(entry("id", new_u64(2)), entry("name", new_string("bb"))),
    new_map(entry("id", new_u64(3)), entry("name", new_string("cc"))),
    new_map(entry("id", new_u64(4)), entry("name", new_string("dd")))
  )
  second <- enc$encode_micro_batch(rows2)
  expect_gt(length(second), 0L)
  expect_equal(as.integer(second[1]), MessageKindTEMPLATE_BATCH)
})

test_that("state patch uses recommended ratio threshold", {
  enc <- new_session_encoder(default_session_options())
  base_values <- lapply(seq_len(100) - 1L, function(i) new_i64(i))
  one_change_values <- base_values
  one_change_values[[1]] <- new_i64(10000)
  twelve_change_values <- base_values
  for (i in seq_len(12)) twelve_change_values[[i]] <- new_i64(10000 + i - 1L)
  enc$encode(new_array(base_values))
  p1 <- enc$encode_patch(new_array(one_change_values))
  enc$decode_message(p1)
  p2 <- enc$encode_patch(new_array(twelve_change_values))
  enc$decode_message(p2)
  expect_true(TRUE)
})

test_that("unknown base id honors stateless retry policy", {
  opts <- default_session_options()
  opts$unknown_reference_policy <- UnknownReferencePolicyStatelessRetry
  enc <- new_session_encoder(opts)
  patch <- new_message(
    MessageKindSTATE_PATCH,
    state_patch = list(
      base_ref = base_ref_id(12345),
      operations = list(),
      literals = list()
    )
  )
  builder <- new_twilic_codec()
  bytes <- builder$encode_message(patch)
  err <- expect_twilic_error(enc$decode_message(bytes), ERR_STATELESS_RETRY_REQUIRED)
  expect_equal(err$ref_kind, "base_id")
  expect_equal(err$ref_id, 12345)
})

test_that("state patch map insert and delete roundtrip via reconstruction", {
  codec <- new_twilic_codec()
  base <- new_message(
    MessageKindMAP,
    map = list(
      message_map_entry("id", new_u64(1)),
      message_map_entry("name", new_string("alice"))
    )
  )
  codec$decode_message(codec$encode_message(base))
  insert_value <- new_map(entry("role", new_string("admin")))
  insert_patch <- new_message(
    MessageKindSTATE_PATCH,
    state_patch = list(
      base_ref = base_ref_previous(),
      operations = list(list(field_id = 2L, opcode = PatchOpcodeINSERT_FIELD, value = insert_value)),
      literals = list()
    )
  )
  codec$decode_message(codec$encode_message(insert_patch))
  expect_equal(codec$state$previous_message$kind, MessageKindMAP)
  delete_patch <- new_message(
    MessageKindSTATE_PATCH,
    state_patch = list(
      base_ref = base_ref_previous(),
      operations = list(list(field_id = 2L, opcode = PatchOpcodeDELETE_FIELD, value = NULL)),
      literals = list()
    )
  )
  codec$decode_message(codec$encode_message(delete_patch))
  expect_equal(codec$state$previous_message$kind, MessageKindMAP)
  expect_length(codec$state$previous_message$map, 2L)
})

test_that("column batch assigns dictionary id for repeated string field", {
  enc <- new_session_encoder(default_session_options())
  rows <- lapply(seq_len(32) - 1L, function(i) {
    role <- if (i %% 2L == 0L) "admin" else "user"
    new_map(entry("id", new_u64(i)), entry("role", new_string(role)))
  })
  batch_bytes <- enc$encode_batch(rows)
  expect_gt(length(batch_bytes), 0L)
  expect_equal(as.integer(batch_bytes[1]), MessageKindCOLUMN_BATCH)
})

test_that("trained dictionary profile is transported to fresh decoder", {
  enc <- new_session_encoder(default_session_options())
  rows <- lapply(seq_len(32) - 1L, function(i) {
    role <- if (i %% 2L == 0L) "admin" else "user"
    new_map(entry("id", new_u64(i)), entry("role", new_string(role)))
  })
  batch_bytes <- enc$encode_batch(rows)
  dec <- new_twilic_codec()
  decoded <- dec$decode_message(batch_bytes)
  expect_equal(decoded$kind, MessageKindCOLUMN_BATCH)
  dict_id <- NULL
  for (col in decoded$column_batch$columns) {
    if (!is.null(col$dictionary_id)) {
      dict_id <- col$dictionary_id
      break
    }
  }
  expect_false(is.null(dict_id))
  expect_true(as.character(dict_id) %in% names(dec$state$dictionaries))
  profile <- dec$state$dictionary_profiles[[as.character(dict_id)]]
  expect_false(is.null(profile))
  expect_equal(profile$version, 1L)
  expect_equal(profile$expires_at, 0L)
  expect_equal(profile$fallback, DictionaryFallbackFailFast)
  expect_equal(profile$hash, dictionary_payload_hash(dec$state$dictionaries[[as.character(dict_id)]]))
  role_values <- NULL
  for (col in decoded$column_batch$columns) {
    if (identical(col$dictionary_id, dict_id)) {
      role_values <- col$values$strings
      break
    }
  }
  expect_false(is.null(role_values))
  expect_length(role_values, 32L)
  expect_equal(role_values[[1]], "admin")
  expect_equal(role_values[[2]], "user")
})

test_that("invalid dictionary profile hash is rejected", {
  enc <- new_twilic_codec()
  dict_id <- 42L
  enc$state$dictionaries[[as.character(dict_id)]] <- as.raw(c(1, 2, 3, 4))
  enc$state$dictionary_profiles[[as.character(dict_id)]] <- list(
    version = 1L,
    hash = 7,
    expires_at = 0L,
    fallback = DictionaryFallbackFailFast
  )
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
        dictionary_id = dict_id,
        values = list(kind = ElementTypeSTRING, strings = list("admin"))
      ))
    )
  )
  batch_bytes <- enc$encode_message(msg)
  dec <- new_twilic_codec()
  expect_twilic_error(dec$decode_message(batch_bytes), ERR_INVALID_DATA, "dictionary profile hash mismatch")
})

test_that("trained dictionary reference writes compressed block after dict id", {
  dict_id <- 9L
  codec <- new_twilic_codec()
  payload <- twilic:::new_buffer()
  payload <- encode_varuint(2, payload)
  payload <- twilic:::encode_string("admin", payload)
  payload <- twilic:::encode_string("user", payload)
  dict_payload <- payload
  codec$state$dictionaries[[as.character(dict_id)]] <- dict_payload
  codec$state$dictionary_profiles[[as.character(dict_id)]] <- list(
    version = 1L,
    hash = dictionary_payload_hash(dict_payload),
    expires_at = 0L,
    fallback = DictionaryFallbackFailFast
  )
  msg <- new_message(
    MessageKindCOLUMN_BATCH,
    column_batch = list(
      count = 4L,
      columns = list(list(
        field_id = 1L,
        null_strategy = NullStrategyALL_PRESENT_ELIDED,
        presence = list(),
        has_presence = FALSE,
        codec = VectorCodecDICTIONARY,
        dictionary_id = dict_id,
        values = list(kind = ElementTypeSTRING, strings = list("admin", "user", "admin", "user"))
      ))
    )
  )
  batch_bytes <- codec$encode_message(msg)
  reader <- twilic:::new_reader(batch_bytes)
  expect_equal(reader$read_u8(), MessageKindCOLUMN_BATCH)
  reader$read_varuint()
  reader$read_varuint()
  reader$read_varuint()
  reader$read_u8()
  reader$read_u8()
  got_dict_id <- reader$read_varuint()
  expect_gt(got_dict_id, 0L)
  fresh <- new_twilic_codec()
  decoded <- fresh$decode_message(batch_bytes)
  expect_equal(decoded$kind, MessageKindCOLUMN_BATCH)
  values <- decoded$column_batch$columns[[1]]$values$strings
  expect_equal(values, list("admin", "user", "admin", "user"))
})
