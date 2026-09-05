# Ported from twilic-python protocol.py / twilic-ruby protocol_helpers.rb

TAG_NULL <- 0L
TAG_BOOL_FALSE <- 1L
TAG_BOOL_TRUE <- 2L
TAG_I64 <- 3L
TAG_U64 <- 4L
TAG_F64 <- 5L
TAG_STRING <- 6L
TAG_BINARY <- 7L
TAG_ARRAY <- 8L
TAG_MAP <- 9L

typed_vector_len <- function(data) {
  switch(as.integer(data$kind) + 1L,
    length(data$bools %||% list()),
    length(data$i64s %||% list()),
    length(data$u64s %||% list()),
    length(data$f64s %||% list()),
    length(data$strings %||% list()),
    length(data$binary %||% list()),
    length(data$values %||% list()),
    0L
  )
}

lookup_map_field <- function(value, key) {
  if (value$kind != ValueKindMAP) return(NULL)
  for (e in value$map) {
    if (identical(e$key, key)) return(value_clone(e$value))
  }
  NULL
}

schema_present_field_indices <- function(schema, presence, has_presence) {
  if (!isTRUE(has_presence)) return(seq_len(length(schema$fields)) - 1L)
  if (length(presence) != length(schema$fields)) {
    twilic_stop(invalid_data("presence bitmap mismatch for schema"))
  }
  which(presence) - 1L
}

normalized_logical_type <- function(raw) tolower(trimws(raw))

rows_from_values <- function(values) {
  rows <- list()
  for (v in values) {
    if (v$kind == ValueKindARRAY) {
      rows[[length(rows) + 1L]] <- lapply(v$arr, value_clone)
    } else {
      rows[[length(rows) + 1L]] <- list(value_clone(v))
    }
  }
  rows
}

column_null_strategy <- function(values, present_bits) {
  null_count <- sum(vapply(values, function(v) v$kind == ValueKindNULL, logical(1L)))
  if (null_count == 0L) return(list(NullStrategyALL_PRESENT_ELIDED, NULL, FALSE))
  if (null_count <= length(values) %/% 4L) {
    inverted <- lapply(present_bits, function(b) !isTRUE(b))
    return(list(NullStrategyINVERTED_PRESENCE_BITMAP, inverted, TRUE))
  }
  list(NullStrategyPRESENCE_BITMAP, present_bits, TRUE)
}

strip_nulls <- function(values) {
  Filter(function(v) v$kind != ValueKindNULL, values)
}

columns_from_map_values <- function(values) {
  if (!length(values)) return(NULL)
  if (any(vapply(values, function(v) v$kind != ValueKindMAP, logical(1L)))) return(NULL)
  key_order <- character()
  key_index <- list()
  column_values <- list()
  column_presence <- list()
  for (row_idx in seq_along(values)) {
    row <- values[[row_idx]]
    present <- rep(FALSE, length(key_order))
    for (e in row$map) {
      key <- e$key
      entry_value <- value_clone(e$value)
      col_idx <- key_index[[key]]
      if (is.null(col_idx)) {
        col_idx <- length(key_order)
        key_order <- c(key_order, key)
        key_index[[key]] <- col_idx
        column_values[[col_idx + 1L]] <- rep(list(new_null()), row_idx - 1L)
        column_presence[[col_idx + 1L]] <- rep(list(FALSE), row_idx - 1L)
        present <- c(present, FALSE)
      }
      column_values[[col_idx + 1L]][[length(column_values[[col_idx + 1L]]) + 1L]] <- entry_value
      column_presence[[col_idx + 1L]][[length(column_presence[[col_idx + 1L]]) + 1L]] <- TRUE
      present[[col_idx + 1L]] <- TRUE
    }
    for (col_idx in seq_along(key_order)) {
      if (!isTRUE(present[[col_idx]])) {
        column_values[[col_idx]][[length(column_values[[col_idx]]) + 1L]] <- new_null()
        column_presence[[col_idx]][[length(column_presence[[col_idx]]) + 1L]] <- FALSE
      }
    }
  }
  columns <- list()
  for (field_id in seq_along(key_order)) {
    col_values <- column_values[[field_id]]
    present_bits <- column_presence[[field_id]]
    ns <- column_null_strategy(col_values, present_bits)
    ic <- infer_column_codec_and_values(strip_nulls(col_values))
    columns[[length(columns) + 1L]] <- list(
      field_id = field_id - 1L,
      null_strategy = ns[[1]], presence = ns[[2]] %||% list(), has_presence = ns[[3]],
      codec = ic[[1]], dictionary_id = NULL, values = ic[[2]]
    )
  }
  columns
}

has_uniform_micro_batch_shape <- function(values) {
  if (!length(values) || values[[1]]$kind != ValueKindMAP) return(FALSE)
  keys <- vapply(values[[1]]$map, function(e) e$key, character(1))
  for (v in values[-1]) {
    if (v$kind != ValueKindMAP || length(v$map) != length(keys)) return(FALSE)
    for (j in seq_along(keys)) {
      if (v$map[[j]]$key != keys[[j]]) return(FALSE)
    }
  }
  TRUE
}

should_register_shape <- function(keys, observed_count) {
  length(keys) > 0L && observed_count >= 2L
}

supports_state_patch <- function(base, current) {
  if (is.null(base)) return(FALSE)
  base$kind == current$kind && base$kind %in% c(
    MessageKindMAP, MessageKindSCHEMA_OBJECT, MessageKindSHAPED_OBJECT, MessageKindARRAY
  )
}

encoded_size <- function(message) estimate_message_size(message)

typed_vector_to_value <- function(vector) {
  d <- vector$data
  switch(as.integer(vector$element_type) + 1L,
    new_array(lapply(d$bools, new_bool)),
    new_array(lapply(d$i64s, new_i64)),
    new_array(lapply(d$u64s, new_u64)),
    new_array(lapply(d$f64s, new_f64)),
    new_array(lapply(d$strings, new_string)),
    new_array(lapply(d$binary, new_binary)),
    new_array(lapply(d$values, value_clone)),
    new_array(list())
  )
}

entries_to_map <- function(entries, state) {
  out <- list()
  for (e in entries) {
    key <- key_ref_string(e$key, state)
    out[[length(out) + 1L]] <- entry(key, e$value)
    got <- intern_table_get_id(state$key_table, key)
    if (!got[[2]]) intern_table_register(state$key_table, key)
  }
  out
}

key_ref_string <- function(key, state) {
  if (isTRUE(key$is_id)) {
    got <- intern_table_get_value(state$key_table, key$id)
    if (got[[2]]) return(got[[1]])
    return("")
  }
  key$literal
}

key_ref_field_identity <- function(key, state) {
  s <- key_ref_string(key, state)
  if (!nzchar(s)) NULL else s
}

shape_values_to_map <- function(keys, presence, has_presence, values) {
  out <- list()
  idx <- 1L
  for (i in seq_along(keys)) {
    if (isTRUE(has_presence) && i <= length(presence) && !isTRUE(presence[[i]])) next
    if (idx > length(values)) break
    out[[length(out) + 1L]] <- entry(keys[[i]], values[[idx]])
    idx <- idx + 1L
  }
  out
}

rows_to_columns <- function(rows) {
  if (!length(rows)) return(list())
  width <- max(vapply(rows, length, integer(1L)))
  column_values <- vector("list", width)
  column_presence <- vector("list", width)
  for (row in rows) {
    for (col in seq_len(width)) {
      value <- if (col <= length(row)) value_clone(row[[col]]) else new_null()
      column_values[[col]] <- c(column_values[[col]], list(value))
      column_presence[[col]] <- c(column_presence[[col]], list(value$kind != ValueKindNULL))
    }
  }
  lapply(seq_len(width), function(col) {
    ns <- column_null_strategy(column_values[[col]], column_presence[[col]])
    ic <- infer_column_codec_and_values(strip_nulls(column_values[[col]]))
    list(
      field_id = col - 1L,
      null_strategy = ns[[1]], presence = ns[[2]] %||% list(), has_presence = ns[[3]],
      codec = ic[[1]], dictionary_id = NULL, values = ic[[2]]
    )
  })
}

infer_column_codec_and_values <- function(values) {
  empty_tvd <- function(kind) {
    list(kind = kind, bools = list(), i64s = list(), u64s = list(), f64s = list(),
         strings = list(), binary = list(), values = list())
  }
  if (!length(values)) return(list(VectorCodecPLAIN, empty_tvd(ElementTypeVALUE)))
  kinds <- unique(vapply(values, function(v) v$kind, integer(1L)))
  if (length(kinds) == 1L && kinds == ValueKindI64) {
    data <- vapply(values, function(v) v$i64, numeric(1))
    return(list(select_integer_codec(data), list(kind = ElementTypeI64, i64s = as.list(data),
      bools = list(), u64s = list(), f64s = list(), strings = list(), binary = list(), values = list())))
  }
  if (length(kinds) == 1L && kinds == ValueKindU64) {
    data <- vapply(values, function(v) v$u64, numeric(1))
    return(list(select_u64_codec(data), list(kind = ElementTypeU64, u64s = as.list(data),
      bools = list(), i64s = list(), f64s = list(), strings = list(), binary = list(), values = list())))
  }
  if (length(kinds) == 1L && kinds == ValueKindF64) {
    data <- vapply(values, function(v) v$f64, numeric(1))
    return(list(select_float_codec(data), list(kind = ElementTypeF64, f64s = as.list(data),
      bools = list(), i64s = list(), u64s = list(), strings = list(), binary = list(), values = list())))
  }
  if (length(kinds) == 1L && kinds == ValueKindBOOL) {
    data <- lapply(values, function(v) v$bool)
    return(list(VectorCodecDIRECT_BITPACK, list(kind = ElementTypeBOOL, bools = data,
      i64s = list(), u64s = list(), f64s = list(), strings = list(), binary = list(), values = list())))
  }
  if (length(kinds) == 1L && kinds == ValueKindSTRING) {
    data <- vapply(values, function(v) v$str, character(1))
    return(list(select_string_codec(data), list(kind = ElementTypeSTRING, strings = as.list(data),
      bools = list(), i64s = list(), u64s = list(), f64s = list(), binary = list(), values = list())))
  }
  list(VectorCodecPLAIN, list(kind = ElementTypeVALUE, values = lapply(values, value_clone),
    bools = list(), i64s = list(), u64s = list(), f64s = list(), strings = list(), binary = list()))
}

select_integer_codec <- function(values) {
  if (length(values) < 4L) return(VectorCodecPLAIN)
  delta_vals <- deltas(values)
  dd <- deltas(delta_vals)
  non_zero_dd <- sum(dd[-1] != 0)
  non_zero_ratio <- if (length(dd) > 1L) non_zero_dd / (length(dd) - 1L) else 0
  delta_range_bits <- bit_width_signed(min(delta_vals), max(delta_vals))
  if (length(values) >= 8L && (non_zero_ratio <= 0.25 || delta_range_bits <= 2L)) {
    return(VectorCodecDELTA_DELTA_BITPACK)
  }
  rs <- run_stats(values)
  if (rs[[1]] >= 0.5 && rs[[2]] >= 3) return(VectorCodecRLE)
  range_bits <- bit_width_signed(min(values), max(values))
  if (range_bits <= 60L) return(VectorCodecFOR_BITPACK)
  monotonic <- all(diff(values) >= 0)
  if (length(values) >= 8L && monotonic && delta_range_bits <= range_bits - 3L) {
    return(VectorCodecDELTA_FOR_BITPACK)
  }
  max_abs_delta_bits <- max(vapply(delta_vals, function(v) bit_width_u64(abs64(v)), integer(1L)))
  if (max_abs_delta_bits <= 61L) return(VectorCodecDELTA_BITPACK)
  max_bit_width <- max(vapply(values, function(v) bit_width_u64(abs64(v)), integer(1L)))
  if (length(values) >= 8L && max_bit_width <= 16L && !monotonic) return(VectorCodecSIMPLE8B)
  if (max_bit_width < 64L) return(VectorCodecDIRECT_BITPACK)
  VectorCodecPLAIN
}

select_u64_codec <- function(values) {
  if (all(values <= 0x7FFFFFFFFFFFFFFF)) {
    chosen <- select_integer_codec(values)
    if (chosen %in% c(VectorCodecRLE, VectorCodecFOR_BITPACK, VectorCodecSIMPLE8B,
                      VectorCodecDIRECT_BITPACK, VectorCodecPLAIN)) return(chosen)
    return(VectorCodecDIRECT_BITPACK)
  }
  if (length(values) < 4L) return(VectorCodecDIRECT_BITPACK)
  rs <- run_stats_u64(values)
  if (rs[[1]] >= 0.5 && rs[[2]] >= 3) return(VectorCodecRLE)
  if (bit_width_u64(max(values) - min(values)) <= 60L) return(VectorCodecFOR_BITPACK)
  max_width <- max(vapply(values, function(v) bit_width_u64(v), integer(1L)))
  if (length(values) >= 8L && max_width <= 16L) return(VectorCodecSIMPLE8B)
  if (max_width < 64L) return(VectorCodecDIRECT_BITPACK)
  VectorCodecPLAIN
}

f64_raw <- function(x) writeBin(as.double(x), raw(8), size = 8, endian = "little")

select_float_codec <- function(values) {
  if (length(values) < 4L) return(VectorCodecPLAIN)
  changes <- 0L
  prev <- f64_raw(values[[1]])
  for (i in 2:length(values)) {
    cur <- f64_raw(values[[i]])
    if (!identical(cur, prev)) changes <- changes + 1L
    prev <- cur
  }
  if (changes * 2L <= length(values)) VectorCodecXOR_FLOAT else VectorCodecPLAIN
}

select_string_codec <- function(values) {
  if (!length(values)) return(VectorCodecPLAIN)
  if (length(unique(values)) * 2L <= length(values)) return(VectorCodecDICTIONARY)
  prefix_gain <- 0L
  prev <- ""
  for (v in values) {
    prefix_gain <- prefix_gain + common_prefix_len(charToRaw(prev), charToRaw(v))
    prev <- v
  }
  if (prefix_gain > length(values) * 2L) return(VectorCodecPREFIX_DELTA)
  VectorCodecPLAIN
}

deltas <- function(values) {
  if (!length(values)) return(numeric())
  c(values[[1]], diff(values))
}

run_stats <- function(values) {
  if (!length(values)) return(list(0, 0))
  runs <- list()
  run_len <- 1L
  if (length(values) > 1L) {
    for (i in 2:length(values)) {
      if (values[[i]] == values[[i - 1L]]) {
        run_len <- run_len + 1L
      } else {
        runs[[length(runs) + 1L]] <- run_len
        run_len <- 1L
      }
    }
  }
  runs[[length(runs) + 1L]] <- run_len
  repeated_items <- sum(vapply(runs, function(r) if (r > 1L) r else 0L, numeric(1L)))
  list(repeated_items / length(values), mean(unlist(runs)))
}

run_stats_u64 <- function(values) run_stats(values)

bit_width_signed <- function(min_v, max_v) {
  range_val <- if (min_v <= max_v) max_v - min_v else min_v - max_v
  bit_width_u64(range_val)
}

bit_width_u64 <- function(v) {
  if (v == 0) return(1L)
  n <- 0L
  x <- as.numeric(v)
  while (x > 0) {
    x <- bitwShiftR(as.integer(x), 1L)
    n <- n + 1L
  }
  n
}

abs64 <- function(v) if (v < 0) -v else v

common_prefix_len <- function(a, b) {
  n <- min(length(a), length(b))
  i <- 0L
  while (i < n && a[i + 1L] == b[i + 1L]) i <- i + 1L
  i
}

write_smallest_u64 <- function(value, out) {
  value <- as.numeric(value)
  if (value <= 0xFF) {
    out <- raw_append_byte(out, 1L)
    return(raw_append_byte(out, as.integer(value)))
  }
  if (value <= 0xFFFF) {
    out <- raw_append_byte(out, 2L)
    out <- raw_append_byte(out, as.integer(value) %% 256L)
    return(raw_append_byte(out, as.integer(value) %/% 256L))
  }
  if (value <= 0xFFFFFFFF) {
    out <- raw_append_byte(out, 4L)
    for (shift in c(0L, 8L, 16L, 24L)) {
      out <- raw_append_byte(out, as.integer(floor(value / 2^shift)) %% 256L)
    }
    return(out)
  }
  out <- raw_append_byte(out, 8L)
  append_u64_le(out, value)
}

read_smallest_u64 <- function(reader) {
  size <- reader$read_u8()
  if (size == 1L) return(reader$read_u8())
  if (size == 2L) {
    b <- reader$read_exact(2L)
    return(as.integer(b[1L]) + as.integer(b[2L]) * 256L)
  }
  if (size == 4L) {
    b <- reader$read_exact(4L)
    return(as.integer(b[1L]) + as.integer(b[2L]) * 256L + as.integer(b[3L]) * 65536L +
      as.integer(b[4L]) * 16777216L)
  }
  if (size == 8L) return(read_u64_le(reader))
  twilic_stop(invalid_data("smallest u64 size"))
}

rle_encode_bytes <- function(input_data) {
  input_data <- as_raw_input(input_data)
  if (!length(input_data)) return(raw())
  out <- raw()
  i <- 1L
  while (i <= length(input_data)) {
    j <- i + 1L
    while (j <= length(input_data) && input_data[j] == input_data[i] && j - i < 255L) j <- j + 1L
    out <- c(out, as.raw(j - i), input_data[i])
    i <- j
  }
  out
}

rle_decode_bytes <- function(input_data) {
  input_data <- as_raw_input(input_data)
  out <- raw()
  i <- 1L
  while (i <= length(input_data)) {
    if (i + 1L > length(input_data)) twilic_stop(invalid_data("rle payload"))
    run <- as.integer(input_data[i])
    b <- input_data[i + 1L]
    out <- c(out, rep.int(b, run))
    i <- i + 2L
  }
  out
}

control_bitpack_encode_bytes <- function(input_data) as_raw_input(input_data)
control_bitpack_decode_bytes <- function(input_data) as_raw_input(input_data)
control_huffman_encode_bytes <- function(input_data) as_raw_input(input_data)
control_huffman_decode_bytes <- function(input_data) as_raw_input(input_data)
control_fse_encode_bytes <- function(input_data) as_raw_input(input_data)
control_fse_decode_bytes <- function(input_data) as_raw_input(input_data)

template_descriptor_from_columns <- function(template_id, columns) {
  list(
    template_id = template_id,
    field_ids = vapply(columns, function(c) c$field_id, numeric(1)),
    null_strategies = vapply(columns, function(c) c$null_strategy, numeric(1)),
    codecs = vapply(columns, function(c) c$codec, numeric(1))
  )
}

find_template_id <- function(templates, columns) {
  ids <- sort(as.numeric(names(templates)))
  for (tid in ids) {
    t <- templates[[as.character(tid)]]
    if (length(t$field_ids) != length(columns)) next
    ok <- all(vapply(seq_along(columns), function(i) {
      t$field_ids[[i]] == columns[[i]]$field_id && t$null_strategies[[i]] == columns[[i]]$null_strategy
    }, logical(1L)))
    if (ok) return(list(tid, TRUE))
  }
  list(0L, FALSE)
}

diff_template_columns <- function(previous, current) {
  mask <- logical(length(current))
  changed <- list()
  for (i in seq_along(current)) {
    if (i > length(previous) || estimate_column_size(previous[[i]]) != estimate_column_size(current[[i]])) {
      mask[[i]] <- TRUE
      changed[[length(changed) + 1L]] <- current[[i]]
    }
  }
  list(mask, changed)
}

merge_template_columns <- function(previous, changed_mask, changed) {
  out <- vector("list", length(changed_mask))
  idx <- 1L
  for (i in seq_along(changed_mask)) {
    if (isTRUE(changed_mask[[i]])) {
      if (idx > length(changed)) twilic_stop(invalid_data("template changed column count mismatch"))
      out[[i]] <- changed[[idx]]
      idx <- idx + 1L
    } else {
      if (i > length(previous)) twilic_stop(invalid_data("template reference out of range"))
      out[[i]] <- previous[[i]]
    }
  }
  out
}

diff_message <- function(prev, current) {
  a <- message_fields(prev)
  b <- message_fields(current)
  n <- max(length(a), length(b))
  ops <- list()
  for (i in seq_len(n)) {
    if (i <= length(a) && i <= length(b)) {
      if (equal(a[[i]], b[[i]])) {
        ops[[length(ops) + 1L]] <- list(field_id = i - 1L, opcode = PatchOpcodeKEEP, value = NULL)
      } else {
        ops[[length(ops) + 1L]] <- list(
          field_id = i - 1L, opcode = PatchOpcodeREPLACE_SCALAR, value = value_clone(b[[i]])
        )
      }
    } else if (i <= length(b)) {
      ops[[length(ops) + 1L]] <- list(
        field_id = i - 1L, opcode = PatchOpcodeINSERT_FIELD, value = value_clone(b[[i]])
      )
    } else {
      ops[[length(ops) + 1L]] <- list(field_id = i - 1L, opcode = PatchOpcodeDELETE_FIELD, value = NULL)
    }
  }
  list(ops, 0L)
}

message_fields <- function(message) {
  if (message$kind == MessageKindARRAY) return(lapply(message$array, value_clone))
  if (message$kind == MessageKindMAP) return(lapply(message$map, function(e) value_clone(e$value)))
  if (message$kind == MessageKindSHAPED_OBJECT) {
    return(lapply(message$shaped_object$values, value_clone))
  }
  if (message$kind == MessageKindSCHEMA_OBJECT) {
    return(lapply(message$schema_object$fields, value_clone))
  }
  list()
}

rebuild_message_like <- function(base, fields) {
  if (base$kind == MessageKindARRAY) return(new_message(MessageKindARRAY, array = fields))
  if (base$kind == MessageKindMAP) {
    entries <- vector("list", length(fields))
    for (i in seq_along(fields)) {
      if (i <= length(base$map)) {
        entries[[i]] <- list(key = base$map[[i]]$key, value = fields[[i]])
      } else {
        v <- fields[[i]]
        if (v$kind != ValueKindMAP || length(v$map) != 1L) {
          twilic_stop(invalid_data("patch map insert requires single-entry map value"))
        }
        e <- v$map[[1L]]
        entries[[i]] <- list(key = key_ref_literal(e$key), value = value_clone(e$value))
      }
    }
    return(new_message(MessageKindMAP, map = entries))
  }
  if (base$kind == MessageKindSHAPED_OBJECT) {
    s <- base$shaped_object
    return(new_message(MessageKindSHAPED_OBJECT, shaped_object = list(
      shape_id = s$shape_id, presence = s$presence, has_presence = s$has_presence, values = fields
    )))
  }
  if (base$kind == MessageKindSCHEMA_OBJECT) {
    s <- base$schema_object
    return(new_message(MessageKindSCHEMA_OBJECT, schema_object = list(
      schema_id = s$schema_id, presence = s$presence, has_presence = s$has_presence, fields = fields
    )))
  }
  twilic_stop(invalid_data("state patch reconstruction unsupported for this message kind"))
}

estimate_message_size <- function(message) {
  if (message$kind == MessageKindSCALAR) return(1L + estimate_value_size(message$scalar))
  if (message$kind == MessageKindARRAY) {
    return(1L + varuint_size(length(message$array)) +
      sum(vapply(message$array, estimate_value_size, numeric(1L))))
  }
  if (message$kind == MessageKindMAP) {
    return(1L + varuint_size(length(message$map)) +
      sum(vapply(message$map, function(e) {
        encoded_key_ref_size(e$key) + estimate_value_size(e$value)
      }, numeric(1L))))
  }
  if (message$kind == MessageKindSTATE_PATCH) {
    sp <- message$state_patch
    total <- 1L + 2L + varuint_size(length(sp$operations))
    for (op in sp$operations) {
      total <- total + varuint_size(op$field_id) + 2L
      if (!is.null(op$value)) total <- total + estimate_value_size(op$value)
    }
    return(total)
  }
  16L
}

estimate_column_size <- function(column) {
  size <- varuint_size(column$field_id) + 4L
  switch(as.integer(column$values$kind) + 1L,
    size + length(column$values$bools) %/% 8L + 2L,
    size + length(column$values$i64s) * 4L,
    size + length(column$values$u64s) * 4L,
    size + length(column$values$f64s) * 8L,
    size + sum(vapply(column$values$strings, encoded_string_size, numeric(1L))),
    size
  )
}

estimate_value_size <- function(value) {
  switch(as.integer(value$kind) + 1L,
    1L, 1L,
    2L + smallest_u64_size(encode_zigzag(value$i64)),
    2L + smallest_u64_size(value$u64),
    9L,
    2L + encoded_string_size(value$str),
    1L + encoded_bytes_size(length(value$bin)),
    1L + varuint_size(length(value$arr)) + sum(vapply(value$arr, estimate_value_size, numeric(1L))),
    1L + varuint_size(length(value$map)) + sum(vapply(value$map, function(e) {
      encoded_string_size(e$key) + estimate_value_size(e$value)
    }, numeric(1L))),
    1L
  )
}

encoded_bytes_size <- function(len) varuint_size(len) + len

encoded_string_size <- function(value) encoded_bytes_size(nchar(enc2utf8(value), type = "bytes"))

encoded_key_ref_size <- function(key) {
  if (isTRUE(key$is_id)) 1L + varuint_size(key$id) else encoded_string_size(key$literal)
}

varuint_size <- function(value) {
  sz <- 1L
  value <- as.numeric(value)
  while (value >= 0x80) {
    value <- floor(value / 128)
    sz <- sz + 1L
  }
  sz
}

smallest_u64_size <- function(value) {
  if (value <= 0xFF) 1L else if (value <= 0xFFFF) 2L else if (value <= 0xFFFFFFFF) 4L else 8L
}
