# V2 wire profile encoding and decoding (ported from twilic-python v2.py)

NULL_TAG <- 0xC0L
FALSE_TAG <- 0xC1L
TRUE_TAG <- 0xC2L
F64_TAG <- 0xC3L
U8_TAG <- 0xC4L
U16_TAG <- 0xC5L
U32_TAG <- 0xC6L
U64_TAG <- 0xC7L
I8_TAG <- 0xC8L
I16_TAG <- 0xC9L
I32_TAG <- 0xCAL
I64_TAG <- 0xCBL
BIN8_TAG <- 0xCCL
BIN16_TAG <- 0xCDL
BIN32_TAG <- 0xCEL
STR8_TAG <- 0xCFL
STR16_TAG <- 0xD0L
STR32_TAG <- 0xD1L
ARRAY16_TAG <- 0xD2L
ARRAY32_TAG <- 0xD3L
MAP16_TAG <- 0xD4L
MAP32_TAG <- 0xD5L
SHAPE_DEF_TAG <- 0xD6L
KEY_REF_TAG <- 0xD8L
STR_REF_TAG <- 0xD9L

new_v2_encode_state <- function() {
  list(
    key_ids = list(),
    str_ids = list(),
    shape_ids = list(),
    next_key_id = 0L,
    next_str_id = 0L,
    next_shape_id = 0L
  )
}

new_v2_decode_state <- function() {
  list(keys = list(), strings = list(), shapes = list())
}

encode_v2 <- function(value) {
  out <- new_buffer()
  st <- new_v2_encode_state()
  encode_v2_value(value, out, st)
}

decode_v2 <- function(data) {
  reader <- new_reader(data)
  st <- new_v2_decode_state()
  value <- decode_v2_value(reader, st)
  if (!reader$is_eof()) twilic_stop(invalid_data("trailing bytes in v2 decode"))
  value
}

encode_v2_value <- function(value, out, state) {
  switch(
    as.integer(value$kind) + 1L,
    raw_append_byte(out, NULL_TAG),
    raw_append_byte(out, if (isTRUE(value$bool)) TRUE_TAG else FALSE_TAG),
    encode_v2_i64(value$i64, out),
    encode_v2_u64(value$u64, out),
    {
      out <- raw_append_byte(out, F64_TAG)
      append_f64_le(out, value$f64)
    },
    {
      ref_id <- state$str_ids[[value$str]]
      if (!is.null(ref_id)) {
        out <- raw_append_byte(out, STR_REF_TAG)
        encode_varuint(ref_id, out)
      } else {
        out <- encode_v2_string_literal(value$str, out)
        state$str_ids[[value$str]] <- state$next_str_id
        state$next_str_id <- state$next_str_id + 1L
        out
      }
    },
    encode_v2_binary(value$bin, out),
    encode_v2_array(value$arr, out, state),
    encode_v2_map(value$map, out, state),
    twilic_stop(invalid_data("unsupported value kind"))
  )
}

encode_v2_array <- function(values, out, state) {
  shape_keys <- detect_shape_keys(values)
  if (!is.null(shape_keys)) {
    sk <- shape_key(shape_keys)
    shape_id <- state$shape_ids[[sk]]
    if (is.null(shape_id)) {
      shape_id <- state$next_shape_id
      state$next_shape_id <- state$next_shape_id + 1L
      state$shape_ids[[sk]] <- shape_id
    }
    out <- write_v2_array_header(length(values), out)
    out <- raw_append_byte(out, SHAPE_DEF_TAG)
    out <- encode_varuint(shape_id, out)
    out <- encode_varuint(length(shape_keys), out)
    for (key in shape_keys) out <- encode_v2_key(key, out, state)
    for (value in values) {
      if (value$kind != ValueKindMAP) twilic_stop(invalid_data("shape array row must be map"))
      for (field in value$map) out <- encode_v2_value(field$value, out, state)
    }
    return(out)
  }
  out <- write_v2_array_header(length(values), out)
  for (value in values) out <- encode_v2_value(value, out, state)
  out
}

encode_v2_map <- function(entries, out, state) {
  out <- write_v2_map_header(length(entries), out)
  for (entry_ in entries) {
    out <- encode_v2_key(entry_$key, out, state)
    out <- encode_v2_value(entry_$value, out, state)
  }
  out
}

encode_v2_key <- function(key, out, state) {
  ref_id <- state$key_ids[[key]]
  if (!is.null(ref_id)) {
    out <- raw_append_byte(out, KEY_REF_TAG)
    return(encode_varuint(ref_id, out))
  }
  out <- encode_v2_string_literal(key, out)
  state$key_ids[[key]] <- state$next_key_id
  state$next_key_id <- state$next_key_id + 1L
  out
}

encode_v2_string_literal <- function(value, out) {
  raw <- charToRaw(enc2utf8(value))
  length <- length(raw)
  if (length <= 31L) {
    out <- raw_append_byte(out, bitwOr(0x80L, length))
  } else if (length <= 0xFFL) {
    out <- raw_append_byte(out, STR8_TAG)
    out <- raw_append_byte(out, length)
  } else if (length <= 0xFFFFL) {
    out <- raw_append_bytes(out, c(STR16_TAG, length %% 256L, bitwShiftR(length, 8L) %% 256L))
  } else {
    out <- raw_append_byte(out, STR32_TAG)
    out <- raw_append_bytes(out, c(
      length %% 256L,
      bitwShiftR(length, 8L) %% 256L,
      bitwShiftR(length, 16L) %% 256L,
      bitwShiftR(length, 24L) %% 256L
    ))
  }
  raw_append_bytes(out, raw)
}

encode_v2_binary <- function(value, out) {
  value <- as_raw_input(value)
  length <- length(value)
  if (length <= 0xFFL) {
    out <- raw_append_bytes(out, c(BIN8_TAG, length))
  } else if (length <= 0xFFFFL) {
    out <- raw_append_bytes(out, c(BIN16_TAG, length %% 256L, bitwShiftR(length, 8L) %% 256L))
  } else {
    out <- raw_append_byte(out, BIN32_TAG)
    out <- raw_append_bytes(out, c(
      length %% 256L,
      bitwShiftR(length, 8L) %% 256L,
      bitwShiftR(length, 16L) %% 256L,
      bitwShiftR(length, 24L) %% 256L
    ))
  }
  raw_append_bytes(out, value)
}

encode_v2_u64 <- function(value, out) {
  value <- as.numeric(value)
  if (value <= 127) {
    raw_append_byte(out, as.integer(value))
  } else if (value <= 0xFF) {
    raw_append_bytes(out, c(U8_TAG, as.integer(value)))
  } else if (value <= 0xFFFF) {
    raw_append_bytes(out, c(U16_TAG, as.integer(value) %% 256L, bitwShiftR(as.integer(value), 8L) %% 256L))
  } else if (value <= 0xFFFFFFFF) {
    v <- as.integer(value)
    raw_append_bytes(out, c(
      U32_TAG,
      v %% 256L,
      bitwShiftR(v, 8L) %% 256L,
      bitwShiftR(v, 16L) %% 256L,
      bitwShiftR(v, 24L) %% 256L
    ))
  } else {
    out <- raw_append_byte(out, U64_TAG)
    append_u64_le(out, value)
  }
}

encode_v2_i64 <- function(value, out) {
  value <- as.numeric(value)
  if (value >= -32 && value <= -1) {
    raw_append_byte(out, as.integer(value) %% 256L)
  } else if (value >= 0 && value <= 127) {
    raw_append_byte(out, as.integer(value))
  } else if (value >= -128 && value <= 127) {
    raw_append_bytes(out, c(I8_TAG, as.integer(value) %% 256L))
  } else if (value >= -32768 && value <= 32767) {
    v <- as.integer(value)
    raw_append_bytes(out, c(I16_TAG, v %% 256L, bitwShiftR(v, 8L) %% 256L))
  } else if (value >= -2147483648 && value <= 2147483647) {
    v <- as.integer(value)
    raw_append_bytes(out, c(
      I32_TAG,
      v %% 256L,
      bitwShiftR(v, 8L) %% 256L,
      bitwShiftR(v, 16L) %% 256L,
      bitwShiftR(v, 24L) %% 256L
    ))
  } else {
    out <- raw_append_byte(out, I64_TAG)
    append_u64_le(out, bitwAnd(value, 18446744073709551615))
  }
}

write_v2_array_header <- function(length, out) {
  length <- as.integer(length)
  if (length <= 15L) {
    raw_append_byte(out, bitwOr(0xA0L, length))
  } else if (length <= 0xFFFFL) {
    raw_append_bytes(out, c(ARRAY16_TAG, length %% 256L, bitwShiftR(length, 8L) %% 256L))
  } else {
    out <- raw_append_byte(out, ARRAY32_TAG)
    raw_append_bytes(out, c(
      length %% 256L,
      bitwShiftR(length, 8L) %% 256L,
      bitwShiftR(length, 16L) %% 256L,
      bitwShiftR(length, 24L) %% 256L
    ))
  }
}

write_v2_map_header <- function(length, out) {
  length <- as.integer(length)
  if (length <= 15L) {
    raw_append_byte(out, bitwOr(0xB0L, length))
  } else if (length <= 0xFFFFL) {
    raw_append_bytes(out, c(MAP16_TAG, length %% 256L, bitwShiftR(length, 8L) %% 256L))
  } else {
    out <- raw_append_byte(out, MAP32_TAG)
    raw_append_bytes(out, c(
      length %% 256L,
      bitwShiftR(length, 8L) %% 256L,
      bitwShiftR(length, 16L) %% 256L,
      bitwShiftR(length, 24L) %% 256L
    ))
  }
}

detect_shape_keys <- function(values) {
  if (length(values) < 2L) return(NULL)
  if (values[[1]]$kind != ValueKindMAP || !length(values[[1]]$map)) return(NULL)
  keys <- vapply(values[[1]]$map, function(e) e$key, character(1))
  for (value in values[-1]) {
    if (value$kind != ValueKindMAP || length(value$map) != length(keys)) return(NULL)
    for (i in seq_along(keys)) {
      if (value$map[[i]]$key != keys[[i]]) return(NULL)
    }
  }
  keys
}

decode_v2_value <- function(reader, state) {
  tag <- reader$read_u8()
  decode_v2_value_from_tag(reader, state, tag)
}

decode_v2_value_from_tag <- function(reader, state, tag) {
  if (tag <= 0x7F) return(new_u64(tag))
  if (tag >= 0x80 && tag <= 0x9F) {
    length <- bitwAnd(tag, 0x1FL)
    raw <- reader$read_exact(length)
    s <- rawToChar(raw)
    state$strings[[length(state$strings) + 1L]] <- s
    return(new_string(s))
  }
  if (tag >= 0xA0 && tag <= 0xAF) {
    return(decode_v2_array_body(reader, state, bitwAnd(tag, 0x0FL)))
  }
  if (tag >= 0xB0 && tag <= 0xBF) {
    return(decode_v2_map_body(reader, state, bitwAnd(tag, 0x0FL)))
  }
  if (tag >= 0xE0) return(new_i64(if (tag < 128) tag else tag - 256L))
  if (tag == NULL_TAG) return(new_null())
  if (tag == FALSE_TAG) return(new_bool(FALSE))
  if (tag == TRUE_TAG) return(new_bool(TRUE))
  if (tag == F64_TAG) return(new_f64(read_f64_le(reader)))
  if (tag == U8_TAG) return(new_u64(reader$read_u8()))
  if (tag == U16_TAG) {
    b <- reader$read_exact(2L)
    return(new_u64(as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L)))
  }
  if (tag == U32_TAG) {
    b <- reader$read_exact(4L)
    return(new_u64(
      as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L) +
        bitwShiftL(as.integer(b[3]), 16L) + bitwShiftL(as.integer(b[4]), 24L)
    ))
  }
  if (tag == U64_TAG) return(new_u64(read_u64_le(reader)))
  if (tag == I8_TAG) {
    b <- reader$read_u8()
    return(new_i64(if (b < 128) b else b - 256L))
  }
  if (tag == I16_TAG) {
    b <- reader$read_exact(2L)
    return(new_i64(readBin(b, what = integer(), size = 2, endian = "little", signed = TRUE)))
  }
  if (tag == I32_TAG) {
    b <- reader$read_exact(4L)
    return(new_i64(readBin(b, what = integer(), size = 4, endian = "little", signed = TRUE)))
  }
  if (tag == I64_TAG) {
    b <- reader$read_exact(8L)
    return(new_i64(readBin(b, what = integer(), size = 8, endian = "little", signed = TRUE)))
  }
  if (tag == BIN8_TAG) return(new_binary(reader$read_exact(reader$read_u8())))
  if (tag == BIN16_TAG) {
    b <- reader$read_exact(2L)
    n <- as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L)
    return(new_binary(reader$read_exact(n)))
  }
  if (tag == BIN32_TAG) {
    b <- reader$read_exact(4L)
    n <- as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L) +
      bitwShiftL(as.integer(b[3]), 16L) + bitwShiftL(as.integer(b[4]), 24L)
    return(new_binary(reader$read_exact(n)))
  }
  if (tag %in% c(STR8_TAG, STR16_TAG, STR32_TAG)) return(decode_v2_string_tag(reader, state, tag))
  if (tag == ARRAY16_TAG) {
    b <- reader$read_exact(2L)
    n <- as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L)
    return(decode_v2_array_body(reader, state, n))
  }
  if (tag == ARRAY32_TAG) {
    b <- reader$read_exact(4L)
    n <- as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L) +
      bitwShiftL(as.integer(b[3]), 16L) + bitwShiftL(as.integer(b[4]), 24L)
    return(decode_v2_array_body(reader, state, n))
  }
  if (tag == MAP16_TAG) {
    b <- reader$read_exact(2L)
    n <- as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L)
    return(decode_v2_map_body(reader, state, n))
  }
  if (tag == MAP32_TAG) {
    b <- reader$read_exact(4L)
    n <- as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L) +
      bitwShiftL(as.integer(b[3]), 16L) + bitwShiftL(as.integer(b[4]), 24L)
    return(decode_v2_map_body(reader, state, n))
  }
  if (tag == STR_REF_TAG) {
    ref_id <- reader$read_varuint()
    if (ref_id >= length(state$strings)) twilic_stop(invalid_data("unknown str_ref id"))
    return(new_string(state$strings[[ref_id + 1L]]))
  }
  twilic_stop(invalid_tag(tag))
}

decode_v2_string_tag <- function(reader, state, tag) {
  length <- if (tag == STR8_TAG) {
    reader$read_u8()
  } else if (tag == STR16_TAG) {
    b <- reader$read_exact(2L)
    as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L)
  } else if (tag == STR32_TAG) {
    b <- reader$read_exact(4L)
    as.integer(b[1]) + bitwShiftL(as.integer(b[2]), 8L) +
      bitwShiftL(as.integer(b[3]), 16L) + bitwShiftL(as.integer(b[4]), 24L)
  } else {
    twilic_stop(invalid_data("invalid string tag"))
  }
  raw <- reader$read_exact(length)
  s <- rawToChar(raw)
  state$strings[[length(state$strings) + 1L]] <- s
  new_string(s)
}

decode_v2_array_body <- function(reader, state, length) {
  reader$claim_output(length)
  reader$enter_depth()
  on.exit(reader$leave_depth(), add = TRUE)
  if (length == 0L) return(new_array(list()))
  first_tag <- reader$read_u8()
  if (first_tag == SHAPE_DEF_TAG) {
    shape_id <- reader$read_count(65535)
    key_count <- reader$read_count(256)
    keys <- character(key_count)
    for (i in seq_len(key_count)) keys[[i]] <- decode_v2_key(reader, state)
    state$shapes[[shape_id + 1L]] <- keys
    values <- vector("list", length)
    for (i in seq_len(length)) {
      reader$claim_output(key_count)
      row <- lapply(keys, function(key) entry(key, decode_v2_value(reader, state)))
      values[[i]] <- do.call(new_map, row)
    }
    return(new_array(values))
  }
  values <- vector("list", length)
  values[[1]] <- decode_v2_value_from_tag(reader, state, first_tag)
  if (length > 1L) {
    for (i in 2:length) values[[i]] <- decode_v2_value(reader, state)
  }
  new_array(values)
}

decode_v2_map_body <- function(reader, state, length) {
  reader$claim_output(length)
  reader$enter_depth()
  on.exit(reader$leave_depth(), add = TRUE)
  entries <- vector("list", length)
  for (i in seq_len(length)) {
    key <- decode_v2_key(reader, state)
    value <- decode_v2_value(reader, state)
    entries[[i]] <- entry(key, value)
  }
  do.call(new_map, entries)
}

decode_v2_key <- function(reader, state) {
  tag <- reader$read_u8()
  if (tag == KEY_REF_TAG) {
    ref_id <- reader$read_varuint()
    if (ref_id >= length(state$keys)) twilic_stop(invalid_data("unknown key_ref id"))
    return(state$keys[[ref_id + 1L]])
  }
  if (tag >= 0x80 && tag <= 0x9F) {
    length <- bitwAnd(tag, 0x1FL)
    key <- rawToChar(reader$read_exact(length))
    state$keys[[length(state$keys) + 1L]] <- key
    return(key)
  }
  if (tag %in% c(STR8_TAG, STR16_TAG, STR32_TAG)) {
    v <- decode_v2_value_from_tag(reader, state, tag)
    if (v$kind != ValueKindSTRING) twilic_stop(invalid_data("expected string key"))
    state$keys[[length(state$keys) + 1L]] <- v$str
    return(v$str)
  }
  twilic_stop(invalid_data("map key must be key_ref or string"))
}
