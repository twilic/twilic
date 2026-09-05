# Protocol message I/O helpers (ported from twilic-ruby protocol.rb)

twilic_write_presence <- function(codec, presence, has_presence, out) {
  if (!isTRUE(has_presence)) {
    return(raw_append_byte(out, 0L))
  }
  out <- raw_append_byte(out, 1L)
  encode_bitmap(presence, out)
}

twilic_read_presence <- function(codec, reader) {
  flag <- reader$read_u8()
  if (flag == 0L) return(list(list(), FALSE))
  if (flag != 1L) twilic_stop(invalid_data("presence flag"))
  list(reader$read_bitmap(), TRUE)
}

twilic_write_string_vector <- function(codec, values, codec_id, out) {
  if (codec_id == VectorCodecDICTIONARY) {
    dct <- list()
    uniq <- list()
    refs <- integer(length(values))
    for (i in seq_along(values)) {
      v <- values[[i]]
      rid <- dct[[v]]
      if (is.null(rid)) {
        rid <- length(uniq)
        dct[[v]] <- rid
        uniq[[rid + 1L]] <- v
      }
      refs[i] <- rid
    }
    out <- encode_varuint(length(uniq), out)
    for (u in uniq) out <- encode_string(u, out)
    return(encode_u64_vector(as.list(refs), VectorCodecDIRECT_BITPACK, out))
  }
  if (codec_id == VectorCodecSTRING_REF) {
    out <- encode_varuint(length(values), out)
    for (v in values) {
      got <- intern_table_get_id(codec$state$string_table, v)
      sid <- if (got[[2]]) got[[1]] else intern_table_register(codec$state$string_table, v)
      out <- encode_varuint(sid, out)
    }
    return(out)
  }
  if (codec_id == VectorCodecPREFIX_DELTA) {
    out <- encode_varuint(length(values), out)
    prev <- ""
    for (v in values) {
      prefix <- common_prefix_len(prev, v)
      out <- encode_varuint(prefix, out)
      out <- encode_string(substr(v, prefix + 1L, nchar(v)), out)
      prev <- v
    }
    return(out)
  }
  out <- encode_varuint(length(values), out)
  for (v in values) out <- encode_string(v, out)
  out
}

twilic_read_string_vector <- function(codec, reader, codec_id) {
  if (codec_id == VectorCodecDICTIONARY) {
    dict_n <- reader$read_count()
    dict <- vector("list", dict_n)
    for (i in seq_len(dict_n)) dict[[i]] <- reader$read_string()
    refs <- decode_u64_vector(reader, VectorCodecDIRECT_BITPACK)
    out <- vector("list", length(refs))
    for (i in seq_along(refs)) {
      ref <- refs[[i]]
      if (ref >= length(dict)) twilic_stop(invalid_data("dictionary reference"))
      out[[i]] <- dict[[ref + 1L]]
    }
    return(out)
  }
  if (codec_id == VectorCodecSTRING_REF) {
    n <- reader$read_count()
    out <- vector("list", n)
    for (i in seq_len(n)) {
      ref_id <- reader$read_varuint()
      got <- intern_table_get_value(codec$state$string_table, ref_id)
      if (!got[[2]]) twilic_reference_error(codec, "string_id", ref_id)
      out[[i]] <- got[[1]]
    }
    return(out)
  }
  if (codec_id == VectorCodecPREFIX_DELTA) {
    n <- reader$read_count()
    out <- vector("list", n)
    prev <- ""
    for (i in seq_len(n)) {
      prefix <- reader$read_varuint()
      suffix <- reader$read_string()
      if (prefix > nchar(prev)) twilic_stop(invalid_data("prefix delta in string vector"))
      out[[i]] <- paste0(substr(prev, 1L, prefix), suffix)
      prev <- out[[i]]
    }
    return(out)
  }
  n <- reader$read_count()
  out <- vector("list", n)
  for (i in seq_len(n)) out[[i]] <- reader$read_string()
  out
}

twilic_write_schema_field_value <- function(codec, field, value, out) {
  lt <- normalized_logical_type(field$logical_type)
  if (lt == "bool" && value$kind != ValueKindBOOL) {
    twilic_stop(invalid_data("schema bool field type mismatch"))
  }
  if (lt %in% c("i64", "int64", "int") && value$kind != ValueKindI64) {
    twilic_stop(invalid_data("schema i64 field type mismatch"))
  }
  if (lt %in% c("u64", "uint64", "uint") && value$kind != ValueKindU64) {
    twilic_stop(invalid_data("schema u64 field type mismatch"))
  }
  if (lt %in% c("f64", "float64", "float") && value$kind != ValueKindF64) {
    twilic_stop(invalid_data("schema f64 field type mismatch"))
  }
  if (lt == "string") {
    if (value$kind != ValueKindSTRING) twilic_stop(invalid_data("schema string field type mismatch"))
    return(twilic_write_value_with_field(codec, value, field$name, out))
  }
  twilic_write_value(codec, value, out)
}

twilic_read_schema_field_value <- function(codec, field, reader) {
  if (normalized_logical_type(field$logical_type) == "string") {
    return(twilic_read_value_with_field(codec, reader, field$name))
  }
  twilic_read_value(codec, reader)
}

twilic_write_schema_fields <- function(codec, schema, presence, has_presence, fields, out) {
  indices <- schema_present_field_indices(schema, presence, has_presence)
  for (j in seq_along(indices)) {
    i <- indices[[j]]
    if (i + 1L > length(fields)) twilic_stop(invalid_data("schema fields length mismatch"))
    out <- twilic_write_schema_field_value(codec, schema$fields[[i + 1L]], fields[[i + 1L]], out)
  }
  out
}

twilic_read_schema_fields <- function(codec, schema, presence, has_presence, n, reader) {
  indices <- schema_present_field_indices(schema, presence, has_presence)
  if (length(indices) != n) twilic_stop(invalid_data("schema fields length"))
  out <- vector("list", length(schema$fields))
  for (j in seq_along(indices)) {
    i <- indices[[j]]
    out[[i + 1L]] <- twilic_read_schema_field_value(codec, schema$fields[[i + 1L]], reader)
  }
  out
}

twilic_write_column <- function(codec, column, out) {
  out <- encode_varuint(column$field_id, out)
  out <- raw_append_byte(out, column$null_strategy)
  if (column$null_strategy %in% c(NullStrategyPRESENCE_BITMAP, NullStrategyINVERTED_PRESENCE_BITMAP)) {
    if (!isTRUE(column$has_presence) || is.null(column$presence)) {
      twilic_stop(invalid_data("missing column presence bitmap"))
    }
    out <- encode_bitmap(column$presence, out)
  }
  out <- raw_append_byte(out, column$codec)
  if (!is.null(column$dictionary_id)) {
    out <- raw_append_byte(out, 1L)
    out <- encode_varuint(column$dictionary_id, out)
    payload <- codec$state$dictionaries[[as.character(column$dictionary_id)]]
    profile <- codec$state$dictionary_profiles[[as.character(column$dictionary_id)]]
    if (!is.null(payload) && !is.null(profile)) {
      out <- raw_append_byte(out, 1L)
      out <- encode_varuint(profile$version, out)
      out <- encode_varuint(profile$hash, out)
      out <- encode_varuint(profile$expires_at, out)
      out <- raw_append_byte(out, profile$fallback)
      out <- encode_bytes(payload, out)
    } else {
      out <- raw_append_byte(out, 0L)
    }
  } else {
    out <- raw_append_byte(out, 0L)
  }

  trained_block <- NULL
  if (!is.null(column$dictionary_id) && column$values$kind == ElementTypeSTRING) {
    if (column$codec %in% c(VectorCodecDICTIONARY, VectorCodecSTRING_REF)) {
      payload <- codec$state$dictionaries[[as.character(column$dictionary_id)]]
      if (!is.null(payload)) {
        dict <- tryCatch(
          decode_trained_dictionary_payload(payload),
          error = function(e) NULL
        )
        if (!is.null(dict)) {
          blk <- tryCatch(
            encode_trained_dictionary_block(column$values$strings, dict),
            error = function(e) list(NULL, FALSE, NULL)
          )
          if (!is.null(blk[[1]]) && isTRUE(blk[[2]])) trained_block <- blk[[1]]
        }
      }
    }
  }
  if (!is.null(trained_block)) {
    out <- raw_append_byte(out, 1L)
    return(encode_bytes(trained_block, out))
  }
  out <- raw_append_byte(out, 0L)
  tv <- list(
    element_type = column$values$kind,
    codec = column$codec,
    data = typed_vector_data_clone(column$values)
  )
  twilic_write_typed_vector(codec, tv, out)
}

twilic_read_column <- function(codec, reader) {
  field_id <- reader$read_varuint()
  null_byte <- reader$read_u8()
  got_ns <- null_strategy_from_byte(null_byte)
  if (!got_ns[[2]]) twilic_stop(invalid_data("null strategy"))
  null_strategy <- got_ns[[1]]
  presence <- list()
  has_presence <- FALSE
  if (null_strategy %in% c(NullStrategyPRESENCE_BITMAP, NullStrategyINVERTED_PRESENCE_BITMAP)) {
    presence <- reader$read_bitmap()
    has_presence <- TRUE
  }
  codec_byte <- reader$read_u8()
  got_c <- vector_codec_from_byte(codec_byte)
  if (!got_c[[2]]) twilic_stop(invalid_data("column codec"))
  codec_enum <- got_c[[1]]
  has_dict <- reader$read_u8()
  dictionary_id <- NULL
  if (has_dict == 1L) {
    dict_id <- reader$read_varuint()
    has_profile <- reader$read_u8()
    if (has_profile == 0L) {
      if (is.null(codec$state$dictionaries[[as.character(dict_id)]])) {
        twilic_reference_error(codec, "dict_id", dict_id)
      }
    } else if (has_profile == 1L) {
      version <- reader$read_varuint()
      hash_val <- reader$read_varuint()
      expires_at <- reader$read_varuint()
      fb <- reader$read_u8()
      got_fb <- dictionary_fallback_from_byte(fb)
      if (!got_fb[[2]]) twilic_stop(invalid_data("dictionary fallback"))
      payload <- reader$read_bytes()
      if (dictionary_payload_hash(payload) != hash_val) {
        twilic_stop(invalid_data("dictionary profile hash mismatch"))
      }
      codec$state$dictionaries[[as.character(dict_id)]] <- payload
      codec$state$dictionary_profiles[[as.character(dict_id)]] <- list(
        version = version,
        hash = hash_val,
        expires_at = expires_at,
        fallback = got_fb[[1]]
      )
    } else {
      twilic_stop(invalid_data("dictionary profile flag"))
    }
    dictionary_id <- dict_id
  } else if (has_dict != 0L) {
    twilic_stop(invalid_data("dictionary flag"))
  }
  payload_mode <- reader$read_u8()
  values <- NULL
  if (payload_mode == 0L) {
    tv <- twilic_read_typed_vector(codec, reader, NULL, codec_enum)
    values <- tv$data
  } else if (payload_mode == 1L) {
    if (is.null(dictionary_id)) twilic_stop(invalid_data("trained dictionary block requires dict_id"))
    if (!(codec_enum %in% c(VectorCodecDICTIONARY, VectorCodecSTRING_REF))) {
      twilic_stop(invalid_data("trained dictionary block requires string dictionary codec"))
    }
    dictionary_payload <- codec$state$dictionaries[[as.character(dictionary_id)]]
    if (is.null(dictionary_payload)) twilic_reference_error(codec, "dict_id", dictionary_id)
    dict <- decode_trained_dictionary_payload(dictionary_payload)
    block <- reader$read_bytes()
    strings <- decode_trained_dictionary_block(block, dict)
    values <- list(kind = ElementTypeSTRING, strings = strings)
  } else {
    twilic_stop(invalid_data("column payload mode"))
  }
  list(
    field_id = field_id,
    null_strategy = null_strategy,
    presence = presence,
    has_presence = has_presence,
    codec = codec_enum,
    dictionary_id = dictionary_id,
    values = values
  )
}

twilic_write_control <- function(codec, control, out) {
  out <- raw_append_byte(out, control$opcode)
  if (control$opcode == ControlOpcodeREGISTER_KEYS) {
    out <- encode_varuint(length(control$register_keys), out)
    for (k in control$register_keys) {
      out <- encode_string(k, out)
      intern_table_register(codec$state$key_table, k)
    }
    return(out)
  }
  if (control$opcode == ControlOpcodeREGISTER_SHAPE) {
    if (is.null(control$register_shape)) twilic_stop(invalid_data("register shape payload missing"))
    rs <- control$register_shape
    out <- encode_varuint(rs$shape_id, out)
    out <- encode_varuint(length(rs$keys), out)
    key_names <- character(length(rs$keys))
    for (i in seq_along(rs$keys)) {
      out <- twilic_write_key_ref(codec, rs$keys[[i]], out)
      key_names[[i]] <- key_ref_string(rs$keys[[i]], codec$state)
    }
    shape_register_with_id(codec$state$shape_table, rs$shape_id, key_names)
    return(out)
  }
  if (control$opcode == ControlOpcodeREGISTER_STRINGS) {
    out <- encode_varuint(length(control$register_strings), out)
    for (s in control$register_strings) {
      out <- encode_string(s, out)
      intern_table_register(codec$state$string_table, s)
    }
    return(out)
  }
  if (control$opcode == ControlOpcodePROMOTE_STRING_FIELD_TO_ENUM) {
    p <- control$promote_string_field_to_enum
    if (is.null(p)) twilic_stop(invalid_data("promote enum payload missing"))
    out <- encode_string(p$field_identity, out)
    out <- encode_varuint(length(p$values), out)
    for (v in p$values) out <- encode_string(v, out)
    codec$state$field_enums[[p$field_identity]] <- p$values
    return(out)
  }
  if (control$opcode == ControlOpcodeRESET_TABLES) {
    reset_tables(codec$state)
    return(out)
  }
  if (control$opcode == ControlOpcodeRESET_STATE) {
    reset_state(codec$state)
    return(out)
  }
  twilic_stop(invalid_data("control opcode"))
}

twilic_read_control <- function(codec, reader) {
  op_byte <- reader$read_u8()
  got <- control_opcode_from_byte(op_byte)
  if (!got[[2]]) twilic_stop(invalid_data("control opcode"))
  opcode <- got[[1]]
  msg <- list(
    opcode = opcode,
    register_keys = list(),
    register_shape = NULL,
    register_strings = list(),
    promote_string_field_to_enum = NULL,
    reset_tables = FALSE,
    reset_state = FALSE
  )
  if (opcode == ControlOpcodeREGISTER_KEYS) {
    n <- reader$read_count()
    keys <- vector("list", n)
    for (i in seq_len(n)) {
      k <- reader$read_string()
      keys[[i]] <- k
      intern_table_register(codec$state$key_table, k)
    }
    msg$register_keys <- keys
    return(msg)
  }
  if (opcode == ControlOpcodeREGISTER_SHAPE) {
    shape_id <- reader$read_count(65535)
    n <- reader$read_count()
    keys <- vector("list", n)
    key_names <- character(n)
    for (i in seq_len(n)) {
      kr <- twilic_read_key_ref(codec, reader)
      keys[[i]] <- kr
      key_names[[i]] <- key_ref_string(kr, codec$state)
    }
    shape_register_with_id(codec$state$shape_table, shape_id, key_names)
    msg$register_shape <- list(shape_id = shape_id, keys = keys)
    return(msg)
  }
  if (opcode == ControlOpcodeREGISTER_STRINGS) {
    n <- reader$read_count()
    strings <- vector("list", n)
    for (i in seq_len(n)) {
      s <- reader$read_string()
      strings[[i]] <- s
      intern_table_register(codec$state$string_table, s)
    }
    msg$register_strings <- strings
    return(msg)
  }
  if (opcode == ControlOpcodePROMOTE_STRING_FIELD_TO_ENUM) {
    field_identity <- reader$read_string()
    n <- reader$read_count()
    values <- vector("list", n)
    for (i in seq_len(n)) values[[i]] <- reader$read_string()
    codec$state$field_enums[[field_identity]] <- values
    msg$promote_string_field_to_enum <- list(field_identity = field_identity, values = values)
    return(msg)
  }
  if (opcode == ControlOpcodeRESET_TABLES) {
    msg$reset_tables <- TRUE
    reset_tables(codec$state)
    return(msg)
  }
  if (opcode == ControlOpcodeRESET_STATE) {
    msg$reset_state <- TRUE
    reset_state(codec$state)
    return(msg)
  }
  msg
}

twilic_write_base_ref <- function(codec, base_ref, out) {
  if (isTRUE(base_ref$previous)) return(raw_append_byte(out, 0L))
  out <- raw_append_byte(out, 1L)
  encode_varuint(base_ref$base_id, out)
}

twilic_read_base_ref <- function(codec, reader) {
  mode <- reader$read_u8()
  if (mode == 0L) return(base_ref_previous())
  if (mode == 1L) return(base_ref_id(reader$read_varuint()))
  twilic_stop(invalid_data("base ref"))
}

twilic_write_control_stream_payload <- function(codec, codec_id, payload, out) {
  encoded <- payload
  if (codec_id == ControlStreamCodecRLE) encoded <- rle_encode_bytes(payload)
  if (codec_id == ControlStreamCodecBITPACK) encoded <- control_bitpack_encode_bytes(payload)
  if (codec_id == ControlStreamCodecHUFFMAN) encoded <- control_huffman_encode_bytes(payload)
  if (codec_id == ControlStreamCodecFSE) encoded <- control_fse_encode_bytes(payload)
  encode_bytes(encoded, out)
}

twilic_read_control_stream_payload <- function(codec, codec_id, reader) {
  encoded <- reader$read_bytes()
  if (codec_id == ControlStreamCodecPLAIN) return(encoded)
  if (codec_id == ControlStreamCodecRLE) return(rle_decode_bytes(encoded))
  if (codec_id == ControlStreamCodecBITPACK) return(control_bitpack_decode_bytes(encoded))
  if (codec_id == ControlStreamCodecHUFFMAN) return(control_huffman_decode_bytes(encoded))
  if (codec_id == ControlStreamCodecFSE) return(control_fse_decode_bytes(encoded))
  twilic_stop(invalid_data("control stream codec"))
}

typed_vector_data_clone <- function(data) {
  unserialize(serialize(data, NULL))
}
