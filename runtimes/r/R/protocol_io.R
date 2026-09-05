# Protocol read/write (ported from twilic-python protocol.py)

twilic_message_for_value <- function(codec, value) {
  if (value$kind == ValueKindARRAY) {
    tv <- twilic_try_make_typed_vector(value$arr)
    if (tv[[2]]) return(new_message(MessageKindTYPED_VECTOR, typed_vector = tv[[1]]))
    return(new_message(MessageKindARRAY, array = lapply(value$arr, value_clone)))
  }
  if (value$kind == ValueKindMAP) {
    keys <- vapply(value$map, function(e) e$key, character(1))
    sk <- shape_key(keys)
    had <- !is.null(codec$state$encode_shape_observations[[sk]])
    obs <- twilic_observe_encode_shape_candidate(codec, keys)
    got <- shape_table_get_id(codec$state$shape_table, keys)
    if (got[[2]] && (!had || obs >= 2L)) return(twilic_shaped_message(codec, got[[1]], value$map))
    return(twilic_map_message(codec, value$map))
  }
  new_message(MessageKindSCALAR, scalar = value_clone(value))
}

twilic_map_message <- function(codec, entries) {
  out <- list()
  for (e in entries) {
    key <- e$key
    got <- intern_table_get_id(codec$state$key_table, key)
    key_ref <- if (got[[2]]) key_ref_id(got[[1]]) else {
      intern_table_register(codec$state$key_table, key)
      key_ref_literal(key)
    }
    out[[length(out) + 1L]] <- list(key = key_ref, value = value_clone(e$value))
  }
  new_message(MessageKindMAP, map = out)
}

twilic_shaped_message <- function(codec, shape_id, entries) {
  got <- shape_table_get_keys(codec$state$shape_table, shape_id)
  keys <- got[[1]]
  index <- setNames(lapply(entries, function(e) e$value), vapply(entries, function(e) e$key, character(1)))
  values <- list()
  presence <- list()
  all_present <- TRUE
  for (key in keys) {
    v <- index[[key]]
    if (!is.null(v)) {
      presence[[length(presence) + 1L]] <- TRUE
      values[[length(values) + 1L]] <- value_clone(v)
    } else {
      presence[[length(presence) + 1L]] <- FALSE
      all_present <- FALSE
    }
  }
  so <- list(shape_id = shape_id, values = values, presence = list(), has_presence = FALSE)
  if (!all_present) {
    so$has_presence <- TRUE
    so$presence <- presence
  }
  new_message(MessageKindSHAPED_OBJECT, shaped_object = so)
}

twilic_try_make_typed_vector <- function(values) {
  if (length(values) < 4L) return(list(NULL, FALSE))
  kinds <- unique(vapply(values, function(v) v$kind, integer(1L)))
  if (length(kinds) != 1L) return(list(NULL, FALSE))
  if (kinds == ValueKindBOOL) {
    return(list(list(
      element_type = ElementTypeBOOL,
      codec = VectorCodecDIRECT_BITPACK,
      data = list(kind = ElementTypeBOOL, bools = lapply(values, function(v) v$bool))
    ), TRUE))
  }
  if (kinds == ValueKindI64) {
    vals <- vapply(values, function(v) v$i64, numeric(1))
    return(list(list(
      element_type = ElementTypeI64,
      codec = select_integer_codec(vals),
      data = list(kind = ElementTypeI64, i64s = as.list(vals))
    ), TRUE))
  }
  if (kinds == ValueKindU64) {
    vals <- vapply(values, function(v) v$u64, numeric(1))
    return(list(list(
      element_type = ElementTypeU64,
      codec = select_u64_codec(vals),
      data = list(kind = ElementTypeU64, u64s = as.list(vals))
    ), TRUE))
  }
  if (kinds == ValueKindF64) {
    vals <- vapply(values, function(v) v$f64, numeric(1))
    return(list(list(
      element_type = ElementTypeF64,
      codec = select_float_codec(vals),
      data = list(kind = ElementTypeF64, f64s = as.list(vals))
    ), TRUE))
  }
  if (kinds == ValueKindSTRING) {
    vals <- vapply(values, function(v) v$str, character(1))
    return(list(list(
      element_type = ElementTypeSTRING,
      codec = select_string_codec(vals),
      data = list(kind = ElementTypeSTRING, strings = as.list(vals))
    ), TRUE))
  }
  list(NULL, FALSE)
}

twilic_observe_encode_shape_candidate <- function(codec, keys) {
  sk <- shape_key(keys)
  obs <- codec$state$encode_shape_observations
  count <- (obs[[sk]] %||% 0L) + 1L
  obs[[sk]] <- count
  if (should_register_shape(keys, count)) {
    shape_table_register(codec$state$shape_table, keys)
  }
  count
}

best_prefix_base <- function(codec, value) {
  best_id <- 0L
  best_len <- 0L
  raw_val <- charToRaw(value)
  n <- length(codec$state$string_table$by_id)
  if (n == 0L) return(list(0L, 0L, FALSE))
  for (i in seq_len(n)) {
    candidate <- codec$state$string_table$by_id[[i]]
    prefix_len <- common_prefix_len(raw_val, charToRaw(candidate))
    if (prefix_len > best_len) {
      best_len <- prefix_len
      best_id <- i - 1L
    }
  }
  if (best_len == 0L) return(list(0L, 0L, FALSE))
  list(best_id, best_len, TRUE)
}

twilic_write_message <- function(codec, message, out) {
  if (message$kind == MessageKindSCALAR) {
    out <- raw_append_byte(out, MessageKindSCALAR)
    return(twilic_write_value(codec, message$scalar, out))
  }
  if (message$kind == MessageKindARRAY) {
    out <- raw_append_byte(out, MessageKindARRAY)
    out <- encode_varuint(length(message$array), out)
    for (v in message$array) out <- twilic_write_value(codec, v, out)
    return(out)
  }
  if (message$kind == MessageKindMAP) {
    out <- raw_append_byte(out, MessageKindMAP)
    out <- encode_varuint(length(message$map), out)
    for (e in message$map) {
      out <- twilic_write_key_ref(codec, e$key, out)
      field_id <- key_ref_field_identity(e$key, codec$state)
      out <- twilic_write_value_with_field(codec, e$value, field_id, out)
    }
    return(out)
  }
  if (message$kind == MessageKindTYPED_VECTOR) {
    out <- raw_append_byte(out, MessageKindTYPED_VECTOR)
    return(twilic_write_typed_vector(codec, message$typed_vector, out))
  }
  if (message$kind == MessageKindSHAPED_OBJECT) {
    out <- raw_append_byte(out, MessageKindSHAPED_OBJECT)
    so <- message$shaped_object
    out <- encode_varuint(so$shape_id, out)
    out <- twilic_write_presence(codec, so$presence, so$has_presence %||% FALSE, out)
    out <- encode_varuint(length(so$values), out)
    got <- shape_table_get_keys(codec$state$shape_table, so$shape_id)
    if (got[[2]]) {
      keys <- got[[1]]
      pres <- so$presence
      if (!isTRUE(so$has_presence)) pres <- rep(TRUE, length(keys))
      v_idx <- 1L
      for (i in seq_along(keys)) {
        if (i <= length(pres) && !isTRUE(pres[[i]])) next
        if (v_idx > length(so$values)) break
        out <- twilic_write_value_with_field(codec, so$values[[v_idx]], keys[[i]], out)
        v_idx <- v_idx + 1L
      }
      while (v_idx <= length(so$values)) {
        out <- twilic_write_value(codec, so$values[[v_idx]], out)
        v_idx <- v_idx + 1L
      }
    } else {
      for (v in so$values) out <- twilic_write_value(codec, v, out)
    }
    return(out)
  }
  if (message$kind == MessageKindSCHEMA_OBJECT) {
    out <- raw_append_byte(out, MessageKindSCHEMA_OBJECT)
    so <- message$schema_object
    if (!is.null(so$schema_id)) {
      out <- raw_append_byte(out, 1L)
      out <- encode_varuint(so$schema_id, out)
    } else {
      out <- raw_append_byte(out, 0L)
    }
    out <- twilic_write_presence(codec, so$presence, so$has_presence %||% FALSE, out)
    out <- encode_varuint(length(so$fields), out)
    schema <- NULL
    if (!is.null(so$schema_id)) schema <- codec$state$schemas[[as.character(so$schema_id)]]
    else if (!is.null(codec$state$last_schema_id)) {
      schema <- codec$state$schemas[[as.character(codec$state$last_schema_id)]]
    }
    if (!is.null(schema)) {
      out <- raw_append_byte(out, 1L)
      out <- twilic_write_schema_fields(codec, schema, so$presence, so$has_presence %||% FALSE, so$fields, out)
      if (!is.null(so$schema_id)) codec$state$last_schema_id <- so$schema_id
    } else {
      out <- raw_append_byte(out, 0L)
      for (v in so$fields) out <- twilic_write_value(codec, v, out)
    }
    return(out)
  }
  if (message$kind == MessageKindROW_BATCH) {
    out <- raw_append_byte(out, MessageKindROW_BATCH)
    rb <- message$row_batch
    out <- encode_varuint(length(rb$rows), out)
    for (row in rb$rows) {
      out <- encode_varuint(length(row), out)
      for (v in row) out <- twilic_write_value(codec, v, out)
    }
    return(out)
  }
  if (message$kind == MessageKindCOLUMN_BATCH) {
    out <- raw_append_byte(out, MessageKindCOLUMN_BATCH)
    cb <- message$column_batch
    out <- encode_varuint(cb$count, out)
    out <- encode_varuint(length(cb$columns), out)
    for (col in cb$columns) out <- twilic_write_column(codec, col, out)
    return(out)
  }
  if (message$kind == MessageKindCONTROL) {
    out <- raw_append_byte(out, MessageKindCONTROL)
    return(twilic_write_control(codec, message$control, out))
  }
  if (message$kind == MessageKindEXT) {
    out <- raw_append_byte(out, MessageKindEXT)
    ext <- message$ext
    out <- encode_varuint(ext$ext_type, out)
    return(encode_bytes(ext$payload, out))
  }
  if (message$kind == MessageKindSTATE_PATCH) {
    out <- raw_append_byte(out, MessageKindSTATE_PATCH)
    sp <- message$state_patch
    out <- twilic_write_base_ref(codec, sp$base_ref, out)
    out <- encode_varuint(length(sp$operations), out)
    for (op in sp$operations) {
      out <- encode_varuint(op$field_id, out)
      out <- raw_append_byte(out, op$opcode)
      if (!is.null(op$value)) {
        out <- raw_append_byte(out, 1L)
        out <- twilic_write_value(codec, op$value, out)
      } else {
        out <- raw_append_byte(out, 0L)
      }
    }
    out <- encode_varuint(length(sp$literals %||% list()), out)
    for (lit in sp$literals %||% list()) out <- twilic_write_value(codec, lit, out)
    return(out)
  }
  if (message$kind == MessageKindTEMPLATE_BATCH) {
    out <- raw_append_byte(out, MessageKindTEMPLATE_BATCH)
    tb <- message$template_batch
    out <- encode_varuint(tb$template_id, out)
    out <- encode_varuint(tb$count, out)
    out <- encode_bitmap(tb$changed_column_mask, out)
    out <- encode_varuint(length(tb$columns), out)
    for (col in tb$columns) out <- twilic_write_column(codec, col, out)
    return(out)
  }
  if (message$kind == MessageKindCONTROL_STREAM) {
    out <- raw_append_byte(out, MessageKindCONTROL_STREAM)
    cs <- message$control_stream
    out <- raw_append_byte(out, cs$codec)
    return(twilic_write_control_stream_payload(codec, cs$codec, cs$payload, out))
  }
  if (message$kind == MessageKindBASE_SNAPSHOT) {
    bs <- message$base_snapshot
    out <- raw_append_byte(out, MessageKindBASE_SNAPSHOT)
    out <- encode_varuint(bs$base_id, out)
    out <- encode_varuint(bs$schema_or_shape_ref, out)
    return(twilic_write_message(codec, bs$payload, out))
  }
  twilic_stop(invalid_data(sprintf("write_message unsupported kind %s", message$kind)))
}

twilic_read_message <- function(codec, reader) {
  reader$enter_depth()
  on.exit(reader$leave_depth(), add = TRUE)
  kind_byte <- reader$read_u8()
  got <- message_kind_from_byte(kind_byte)
  if (!got[[2]]) twilic_stop(invalid_kind(kind_byte))
  kind <- got[[1]]
  if (kind == MessageKindSCALAR) {
    return(new_message(MessageKindSCALAR, scalar = twilic_read_value(codec, reader)))
  }
  if (kind == MessageKindARRAY) {
    n <- reader$read_count()
    arr <- vector("list", n)
    for (i in seq_len(n)) arr[[i]] <- twilic_read_value(codec, reader)
    return(new_message(MessageKindARRAY, array = arr))
  }
  if (kind == MessageKindMAP) {
    n <- reader$read_count()
    mp <- vector("list", n)
    keys <- character(n)
    for (i in seq_len(n)) {
      kr <- twilic_read_key_ref(codec, reader)
      field_id <- key_ref_field_identity(kr, codec$state)
      v <- twilic_read_value_with_field(codec, reader, field_id)
      mp[[i]] <- list(key = kr, value = v)
      keys[[i]] <- key_ref_string(kr, codec$state)
    }
    twilic_observe_decode_shape_candidate(codec, keys)
    return(new_message(MessageKindMAP, map = mp))
  }
  if (kind == MessageKindSHAPED_OBJECT) {
    shape_id <- reader$read_count(65535)
    pres <- twilic_read_presence(codec, reader)
    presence <- pres[[1]]
    has_presence <- pres[[2]]
    n <- reader$read_count()
    values <- list()
    got <- shape_table_get_keys(codec$state$shape_table, shape_id)
    if (got[[2]]) {
      keys <- got[[1]]
      pres_bits <- if (isTRUE(has_presence)) presence else rep(TRUE, length(keys))
      read_count <- 0L
      for (i in seq_along(keys)) {
        if (i <= length(pres_bits) && !isTRUE(pres_bits[[i]])) next
        if (read_count >= n) break
        values[[length(values) + 1L]] <- twilic_read_value_with_field(codec, reader, keys[[i]])
        read_count <- read_count + 1L
      }
      while (read_count < n) {
        values[[length(values) + 1L]] <- twilic_read_value(codec, reader)
        read_count <- read_count + 1L
      }
    } else {
      for (i in seq_len(n)) values[[i]] <- twilic_read_value(codec, reader)
    }
    return(new_message(MessageKindSHAPED_OBJECT, shaped_object = list(
      shape_id = shape_id, presence = presence, has_presence = has_presence, values = values
    )))
  }
  if (kind == MessageKindSCHEMA_OBJECT) {
    has_schema <- reader$read_u8()
    schema_id <- if (has_schema == 1L) reader$read_varuint() else NULL
    pres <- twilic_read_presence(codec, reader)
    presence <- pres[[1]]
    has_presence <- pres[[2]]
    n <- reader$read_count()
    mode <- reader$read_u8()
    fields <- list()
    if (mode == 1L) {
      effective_id <- schema_id %||% codec$state$last_schema_id
      if (is.null(effective_id)) {
        twilic_stop(invalid_data("schema object requires schema id in context"))
      }
      schema <- codec$state$schemas[[as.character(effective_id)]]
      if (is.null(schema)) twilic_reference_error(codec, "schema_id", effective_id)
      fields <- twilic_read_schema_fields(codec, schema, presence, has_presence, n, reader)
      codec$state$last_schema_id <- effective_id
    } else {
      for (i in seq_len(n)) fields[[i]] <- twilic_read_value(codec, reader)
      if (!is.null(schema_id)) codec$state$last_schema_id <- schema_id
    }
    return(new_message(MessageKindSCHEMA_OBJECT, schema_object = list(
      schema_id = schema_id, presence = presence, has_presence = has_presence, fields = fields
    )))
  }
  if (kind == MessageKindTYPED_VECTOR) {
    return(new_message(
      MessageKindTYPED_VECTOR,
      typed_vector = twilic_read_typed_vector(codec, reader, NULL, NULL)
    ))
  }
  if (kind == MessageKindROW_BATCH) {
    row_count <- reader$read_count()
    rows <- vector("list", row_count)
    for (r in seq_len(row_count)) {
      field_count <- reader$read_count()
      row <- vector("list", field_count)
      for (i in seq_len(field_count)) row[[i]] <- twilic_read_value(codec, reader)
      rows[[r]] <- row
    }
    return(new_message(MessageKindROW_BATCH, row_batch = list(rows = rows)))
  }
  if (kind == MessageKindCOLUMN_BATCH) {
    count <- reader$read_count()
    col_count <- reader$read_count()
    cols <- vector("list", col_count)
    for (i in seq_len(col_count)) cols[[i]] <- twilic_read_column(codec, reader)
    return(new_message(MessageKindCOLUMN_BATCH, column_batch = list(count = count, columns = cols)))
  }
  if (kind == MessageKindCONTROL) {
    return(new_message(MessageKindCONTROL, control = twilic_read_control(codec, reader)))
  }
  if (kind == MessageKindEXT) {
    ext_type <- reader$read_varuint()
    payload <- reader$read_bytes()
    return(new_message(MessageKindEXT, ext = list(ext_type = ext_type, payload = payload)))
  }
  if (kind == MessageKindSTATE_PATCH) {
    base_ref <- twilic_read_base_ref(codec, reader)
    op_n <- reader$read_count()
    ops <- vector("list", op_n)
    for (i in seq_len(op_n)) {
      field_id <- reader$read_varuint()
      op_byte <- reader$read_u8()
      pok <- patch_opcode_from_byte(op_byte)
      if (!pok[[2]]) twilic_stop(invalid_data("patch opcode"))
      has_value <- reader$read_u8()
      value <- if (has_value == 1L) twilic_read_value(codec, reader) else NULL
      ops[[i]] <- list(field_id = field_id, opcode = pok[[1]], value = value)
    }
    lit_n <- reader$read_count()
    lits <- vector("list", lit_n)
    for (i in seq_len(lit_n)) lits[[i]] <- twilic_read_value(codec, reader)
    return(new_message(MessageKindSTATE_PATCH, state_patch = list(
      base_ref = base_ref, operations = ops, literals = lits
    )))
  }
  if (kind == MessageKindTEMPLATE_BATCH) {
    template_id <- reader$read_varuint()
    count <- reader$read_count()
    mask <- reader$read_bitmap()
    col_n <- reader$read_count()
    changed_cols <- vector("list", col_n)
    for (i in seq_len(col_n)) changed_cols[[i]] <- twilic_read_column(codec, reader)
    full_cols <- changed_cols
    prev <- codec$state$template_columns[[as.character(template_id)]]
    if (!is.null(prev)) {
      full_cols <- merge_template_columns(prev, mask, changed_cols)
    } else {
      for (i in seq_along(mask)) {
        if (!isTRUE(mask[[i]])) twilic_reference_error(codec, "template_id", template_id)
      }
    }
    codec$state$template_columns[[as.character(template_id)]] <- full_cols
    codec$state$templates[[as.character(template_id)]] <- template_descriptor_from_columns(template_id, full_cols)
    if (count >= 16L) {
      codec$state$previous_message <- new_message(
        MessageKindCOLUMN_BATCH,
        column_batch = list(count = count, columns = full_cols)
      )
    }
    return(new_message(MessageKindTEMPLATE_BATCH, template_batch = list(
      template_id = template_id, count = count,
      changed_column_mask = mask, columns = changed_cols
    )))
  }
  if (kind == MessageKindCONTROL_STREAM) {
    codec_byte <- reader$read_u8()
    cs_got <- control_stream_codec_from_byte(codec_byte)
    if (!cs_got[[2]]) twilic_stop(invalid_data("control stream codec"))
    payload <- twilic_read_control_stream_payload(codec, cs_got[[1]], reader)
    return(new_message(MessageKindCONTROL_STREAM, control_stream = list(
      codec = cs_got[[1]], payload = payload
    )))
  }
  if (kind == MessageKindBASE_SNAPSHOT) {
    base_id <- reader$read_varuint()
    schema_or_shape_ref <- reader$read_varuint()
    payload <- twilic_read_message(codec, reader)
    register_base_snapshot(codec$state, base_id, payload)
    return(new_message(MessageKindBASE_SNAPSHOT, base_snapshot = list(
      base_id = base_id, schema_or_shape_ref = schema_or_shape_ref, payload = payload
    )))
  }
  twilic_stop(invalid_data(sprintf("unsupported message kind %s", kind)))
}

twilic_update_state_after_decode <- function(codec, msg, size) {
  if (msg$kind == MessageKindCONTROL) return(invisible(NULL))
  if (msg$kind == MessageKindSTATE_PATCH) {
    sp <- msg$state_patch
    tryCatch(
      {
        reconstructed <- apply_state_patch(codec$state, sp$base_ref, sp$operations, sp$literals)
        codec$state$previous_message <- reconstructed
        codec$state$previous_message_size <- size
      },
      error = function(e) {
        if (is_twilic_error(e) && (is_unknown_reference(e) || is_stateless_retry(e))) twilic_stop(e)
      }
    )
    return(invisible(NULL))
  }
  if (msg$kind == MessageKindTEMPLATE_BATCH) {
    if (is.null(codec$state$previous_message)) {
      codec$state$previous_message <- message_clone(msg)
      codec$state$previous_message_size <- size
    }
    return(invisible(NULL))
  }
  codec$state$previous_message <- message_clone(msg)
  codec$state$previous_message_size <- size
  invisible(NULL)
}

twilic_write_value <- function(codec, value, out) {
  twilic_write_value_with_field(codec, value, NULL, out)
}

twilic_write_value_with_field <- function(codec, value, field_identity, out) {
  if (value$kind == ValueKindNULL) return(raw_append_byte(out, TAG_NULL))
  if (value$kind == ValueKindBOOL) {
    return(raw_append_byte(out, if (isTRUE(value$bool)) TAG_BOOL_TRUE else TAG_BOOL_FALSE))
  }
  if (value$kind == ValueKindI64) {
    out <- raw_append_byte(out, TAG_I64)
    return(write_smallest_u64(encode_zigzag(value$i64), out))
  }
  if (value$kind == ValueKindU64) {
    out <- raw_append_byte(out, TAG_U64)
    return(write_smallest_u64(value$u64, out))
  }
  if (value$kind == ValueKindF64) {
    out <- raw_append_byte(out, TAG_F64)
    return(append_f64_le(out, value$f64))
  }
  if (value$kind == ValueKindSTRING) {
    out <- raw_append_byte(out, TAG_STRING)
    if (value$str == "") {
      out <- raw_append_byte(out, StringModeEMPTY)
      return(out)
    }
    got <- intern_table_get_id(codec$state$string_table, value$str)
    if (got[[2]]) {
      out <- raw_append_byte(out, StringModeREF)
      return(encode_varuint(got[[1]], out))
    }
    bp <- best_prefix_base(codec, value$str)
    if (isTRUE(bp[[3]]) && bp[[2]] >= 4L && bp[[2]] < nchar(value$str)) {
      out <- raw_append_byte(out, StringModePREFIX_DELTA)
      out <- encode_varuint(bp[[1]], out)
      out <- encode_varuint(bp[[2]], out)
      suffix <- substr(value$str, bp[[2]] + 1L, nchar(value$str))
      out <- encode_string(suffix, out)
      intern_table_register(codec$state$string_table, value$str)
      return(out)
    }
    out <- raw_append_byte(out, StringModeLITERAL)
    out <- encode_string(value$str, out)
    intern_table_register(codec$state$string_table, value$str)
    return(out)
  }
  if (value$kind == ValueKindBINARY) {
    out <- raw_append_byte(out, TAG_BINARY)
    return(encode_bytes(value$bin, out))
  }
  if (value$kind == ValueKindARRAY) {
    out <- raw_append_byte(out, TAG_ARRAY)
    out <- encode_varuint(length(value$arr), out)
    for (v in value$arr) out <- twilic_write_value(codec, v, out)
    return(out)
  }
  if (value$kind == ValueKindMAP) {
    out <- raw_append_byte(out, TAG_MAP)
    out <- encode_varuint(length(value$map), out)
    for (e in value$map) {
      out <- twilic_write_key_ref(codec, key_ref_literal(e$key), out)
      out <- twilic_write_value_with_field(codec, e$value, e$key, out)
    }
    return(out)
  }
  twilic_stop(invalid_data("unsupported value kind"))
}

twilic_read_value <- function(codec, reader) {
  twilic_read_value_with_field(codec, reader, NULL)
}

twilic_read_value_with_field <- function(codec, reader, field_identity) {
  reader$enter_depth()
  on.exit(reader$leave_depth(), add = TRUE)
  tag <- reader$read_u8()
  if (tag == TAG_NULL) return(new_null())
  if (tag == TAG_BOOL_FALSE) return(new_bool(FALSE))
  if (tag == TAG_BOOL_TRUE) return(new_bool(TRUE))
  if (tag == TAG_I64) return(new_i64(decode_zigzag(read_smallest_u64(reader))))
  if (tag == TAG_U64) return(new_u64(read_smallest_u64(reader)))
  if (tag == TAG_F64) return(new_f64(read_f64_le(reader)))
  if (tag == TAG_STRING) {
    mode_byte <- reader$read_u8()
    got <- string_mode_from_byte(mode_byte)
    if (!got[[2]]) twilic_stop(invalid_data("string mode"))
    mode <- got[[1]]
    if (mode == StringModeEMPTY) return(new_string(""))
    if (mode == StringModeLITERAL) {
      s <- reader$read_string()
      intern_table_register(codec$state$string_table, s)
      return(new_string(s))
    }
    if (mode == StringModeREF) {
      ref_id <- reader$read_varuint()
      got <- intern_table_get_value(codec$state$string_table, ref_id)
      if (!got[[2]]) twilic_reference_error(codec, "string_id", ref_id)
      return(new_string(got[[1]]))
    }
    if (mode == StringModePREFIX_DELTA) {
      base_id <- reader$read_varuint()
      prefix_len <- reader$read_count()
      suffix <- reader$read_string()
      got <- intern_table_get_value(codec$state$string_table, base_id)
      if (!got[[2]]) twilic_reference_error(codec, "string_id", base_id)
      base_raw <- charToRaw(got[[1]])
      if (prefix_len > length(base_raw)) twilic_stop(invalid_data("prefix delta length"))
      s <- rawToChar(c(base_raw[seq_len(prefix_len)], charToRaw(suffix)))
      intern_table_register(codec$state$string_table, s)
      return(new_string(s))
    }
    twilic_stop(invalid_data("string mode not ported"))
  }
  if (tag == TAG_BINARY) return(new_binary(reader$read_bytes()))
  if (tag == TAG_ARRAY) {
    n <- reader$read_count()
    arr <- vector("list", n)
    for (i in seq_len(n)) arr[[i]] <- twilic_read_value(codec, reader)
    return(new_array(arr))
  }
  if (tag == TAG_MAP) {
    n <- reader$read_count()
    entries <- vector("list", n)
    for (i in seq_len(n)) {
      kr <- twilic_read_key_ref(codec, reader)
      v <- twilic_read_value_with_field(codec, reader, kr$literal)
      entries[[i]] <- entry(kr$literal, v)
    }
    return(do.call(new_map, entries))
  }
  twilic_stop(invalid_tag(tag))
}

twilic_write_key_ref <- function(codec, key_ref, out) {
  if (isTRUE(key_ref$is_id)) {
    out <- raw_append_byte(out, 1L)
    return(encode_varuint(key_ref$id, out))
  }
  out <- raw_append_byte(out, 0L)
  out <- encode_string(key_ref$literal, out)
  intern_table_register(codec$state$key_table, key_ref$literal)
  out
}

twilic_read_key_ref <- function(codec, reader) {
  mode <- reader$read_u8()
    if (mode == 1L) {
      ref_id <- reader$read_varuint()
      got <- intern_table_get_value(codec$state$key_table, ref_id)
      if (!got[[2]]) twilic_reference_error(codec, "key_id", ref_id)
      return(key_ref_id(ref_id))
    }
  if (mode != 0L) twilic_stop(invalid_data("key ref mode"))
  s <- reader$read_string()
  intern_table_register(codec$state$key_table, s)
  key_ref_literal(s)
}

twilic_write_typed_vector <- function(codec, vector, out) {
  out <- raw_append_byte(out, vector$element_type)
  out <- encode_varuint(typed_vector_len(vector$data), out)
  out <- raw_append_byte(out, vector$codec)
  et <- vector$element_type
  d <- vector$data
  if (et == ElementTypeBOOL) {
    return(encode_bitmap(unlist(d$bools), out))
  }
  if (et == ElementTypeI64) {
    return(encode_i64_vector(unlist(d$i64s), vector$codec, out))
  }
  if (et == ElementTypeU64) {
    return(encode_u64_vector(unlist(d$u64s), vector$codec, out))
  }
  if (et == ElementTypeF64) {
    return(encode_f64_vector(unlist(d$f64s), vector$codec, out))
  }
  if (et == ElementTypeSTRING) {
    return(twilic_write_string_vector(codec, d$strings, vector$codec, out))
  }
  if (et == ElementTypeBINARY) {
    out <- encode_varuint(length(d$binary), out)
    for (b in d$binary) out <- encode_bytes(b, out)
    return(out)
  }
  if (et == ElementTypeVALUE) {
    out <- encode_varuint(length(d$values), out)
    for (v in d$values) out <- twilic_write_value(codec, v, out)
    return(out)
  }
  twilic_stop(invalid_data("typed vector element type not ported"))
}

twilic_read_typed_vector <- function(codec, reader, forced_element = NULL, expected_codec = NULL) {
  if (is.null(forced_element)) {
    et <- reader$read_u8()
    got <- element_type_from_byte(et)
    if (!got[[2]]) twilic_stop(invalid_data("element type"))
    element_type <- got[[1]]
  } else {
    element_type <- forced_element
  }
  expected_len <- reader$read_count()
  vc <- reader$read_u8()
  gotc <- vector_codec_from_byte(vc)
  if (!gotc[[2]]) twilic_stop(invalid_data("vector codec"))
  codec_enum <- gotc[[1]]
  if (!is.null(expected_codec) && codec_enum != expected_codec) {
    twilic_stop(invalid_data("column codec mismatch"))
  }
  data <- list(kind = element_type)
  if (element_type == ElementTypeBOOL) {
    data$bools <- reader$read_bitmap()
  } else if (element_type == ElementTypeI64) {
    data$i64s <- as.list(decode_i64_vector(reader, codec_enum))
  } else if (element_type == ElementTypeU64) {
    data$u64s <- as.list(decode_u64_vector(reader, codec_enum))
  } else if (element_type == ElementTypeF64) {
    data$f64s <- as.list(decode_f64_vector(reader, codec_enum))
  } else if (element_type == ElementTypeSTRING) {
    data$strings <- twilic_read_string_vector(codec, reader, codec_enum)
  } else if (element_type == ElementTypeBINARY) {
    n <- reader$read_count()
    bins <- vector("list", n)
    for (i in seq_len(n)) bins[[i]] <- reader$read_bytes()
    data$binary <- bins
  } else if (element_type == ElementTypeVALUE) {
    n <- reader$read_count()
    vals <- vector("list", n)
    for (i in seq_len(n)) vals[[i]] <- twilic_read_value(codec, reader)
    data$values <- vals
  } else {
    twilic_stop(invalid_data("typed vector read not ported"))
  }
  if (typed_vector_len(data) != expected_len) {
    twilic_stop(invalid_data("typed vector length mismatch"))
  }
  list(element_type = element_type, codec = codec_enum, data = data)
}
