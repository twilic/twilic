# TwilicCodec and SessionEncoder (ported from twilic-python protocol.py)

is_session_state <- function(x) {
  (is.list(x) || is.environment(x)) && !is.null(x$key_table) && !is.null(x$options)
}

new_twilic_codec <- function(options = NULL) {
  state <- if (is_session_state(options)) {
    options
  } else if (is.null(options)) {
    new_session_state()
  } else {
    new_session_state_with_options(options)
  }
  codec <- list(state = state)
  codec$encode_message <- function(msg) twilic_codec_encode_message(codec, msg)
  codec$decode_message <- function(data) twilic_codec_decode_message(codec, data)
  codec$encode_value <- function(val) twilic_codec_encode_value(codec, val)
  codec$decode_value <- function(data) twilic_codec_decode_value(codec, data)
  codec
}

twilic_codec_with_options <- function(options) new_twilic_codec(options)

new_session_encoder <- function(options = NULL) {
  opts <- options %||% default_session_options()
  state <- new_session_state_with_options(opts)
  codec <- new_twilic_codec(state)
  enc <- list(state = state, codec = codec)
  enc$encode <- function(v) session_encoder_encode(enc, v)
  enc$encode_with_schema <- function(schema, v) session_encoder_encode_with_schema(enc, schema, v)
  enc$encode_batch <- function(vals) session_encoder_encode_batch(enc, vals)
  enc$encode_patch <- function(v) session_encoder_encode_patch(enc, v)
  enc$encode_micro_batch <- function(vals) session_encoder_encode_micro_batch(enc, vals)
  enc$decode_message <- function(data) session_encoder_decode_message(enc, data)
  enc$reset <- function() session_encoder_reset(enc)
  enc
}

reset_encode_shape_observation <- function(codec, keys) {
  codec$state$encode_shape_observations[[shape_key(keys)]] <- NULL
  invisible(NULL)
}

twilic_reference_error <- function(codec, kind, ref_id) {
  if (codec$state$options$unknown_reference_policy == UnknownReferencePolicyStatelessRetry) {
    twilic_stop(stateless_retry_required(kind, ref_id))
  }
  twilic_stop(unknown_reference(kind, ref_id))
}

twilic_codec_encode_message <- function(codec, message) {
  out <- new_buffer()
  out <- twilic_write_message(codec, message, out)
  buffer_bytes(out)
}

twilic_codec_decode_message <- function(codec, data) {
  reader <- new_reader(data)
  msg <- twilic_read_message(codec, reader)
  if (!reader$is_eof()) twilic_stop(invalid_data("trailing bytes in message"))
  size <- length(as.raw_input(data))
  twilic_update_state_after_decode(codec, msg, size)
  msg
}

twilic_codec_encode_value <- function(codec, value) {
  msg <- twilic_message_for_value(codec, value)
  out <- twilic_codec_encode_message(codec, msg)
  codec$state$previous_message <- message_clone(msg)
  codec$state$previous_message_size <- length(out)
  out
}

twilic_codec_decode_value <- function(codec, data) {
  msg <- twilic_codec_decode_message(codec, data)
  codec$state$previous_message <- message_clone(msg)
  if (msg$kind == MessageKindSCALAR) return(value_clone(msg$scalar))
  if (msg$kind == MessageKindARRAY) return(new_array(lapply(msg$array, value_clone)))
  if (msg$kind == MessageKindMAP) return(do.call(new_map, entries_to_map(msg$map, codec$state)))
  if (msg$kind == MessageKindSHAPED_OBJECT) {
    so <- msg$shaped_object
    got <- shape_table_get_keys(codec$state$shape_table, so$shape_id)
    if (!got[[2]]) twilic_reference_error(codec, "shape_id", so$shape_id)
    return(do.call(new_map, shape_values_to_map(got[[1]], so$presence, so$has_presence, so$values)))
  }
  if (msg$kind == MessageKindTYPED_VECTOR) {
    return(typed_vector_to_value(msg$typed_vector))
  }
  twilic_stop(invalid_data("decode_value expects scalar/array/map/vector message"))
}

session_encoder_encode <- function(enc, value) {
  codec <- enc$codec
  msg <- twilic_message_for_value(codec, value)
  if (isTRUE(codec$state$options$enable_state_patch) &&
      !is.null(codec$state$previous_message) &&
      supports_state_patch(codec$state$previous_message, msg)) {
    ops <- diff_message(codec$state$previous_message, msg)[[1]]
    patch_msg <- new_message(
      MessageKindSTATE_PATCH,
      state_patch = list(base_ref = base_ref_previous(), operations = ops, literals = list())
    )
    if (encoded_size(patch_msg) < encoded_size(msg)) {
      out <- tryCatch(
        twilic_codec_encode_message(codec, patch_msg),
        error = function(e) NULL
      )
      if (!is.null(out)) return(out)
    }
  }
  twilic_codec_encode_message(codec, msg)
}

session_encoder_encode_with_schema <- function(enc, schema, value) {
  codec <- enc$codec
  codec$state$schemas[[as.character(schema$schema_id)]] <- schema
  codec$state$last_schema_id <- schema$schema_id
  for (f in schema$fields) {
    if (length(f$enum_values)) codec$state$field_enums[[f$name]] <- f$enum_values
  }
  if (value$kind != ValueKindMAP) twilic_stop(invalid_data("encode_with_schema expects map value"))
  presence <- list()
  fields <- list()
  has_presence <- FALSE
  for (f in schema$fields) {
    v <- lookup_map_field(value, f$name)
    if (!is.null(v)) {
      presence[[length(presence) + 1L]] <- TRUE
      fields[[length(fields) + 1L]] <- value_clone(v)
    } else {
      presence[[length(presence) + 1L]] <- FALSE
      has_presence <- TRUE
    }
  }
  msg <- new_message(
    MessageKindSCHEMA_OBJECT,
    schema_object = list(
      schema_id = schema$schema_id,
      presence = presence,
      has_presence = has_presence,
      fields = fields
    )
  )
  twilic_codec_encode_message(codec, msg)
}

session_encoder_encode_batch <- function(enc, values) {
  codec <- enc$codec
  if (!length(values)) {
    msg <- new_message(MessageKindROW_BATCH, row_batch = list(rows = list()))
    return(twilic_codec_encode_message(codec, msg))
  }
  if (length(values) >= 16L) {
    cols <- columns_from_map_values(values)
    if (is.null(cols)) cols <- rows_to_columns(rows_from_values(values))
    if (isTRUE(codec$state$options$enable_trained_dictionary)) {
      cols <- apply_dictionary_references(codec$state, cols)
    }
    msg <- new_message(MessageKindCOLUMN_BATCH, column_batch = list(count = length(values), columns = cols))
  } else {
    msg <- new_message(MessageKindROW_BATCH, row_batch = list(rows = rows_from_values(values)))
  }
  data <- twilic_codec_encode_message(codec, msg)
  codec$state$previous_message <- message_clone(msg)
  codec$state$previous_message_size <- length(data)
  record_full_message_as_base(codec)
  data
}

session_encoder_encode_patch <- function(enc, value) {
  codec <- enc$codec
  msg <- twilic_message_for_value(codec, value)
  if (is.null(codec$state$previous_message) ||
      !supports_state_patch(codec$state$previous_message, msg)) {
    return(twilic_codec_encode_message(codec, msg))
  }
  ops <- diff_message(codec$state$previous_message, msg)[[1]]
  patch_msg <- new_message(
    MessageKindSTATE_PATCH,
    state_patch = list(base_ref = base_ref_previous(), operations = ops, literals = list())
  )
  if (encoded_size(patch_msg) >= encoded_size(msg)) return(twilic_codec_encode_message(codec, msg))
  twilic_codec_encode_message(codec, patch_msg)
}

session_encoder_encode_micro_batch <- function(enc, values) {
  codec <- enc$codec
  if (!length(values)) return(session_encoder_encode_batch(enc, values))
  if (!isTRUE(codec$state$options$enable_template_batch) ||
      !has_uniform_micro_batch_shape(values)) {
    return(session_encoder_encode_batch(enc, values))
  }
  columns <- columns_from_map_values(values)
  if (is.null(columns)) columns <- rows_to_columns(rows_from_values(values))
  if (isTRUE(codec$state$options$enable_trained_dictionary)) {
    columns <- apply_dictionary_references(codec$state, columns)
  }
  tid <- find_template_id(codec$state$templates, columns)
  if (!tid[[2]]) {
    template_id <- allocate_template_id(codec$state)
    codec$state$templates[[as.character(template_id)]] <- template_descriptor_from_columns(template_id, columns)
    codec$state$template_columns[[as.character(template_id)]] <- columns
    mask <- rep(TRUE, length(columns))
    msg <- new_message(
      MessageKindTEMPLATE_BATCH,
      template_batch = list(
        template_id = template_id, count = length(values),
        changed_column_mask = mask, columns = columns
      )
    )
    return(twilic_codec_encode_message(codec, msg))
  }
  template_id <- tid[[1]]
  merged <- diff_template_columns(codec$state$template_columns[[as.character(template_id)]], columns)
  codec$state$template_columns[[as.character(template_id)]] <- columns
  msg <- new_message(
    MessageKindTEMPLATE_BATCH,
    template_batch = list(
      template_id = template_id, count = length(values),
      changed_column_mask = merged[[1]], columns = merged[[2]]
    )
  )
  twilic_codec_encode_message(codec, msg)
}

session_encoder_decode_message <- function(enc, data) {
  twilic_codec_decode_message(enc$codec, data)
}

session_encoder_reset <- function(enc) {
  reset_state(enc$codec$state)
  invisible(NULL)
}

record_full_message_as_base <- function(codec) {
  if (codec$state$options$max_base_snapshots == 0L) return(invisible(NULL))
  if (is.null(codec$state$previous_message)) return(invisible(NULL))
  base_id <- allocate_base_id(codec$state)
  register_base_snapshot(codec$state, base_id, codec$state$previous_message)
  invisible(NULL)
}

patch_reference_error <- function(state, kind, ref_id) {
  if (state$options$unknown_reference_policy == UnknownReferencePolicyStatelessRetry) {
    twilic_stop(stateless_retry_required(kind, ref_id))
  }
  twilic_stop(unknown_reference(kind, ref_id))
}

apply_state_patch <- function(state, base_ref, operations, literals) {
  base <- if (isTRUE(base_ref$previous)) {
    if (is.null(state$previous_message)) {
      patch_reference_error(state, "previous", 0L)
    }
    message_clone(state$previous_message)
  } else {
    got <- get_base_snapshot(state, base_ref$base_id)
    if (!got[[2]]) patch_reference_error(state, "base_id", base_ref$base_id)
    got[[1]]
  }
  fields <- message_fields(base)
  for (op in operations) {
    fi <- op$field_id + 1L
    if (op$opcode == PatchOpcodeKEEP) next
    if (op$opcode %in% c(
      PatchOpcodeREPLACE_SCALAR, PatchOpcodeREPLACE_VECTOR, PatchOpcodeINSERT_FIELD,
      PatchOpcodeSTRING_REF, PatchOpcodePREFIX_DELTA
    )) {
      if (is.null(op$value)) twilic_stop(invalid_data("patch operation missing value"))
      if (fi <= length(fields)) {
        fields[[fi]] <- value_clone(op$value)
      } else if (op$field_id == length(fields)) {
        fields[[length(fields) + 1L]] <- value_clone(op$value)
      } else {
        twilic_stop(invalid_data("patch field index out of range"))
      }
    } else if (op$opcode == PatchOpcodeDELETE_FIELD) {
      if (op$field_id < 0L || fi > length(fields)) {
        twilic_stop(invalid_data("delete field index out of range"))
      }
      fields <- fields[-fi]
    } else if (op$opcode == PatchOpcodeAPPEND_VECTOR) {
      if (is.null(op$value) || op$field_id < 0L || fi > length(fields)) {
        twilic_stop(invalid_data("append vector patch invalid"))
      }
      if (fields[[fi]]$kind != ValueKindARRAY || op$value$kind != ValueKindARRAY) {
        twilic_stop(invalid_data("append vector requires arrays"))
      }
      fields[[fi]] <- new_array(c(fields[[fi]]$arr, op$value$arr))
    } else if (op$opcode == PatchOpcodeTRUNCATE_VECTOR) {
      if (is.null(op$value) || op$field_id < 0L || fi > length(fields)) {
        twilic_stop(invalid_data("truncate vector patch invalid"))
      }
      if (fields[[fi]]$kind != ValueKindARRAY || op$value$kind != ValueKindU64) {
        twilic_stop(invalid_data("truncate vector requires array and u64"))
      }
      n <- op$value$u64
      if (n < 0 || n > length(fields[[fi]]$arr)) {
        twilic_stop(invalid_data("truncate length"))
      }
      fields[[fi]] <- new_array(fields[[fi]]$arr[seq_len(n)])
    }
  }
  rebuild_message_like(base, fields)
}

twilic_observe_decode_shape_candidate <- function(codec, keys) {
  got <- shape_table_get_id(codec$state$shape_table, keys)
  if (got[[2]]) return(invisible(NULL))
  observed <- shape_table_observe(codec$state$shape_table, keys)
  if (should_register_shape(keys, observed)) shape_table_register(codec$state$shape_table, keys)
  invisible(NULL)
}
