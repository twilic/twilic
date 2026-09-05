
SIMPLE8B_SLOTS <- list(
  c(60L, 1L), c(30L, 2L), c(20L, 3L), c(15L, 4L), c(12L, 5L), c(10L, 6L),
  c(8L, 7L), c(7L, 8L), c(6L, 10L), c(5L, 12L), c(4L, 15L), c(3L, 20L),
  c(2L, 30L), c(1L, 60L)
)
U64_MAX <- 18446744073709551615
SIMPLE8B_MAX_U64 <- 1152921504606846975 # 2^60 - 1

i64_plain_codecs <- c(
  VectorCodecPLAIN, VectorCodecDICTIONARY, VectorCodecSTRING_REF,
  VectorCodecPREFIX_DELTA, VectorCodecXOR_FLOAT
)

u64_plain_codecs <- c(
  VectorCodecDICTIONARY, VectorCodecSTRING_REF, VectorCodecPREFIX_DELTA,
  VectorCodecXOR_FLOAT, VectorCodecDELTA_BITPACK, VectorCodecDELTA_FOR_BITPACK,
  VectorCodecDELTA_DELTA_BITPACK, VectorCodecPATCHED_FOR
)

encode_i64_vector <- function(values, codec, out) {
  codec <- as.integer(codec)
  if (codec == VectorCodecRLE) return(encode_i64_rle(values, out))
  if (codec == VectorCodecDIRECT_BITPACK) return(encode_i64_direct_bitpack(values, out))
  if (codec == VectorCodecDELTA_BITPACK) return(encode_i64_direct_bitpack(delta(values), out))
  if (codec == VectorCodecFOR_BITPACK) {
    if (!length(values)) return(encode_varuint(0, out))
    min_value <- min(values)
    out <- encode_varuint(encode_zigzag(min_value), out)
    return(encode_i64_direct_bitpack(values - min_value, out))
  }
  if (codec == VectorCodecDELTA_FOR_BITPACK) {
    d <- delta(values)
    if (!length(d)) return(encode_varuint(0, out))
    min_value <- min(d)
    out <- encode_varuint(encode_zigzag(min_value), out)
    return(encode_i64_direct_bitpack(d - min_value, out))
  }
  if (codec == VectorCodecDELTA_DELTA_BITPACK) return(encode_i64_delta_delta(values, out))
  if (codec == VectorCodecPATCHED_FOR) return(encode_i64_patched_for(values, out))
  if (codec == VectorCodecSIMPLE8B) return(encode_i64_simple8b(values, out))
  if (codec %in% i64_plain_codecs) return(encode_i64_plain(values, out))
  twilic_stop(invalid_data("unsupported vector codec"))
}

decode_i64_vector <- function(reader, codec) {
  codec <- as.integer(codec)
  if (codec == VectorCodecRLE) return(decode_i64_rle(reader))
  if (codec == VectorCodecDIRECT_BITPACK) return(decode_i64_direct_bitpack(reader))
  if (codec == VectorCodecDELTA_BITPACK) return(undelta(decode_i64_direct_bitpack(reader)))
  if (codec == VectorCodecFOR_BITPACK) {
    min_value <- decode_zigzag(reader$read_varuint())
    if (reader$is_eof()) return(integer())
    return(decode_i64_direct_bitpack(reader) + min_value)
  }
  if (codec == VectorCodecDELTA_FOR_BITPACK) {
    min_value <- decode_zigzag(reader$read_varuint())
    if (reader$is_eof()) return(integer())
    return(undelta(decode_i64_direct_bitpack(reader) + min_value))
  }
  if (codec == VectorCodecDELTA_DELTA_BITPACK) return(decode_i64_delta_delta(reader))
  if (codec == VectorCodecPATCHED_FOR) return(decode_i64_patched_for(reader))
  if (codec == VectorCodecSIMPLE8B) return(decode_i64_simple8b(reader))
  if (codec %in% i64_plain_codecs) return(decode_i64_plain(reader))
  twilic_stop(invalid_data("unsupported vector codec"))
}

encode_u64_vector <- function(values, codec, out) {
  codec <- as.integer(codec)
  if (codec == VectorCodecRLE) return(encode_u64_rle(values, out))
  if (codec == VectorCodecDIRECT_BITPACK) return(encode_u64_direct_bitpack(values, out))
  if (codec == VectorCodecFOR_BITPACK) {
    if (!length(values)) return(encode_varuint(0, out))
    min_value <- min(values)
    out <- encode_varuint(min_value, out)
    return(encode_u64_direct_bitpack(values - min_value, out))
  }
  if (codec == VectorCodecPLAIN) return(encode_u64_plain(values, out))
  if (codec == VectorCodecSIMPLE8B) return(encode_u64_simple8b(values, out))
  if (codec %in% u64_plain_codecs) return(encode_u64_plain(values, out))
  twilic_stop(invalid_data("unsupported vector codec"))
}

decode_u64_vector <- function(reader, codec) {
  codec <- as.integer(codec)
  if (codec == VectorCodecRLE) return(decode_u64_rle(reader))
  if (codec == VectorCodecDIRECT_BITPACK) return(decode_u64_direct_bitpack(reader))
  if (codec == VectorCodecFOR_BITPACK) {
    min_value <- reader$read_varuint()
    if (reader$is_eof()) return(numeric())
    shifted <- decode_u64_direct_bitpack(reader)
    out <- numeric(length(shifted))
    for (i in seq_along(shifted)) {
      sum_ok <- checked_add_u64(shifted[[i]], min_value)
      if (!sum_ok[[2]]) twilic_stop(invalid_data("u64 FOR overflow"))
      out[[i]] <- sum_ok[[1]]
    }
    return(out)
  }
  if (codec == VectorCodecPLAIN) return(decode_u64_plain(reader))
  if (codec == VectorCodecSIMPLE8B) return(decode_u64_simple8b(reader))
  if (codec %in% u64_plain_codecs) return(decode_u64_plain(reader))
  twilic_stop(invalid_data("unsupported vector codec"))
}

encode_f64_vector <- function(values, codec, out) {
  if (codec == VectorCodecXorFloat) return(encode_xor_float(values, out))
  out <- encode_varuint(length(values), out)
  for (v in values) out <- append_f64_le(out, v)
  out
}

decode_f64_vector <- function(reader, codec) {
  if (codec == VectorCodecXorFloat) return(decode_xor_float(reader))
  length <- reader$read_count()
  vapply(seq_len(length), function(i) read_f64_le(reader), numeric(1))
}

encode_u64_plain <- function(values, out) {
  out <- encode_varuint(length(values), out)
  for (value in values) out <- encode_varuint(value, out)
  out
}

decode_u64_plain <- function(reader) {
  length <- reader$read_count()
  vapply(seq_len(length), function(i) reader$read_varuint(), numeric(1))
}

encode_u64_rle <- function(values, out) {
  runs <- list()
  for (value in values) {
    if (length(runs) && runs[[length(runs)]][[1]] == value) {
      runs[[length(runs)]][[2]] <- runs[[length(runs)]][[2]] + 1L
    } else {
      runs[[length(runs) + 1L]] <- list(value, 1L)
    }
  }
  out <- encode_varuint(length(runs), out)
  for (run in runs) {
    out <- encode_varuint(run[[1]], out)
    out <- encode_varuint(run[[2]], out)
  }
  out
}

decode_u64_rle <- function(reader) {
  runs_len <- reader$read_count()
  out <- numeric()
  for (i in seq_len(runs_len)) {
    value <- reader$read_varuint()
    count <- reader$read_count()
    out <- c(out, rep(value, count))
  }
  out
}

encode_u64_direct_bitpack <- function(values, out) {
  out <- encode_varuint(length(values), out)
  if (!length(values)) return(raw_append_byte(out, 0L))
  width <- max(1L, vapply(values, bit_width, integer(1)))
  out <- raw_append_byte(out, width)
  pack_u64_values(values, width, out)
}

decode_u64_direct_bitpack <- function(reader) {
  length <- reader$read_count()
  width <- reader$read_u8()
  if (length == 0L) return(numeric())
  if (width == 0L || width > 64L) twilic_stop(invalid_data("bitpack width"))
  unpack_u64_values(reader, length, width)
}

encode_i64_plain <- function(values, out) {
  out <- encode_varuint(length(values), out)
  for (value in values) out <- encode_varuint(encode_zigzag(value), out)
  out
}

decode_i64_plain <- function(reader) {
  length <- reader$read_count()
  vapply(seq_len(length), function(i) decode_zigzag(reader$read_varuint()), numeric(1))
}

encode_i64_simple8b <- function(values, out) {
  encode_u64_simple8b_inner(vapply(values, encode_zigzag, numeric(1)), out)
}

decode_i64_simple8b <- function(reader) {
  vapply(decode_u64_simple8b_inner(reader), decode_zigzag, numeric(1))
}

encode_u64_simple8b <- function(values, out) encode_u64_simple8b_inner(values, out)

decode_u64_simple8b <- function(reader) decode_u64_simple8b_inner(reader)

pack_simple8b_word <- function(selector, payload_raw) {
  bits <- integer(64)
  payload_bits <- raw8_to_bits(as_raw_input(payload_raw))
  bits[1:60] <- payload_bits[1:60]
  for (j in 0:3) {
    if (bitwAnd(selector, bitwShiftL(1L, j)) != 0L) bits[61 + j] <- 1L
  }
  bits_to_raw8(bits)
}

unpack_simple8b_word <- function(word_raw) {
  bits <- raw8_to_bits(as_raw_input(word_raw))
  selector <- 0L
  for (j in 0:3) {
    if (bits[[61 + j]] != 0L) selector <- selector + bitwShiftL(1L, j)
  }
  list(
    selector = selector,
    payload = bits_to_raw8(c(bits[1:60], rep(0L, 4L)))
  )
}

pack_simple8b_payload <- function(values, width) {
  width <- as.integer(width)
  bits <- integer(64)
  shift <- 0L
  for (i in seq_along(values)) {
    vb <- u64_to_bits(as.numeric(values[[i]]))
    idx <- (shift + 1L):(shift + width)
    bits[idx] <- as.integer(vb[seq_len(width)])
    shift <- shift + width
  }
  bits_to_raw8(bits)
}

unpack_simple8b_payload <- function(payload_raw, width, count) {
  bits <- raw8_to_bits(as_raw_input(payload_raw))
  out <- numeric(count)
  shift <- 0L
  for (i in seq_len(count)) {
    slot <- bits[(shift + 1L):(shift + width)]
    out[[i]] <- u64_from_bits(c(slot, rep(0L, 64L - width)))
    shift <- shift + width
  }
  out
}

encode_u64_simple8b_inner <- function(values, out) {
  out <- encode_varuint(length(values), out)
  if (!length(values)) return(out)
  max_value <- max(values)
  if (max_value > SIMPLE8B_MAX_U64) {
    out <- raw_append_byte(out, 0L)
    for (value in values) out <- encode_varuint(value, out)
    return(out)
  }
  out <- raw_append_byte(out, 1L)
  idx <- 1L
  while (idx <= length(values)) {
    zero_run <- 0L
    while (idx + zero_run <= length(values) && values[idx + zero_run] == 0 && zero_run < 240L) {
      zero_run <- zero_run + 1L
    }
    if (zero_run >= 120L) {
      take <- if (zero_run >= 240L) 240L else 120L
      word <- if (take == 240L) {
        as.raw(rep(0, 8))
      } else {
        pack_simple8b_word(1L, as.raw(rep(0, 8)))
      }
      out <- raw_append_bytes(out, word)
      idx <- idx + take
      next
    }
    packed <- FALSE
    for (selector_idx in seq_along(SIMPLE8B_SLOTS)) {
      slot <- SIMPLE8B_SLOTS[[selector_idx]]
      count <- slot[[1]]
      slot_width <- slot[[2]]
      if (idx + count - 1L > length(values)) next
      slice <- values[idx:(idx + count - 1L)]
      max_encodable <- if (slot_width == 64L) U64_MAX else u64_mask_low(slot_width)
      if (any(slice > max_encodable)) next
      selector <- selector_idx + 1L
      payload <- pack_simple8b_payload(slice, slot_width)
      word <- pack_simple8b_word(selector, payload)
      out <- raw_append_bytes(out, word)
      idx <- idx + count
      packed <- TRUE
      break
    }
    if (!packed) {
      selector <- 15L
      word <- pack_simple8b_word(
        selector,
        pack_simple8b_payload(as.numeric(values[[idx]]), 60L)
      )
      out <- raw_append_bytes(out, word)
      idx <- idx + 1L
    }
  }
  out
}

decode_u64_simple8b_inner <- function(reader) {
  length <- reader$read_count()
  if (length == 0L) return(numeric())
  mode <- reader$read_u8()
  if (mode == 0L) return(vapply(seq_len(length), function(i) reader$read_varuint(), numeric(1)))
  if (mode != 1L) twilic_stop(invalid_data("simple8b mode"))
  out <- numeric()
  while (length(out) < length) {
    packed <- reader$read_exact(8L)
    unpacked <- unpack_simple8b_word(packed)
    selector <- unpacked$selector
    payload <- unpacked$payload
    if (selector %in% c(0L, 1L)) {
      count <- if (selector == 0L) 240L else 120L
      remain <- length - length(out)
      limit <- min(count, remain)
      out <- c(out, rep(0, limit))
    } else if (selector >= 2L && selector <= 15L) {
      if (selector == 15L) {
        count <- 1L
        width <- 60L
      } else {
        slot <- SIMPLE8B_SLOTS[[selector - 1L]]
        count <- slot[[1]]
        width <- slot[[2]]
      }
      remain <- length - length(out)
      limit <- min(count, remain)
      out <- c(out, unpack_simple8b_payload(payload, width, limit))
    } else {
      twilic_stop(invalid_data("simple8b selector"))
    }
  }
  out
}

delta <- function(values) {
  if (!length(values)) return(integer())
  out <- numeric(length(values))
  prev <- 0
  for (i in seq_along(values)) {
    if (i == 1L) out[i] <- values[i] else out[i] <- values[i] - prev
    prev <- values[i]
  }
  out
}

undelta <- function(values) {
  if (!length(values)) return(integer())
  out <- numeric(length(values))
  prev <- 0
  for (i in seq_along(values)) {
    if (i == 1L) {
      out[i] <- values[i]
      prev <- values[i]
    } else {
      nxt <- prev + values[i]
      if ((values[i] > 0 && nxt < prev) || (values[i] < 0 && nxt > prev)) {
        twilic_stop(invalid_data("delta overflow"))
      }
      out[i] <- nxt
      prev <- nxt
    }
  }
  out
}

encode_i64_rle <- function(values, out) {
  runs <- list()
  for (value in values) {
    if (length(runs) && runs[[length(runs)]][[1]] == value) {
      runs[[length(runs)]][[2]] <- runs[[length(runs)]][[2]] + 1L
    } else {
      runs[[length(runs) + 1L]] <- list(value, 1L)
    }
  }
  out <- encode_varuint(length(runs), out)
  for (run in runs) {
    out <- encode_varuint(encode_zigzag(run[[1]]), out)
    out <- encode_varuint(run[[2]], out)
  }
  out
}

decode_i64_rle <- function(reader) {
  runs_len <- reader$read_count()
  out <- numeric()
  for (i in seq_len(runs_len)) {
    value <- decode_zigzag(reader$read_varuint())
    count <- reader$read_count()
    out <- c(out, rep(value, count))
  }
  out
}

encode_i64_patched_for <- function(values, out) {
  if (!length(values)) return(encode_varuint(0, out))
  base <- min(values)
  shifted <- values - base
  out <- encode_varuint(length(shifted), out)
  out <- encode_varuint(encode_zigzag(base), out)
  max_value <- if (length(shifted)) max(shifted) else 0
  bw <- bit_width(max_value)
  base_width <- if (bw > 2L) bw - 2L else 0L
  out <- raw_append_byte(out, base_width)
  patch_positions <- list()
  main_values <- numeric()
  for (idx in seq_along(shifted)) {
    value <- shifted[idx]
    if (bit_width(value) > base_width) {
      patch_positions[[length(patch_positions) + 1L]] <- list(idx - 1L, value)
      main <- 0L
      if (base_width > 0L) {
        mask <- bitwShiftL(1L, base_width) - 1L
        main <- bitwAnd(value, mask)
        if (main < 0L) main <- 0L
      }
      main_values <- c(main_values, main)
    } else {
      main_values <- c(main_values, value)
    }
  }
  for (value in main_values) out <- encode_varuint(value, out)
  out <- encode_varuint(length(patch_positions), out)
  for (pos in patch_positions) {
    out <- encode_varuint(pos[[1]], out)
    out <- encode_varuint(pos[[2]], out)
  }
  out
}

decode_i64_patched_for <- function(reader) {
  length <- reader$read_count()
  if (length == 0L) return(integer())
  base <- decode_zigzag(reader$read_varuint())
  reader$read_u8()
  values <- vapply(seq_len(length), function(i) reader$read_varuint(), numeric(1))
  patch_count <- reader$read_count()
  for (i in seq_len(patch_count)) {
    pos <- reader$read_varuint()
    patch <- reader$read_varuint()
    if (pos < length(values)) values[pos + 1L] <- patch
  }
  values + base
}

encode_xor_float <- function(values, out) {
  out <- encode_varuint(length(values), out)
  if (!length(values)) return(out)
  first_bits <- f64_to_u64(values[[1]])
  out <- append_u64_le(out, first_bits)
  prev <- first_bits
  if (length(values) > 1L) {
    for (value in values[-1]) {
      bits_value <- f64_to_u64(value)
      x <- u64_xor(prev, bits_value)
      if (x == 0) {
        out <- raw_append_byte(out, 0L)
      } else {
        out <- raw_append_byte(out, 1L)
        leading <- leading_zeros64(x)
        trailing <- trailing_zeros64(x)
        width <- 64L - (leading + trailing)
        out <- encode_varuint(leading, out)
        out <- encode_varuint(trailing, out)
        out <- encode_varuint(width, out)
        payload <- if (width == 64L) x else u64_and(u64_shr(x, trailing), u64_mask_low(width))
        out <- encode_varuint(payload, out)
      }
      prev <- bits_value
    }
  }
  out
}

decode_xor_float <- function(reader) {
  length <- reader$read_count()
  if (length == 0L) return(numeric())
  prev_raw <- reader$read_exact(8L)
  out <- list(readBin(prev_raw, what = double(), size = 8, endian = "little"))
  if (length > 1L) {
    for (i in 2:length) {
      flag <- reader$read_u8()
      bits_raw <- prev_raw
      if (flag != 0L) {
        leading <- reader$read_varuint()
        trailing <- reader$read_varuint()
        width <- reader$read_varuint()
        payload <- reader$read_varuint()
        if (leading + trailing + width > 64L) twilic_stop(invalid_data("xor-float bit widths"))
        x_raw <- if (width == 64L) {
          u64_to_le_bytes(payload)
        } else {
          bits <- rep(0L, 64)
          pb <- u64_to_bits(payload)
          bits[(trailing + 1L):(trailing + width)] <- pb[seq_len(width)]
          u64_to_le_bytes(u64_from_bits(bits))
        }
        bits_raw <- xor_raw8(prev_raw, x_raw)
      }
      out[[length(out) + 1L]] <- readBin(bits_raw, what = double(), size = 8, endian = "little")
      prev_raw <- bits_raw
    }
  }
  unlist(out)
}

f64_to_u64 <- function(v) {
  u64_from_le_bytes(writeBin(as.double(v), raw(8), size = 8, endian = "little"))
}

u64_to_f64 <- function(u) {
  readBin(u64_to_le_bytes(u), what = double(), size = 8, endian = "little")
}

encode_i64_direct_bitpack <- function(values, out) {
  out <- encode_varuint(length(values), out)
  if (!length(values)) return(raw_append_byte(out, 0L))
  encoded <- vapply(values, encode_zigzag, numeric(1))
  width <- max(vapply(encoded, bit_width, integer(1)))
  out <- raw_append_byte(out, width)
  pack_u64_values(encoded, width, out)
}

decode_i64_direct_bitpack <- function(reader) {
  length <- reader$read_count()
  width <- reader$read_u8()
  if (length == 0L) return(integer())
  if (width == 0L || width > 64L) twilic_stop(invalid_data("bitpack width"))
  vapply(unpack_u64_values(reader, length, width), decode_zigzag, numeric(1))
}

encode_i64_delta_delta <- function(values, out) {
  out <- encode_varuint(length(values), out)
  if (!length(values)) return(out)
  out <- encode_varuint(encode_zigzag(values[[1]]), out)
  if (length(values) == 1L) return(out)
  d1 <- values[[2]] - values[[1]]
  out <- encode_varuint(encode_zigzag(d1), out)
  dd <- numeric()
  prev_delta <- d1
  if (length(values) > 2L) {
    for (i in 2:(length(values) - 1L)) {
      d <- values[[i + 1L]] - values[[i]]
      dd <- c(dd, d - prev_delta)
      prev_delta <- d
    }
  }
  encode_i64_direct_bitpack(dd, out)
}

decode_i64_delta_delta <- function(reader) {
  length <- reader$read_count()
  if (length == 0L) return(integer())
  first <- decode_zigzag(reader$read_varuint())
  if (length == 1L) return(first)
  first_delta <- decode_zigzag(reader$read_varuint())
  dd <- decode_i64_direct_bitpack(reader)
  if (length(dd) != length - 2L) twilic_stop(invalid_data("delta-delta length"))
  out <- c(first)
  prev <- first
  second <- prev + first_delta
  out <- c(out, second)
  prev <- second
  prev_delta <- first_delta
  for (ddv in dd) {
    d <- prev_delta + ddv
    nxt <- prev + d
    out <- c(out, nxt)
    prev <- nxt
    prev_delta <- d
  }
  out
}

pack_u64_values <- function(values, width, out) {
  total_bits <- length(values) * width
  byte_len <- (total_bits + 7L) %/% 8L
  bytes_arr <- raw(byte_len)
  bit_pos <- 0L
  for (value in values) {
    written <- 0L
    while (written < width) {
      byte_idx <- bit_pos %/% 8L
      bit_off <- bit_pos %% 8L
      room <- 8L - bit_off
      take <- min(width - written, room)
      mask <- bitwShiftL(1L, take) - 1L
      part <- bitwAnd(bitwShiftR(as.numeric(value), written), mask)
      bytes_arr[byte_idx + 1L] <- as.raw(bitwOr(as.integer(bytes_arr[byte_idx + 1L]), bitwShiftL(part, bit_off)))
      bit_pos <- bit_pos + take
      written <- written + take
    }
  }
  raw_append_bytes(out, bytes_arr)
}

unpack_u64_values <- function(reader, length, width) {
  total_bits <- length * width
  byte_len <- (total_bits + 7L) %/% 8L
  raw <- reader$read_exact(byte_len)
  out <- numeric(length)
  bit_pos <- 0L
  for (i in seq_len(length)) {
    value <- 0
    written <- 0L
    while (written < width) {
      byte_idx <- bit_pos %/% 8L + 1L
      if (byte_idx > length(raw)) twilic_stop(invalid_data("bitpack underflow"))
      bit_off <- bit_pos %% 8L
      room <- 8L - bit_off
      take <- min(width - written, room)
      mask <- bitwShiftL(1L, take) - 1L
      part <- bitwAnd(bitwShiftR(as.integer(raw[byte_idx]), bit_off), mask)
      value <- value + bitwShiftL(part, written)
      bit_pos <- bit_pos + take
      written <- written + take
    }
    out[i] <- value
  }
  out
}

bit_length64 <- function(x) {
  if (x == 0) return(0L)
  n <- 0L
  while (x > 0) {
    x <- bitwShiftR(x, 1L)
    n <- n + 1L
  }
  n
}

bit_width <- function(v) {
  if (v == 0) return(1L)
  bit_length64(v)
}

checked_add_u64 <- function(a, b) {
  a <- as.numeric(a)
  b <- as.numeric(b)
  if (b > 0) {
    limit <- U64_MAX - b
    if (a > limit) return(list(0, FALSE))
  }
  list(u64_add(a, b), TRUE)
}

checked_add_i64 <- function(a, b) {
  total <- a + b
  if ((b > 0 && total < a) || (b < 0 && total > a)) return(list(0, FALSE))
  list(total, TRUE)
}
