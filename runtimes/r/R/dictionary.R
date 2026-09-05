decode_trained_dictionary_payload <- function(payload) {
  suppressPackageStartupMessages(requireNamespace("bit64", quietly = TRUE))
  reader <- new_reader(payload)
  n <- reader$read_count()
  values <- vector("character", n)
  for (i in seq_len(n)) values[[i]] <- reader$read_string()
  if (!reader$is_eof()) twilic_stop(invalid_data("trained dictionary payload trailing bytes"))
  values
}

encode_trained_dictionary_block <- function(values, dictionary) {
  if (!length(values)) {
    out <- raw_append_byte(new_buffer(), 0L)
    return(list(encode_varuint(0L, out), TRUE, NULL))
  }
  by_value <- setNames(seq_along(dictionary) - 1L, dictionary)
  ids <- numeric()
  for (value in values) {
    ref_id <- by_value[[value]]
    if (is.null(ref_id)) return(list(NULL, FALSE, NULL))
    ids <- c(ids, ref_id)
  }
  raw <- raw_append_byte(new_buffer(), 0L)
  raw <- encode_varuint(length(ids), raw)
  for (ref_id in ids) raw <- encode_varuint(ref_id, raw)
  max_id <- if (length(ids)) max(ids) else 0
  bit_width <- if (max_id == 0) 0L else bit_length64(max_id)
  packed <- pack_fixed_width_u64(ids, bit_width, new_buffer())
  bitpacked <- raw_append_byte(new_buffer(), 1L)
  bitpacked <- encode_varuint(length(ids), bitpacked)
  bitpacked <- raw_append_byte(bitpacked, bit_width)
  bitpacked <- raw_append_bytes(bitpacked, packed)
  if (length(bitpacked) < length(raw)) return(list(bitpacked, TRUE, NULL))
  list(raw, TRUE, NULL)
}

decode_trained_dictionary_block <- function(block, dictionary) {
  reader <- new_reader(block)
  mode <- reader$read_u8()
  n <- reader$read_count()
  if (mode == 0L) {
    ids <- vapply(seq_len(n), function(i) reader$read_varuint(), numeric(1))
  } else if (mode == 1L) {
    bit_width <- reader$read_u8()
    remaining <- length(block) - reader$position()
    packed <- reader$read_exact(remaining)
    ids <- unpack_fixed_width_u64(packed, n, bit_width)
  } else {
    twilic_stop(invalid_data("trained dictionary block mode"))
  }
  if (!reader$is_eof()) twilic_stop(invalid_data("trained dictionary block trailing bytes"))
  out <- character()
  for (ref_id in ids) {
    if (ref_id >= length(dictionary)) twilic_stop(invalid_data("trained dictionary block id"))
    out <- c(out, dictionary[[ref_id + 1L]])
  }
  out
}

wide_u128_mask <- function(width) {
  if (width == 0L) return(list(lo = 0L, hi = 0L))
  if (width >= 64L) return(list(lo = -1L, hi = -1L))
  if (width == 32L) return(list(lo = -1L, hi = 0L))
  if (width < 32L) return(list(lo = bitwShiftL(1L, width) - 1L, hi = 0L))
  list(lo = -1L, hi = bitwShiftL(1L, width - 32L) - 1L)
}

wide_u128_and <- function(a, b) list(lo = bitwAnd(a$lo, b$lo), hi = bitwAnd(a$hi, b$hi))
wide_u128_or <- function(a, b) list(lo = bitwOr(a$lo, b$lo), hi = bitwOr(a$hi, b$hi))
wide_u128_shr <- function(a, n) {
  if (n == 0L) return(a)
  if (n >= 128L) return(list(lo = 0, hi = 0))
  if (n < 64L) {
    return(list(
      lo = bitwAnd(bitwOr(bitwShiftR(a$lo, n), bitwShiftL(a$hi, 64L - n)), bitwShiftL(1L, 64) - 1),
      hi = bitwShiftR(a$hi, n)
    ))
  }
  list(lo = bitwShiftR(a$hi, n - 64L), hi = 0)
}

wide_u128_shl <- function(a, n) {
  if (n == 0L) return(a)
  if (n >= 128L) return(list(lo = 0, hi = 0))
  if (n < 64L) {
    return(list(
      lo = bitwAnd(bitwShiftL(a$lo, n), bitwShiftL(1L, 64) - 1),
      hi = bitwAnd(bitwOr(bitwShiftL(a$hi, n), bitwShiftR(a$lo, 64L - n)), bitwShiftL(1L, 64) - 1)
    ))
  }
  list(lo = 0, hi = bitwAnd(bitwShiftL(a$lo, n - 64L), bitwShiftL(1L, 64) - 1))
}

pack_fixed_width_u64 <- function(values, width, out) {
  if (width > 64L) twilic_stop(invalid_data("fixed-width u64 bit width"))
  if (width == 0L) {
    if (any(values != 0)) twilic_stop(invalid_data("fixed-width u64 value overflow"))
    return(out)
  }
  acc <- list(lo = 0, hi = 0)
  acc_bits <- 0L
  for (value in values) {
    if (width < 64L && width > 0L && value >= wide_u128_mask(width)$lo) {
      twilic_stop(invalid_data("fixed-width u64 value overflow"))
    }
    acc <- wide_u128_or(acc, wide_u128_shl(list(lo = as.numeric(value), hi = 0), acc_bits))
    acc_bits <- acc_bits + width
    while (acc_bits >= 8L) {
      out <- raw_append_byte(out, bitwAnd(acc$lo, 0xFFL))
      acc <- wide_u128_shr(acc, 8L)
      acc_bits <- acc_bits - 8L
    }
  }
  if (acc_bits > 0L) out <- raw_append_byte(out, bitwAnd(acc$lo, 0xFFL))
  out
}

unpack_fixed_width_u64 <- function(data, count, width) {
  if (width > 64L) twilic_stop(invalid_data("fixed-width u64 bit width"))
  if (width == 0L) {
    if (any(as.integer(data) != 0L)) twilic_stop(invalid_data("fixed-width u64 trailing bytes"))
    return(rep(0, count))
  }
  out <- numeric(count)
  acc <- list(lo = 0L, hi = 0L)
  acc_bits <- 0L
  idx <- 1L
  mask <- wide_u128_mask(width)
  for (i in seq_len(count)) {
    while (acc_bits < width) {
      if (idx > length(data)) twilic_stop(invalid_data("fixed-width u64 underflow"))
      acc <- wide_u128_or(acc, wide_u128_shl(list(lo = as.integer(data[idx]), hi = 0L), acc_bits))
      idx <- idx + 1L
      acc_bits <- acc_bits + 8L
    }
    out[i] <- wide_u128_and(acc, mask)$lo
    acc <- wide_u128_shr(acc, width)
    acc_bits <- acc_bits - width
  }
  if (acc$lo != 0L || acc$hi != 0L) twilic_stop(invalid_data("fixed-width u64 trailing bytes"))
  for (j in idx:length(data)) {
    if (as.integer(data[j]) != 0L) twilic_stop(invalid_data("fixed-width u64 trailing bytes"))
  }
  out
}

apply_dictionary_references <- function(state, columns) {
  for (i in seq_along(columns)) {
    column <- columns[[i]]
    if (column$values$kind != ElementTypeSTRING) next
    values <- unlist(column$values$strings)
    if (length(values) < 16L) next
    unique_vals <- unique(values)
    if (length(unique_vals) / length(values) > 0.5) next
    if (!(column$codec %in% c(VectorCodecDICTIONARY, VectorCodecSTRING_REF))) next
    dict_id <- allocate_dictionary_id(state)
    payload <- new_buffer()
    keys <- sort(unique_vals)
    payload <- encode_varuint(length(keys), payload)
    for (item in keys) payload <- encode_string(item, payload)
    profile <- list(
      version = 1L,
      hash = dictionary_payload_hash(payload),
      expires_at = 0L,
      fallback = DictionaryFallbackFailFast
    )
    if (state$options$unknown_reference_policy == UnknownReferencePolicyStatelessRetry) {
      profile$fallback <- DictionaryFallbackStatelessRetry
    }
    state$dictionaries[[as.character(dict_id)]] <- payload
    state$dictionary_profiles[[as.character(dict_id)]] <- profile
    column$dictionary_id <- dict_id
    columns[[i]] <- column
  }
  columns
}

mul32 <- function(x, y) {
  x <- as.numeric(x) %% 4294967296
  y <- as.numeric(y) %% 4294967296
  x0 <- x %% 65536
  x1 <- floor(x / 65536)
  y0 <- y %% 65536
  y1 <- floor(y / 65536)
  z00 <- x0 * y0
  z01 <- x0 * y1
  z10 <- x1 * y0
  z11 <- x1 * y1
  mid <- floor(z00 / 65536) + z01 + z10
  lo <- (z00 %% 65536) + (mid %% 65536) * 65536
  hi <- z11 + floor(mid / 65536) + floor(lo / 4294967296)
  list(lo = lo %% 4294967296, hi = hi %% 4294967296)
}

add64 <- function(lo, hi, dlo = 0, dhi = 0) {
  lo <- lo + dlo
  hi <- hi + dhi + floor(lo / 4294967296)
  list(lo = lo %% 4294967296, hi = hi %% 4294967296)
}

u64_mul_mod_prime <- function(a_lo, a_hi, m) {
  m_lo <- m %% 4294967296
  m_hi <- floor(m / 4294967296)
  t0 <- mul32(a_lo, m_lo)
  t1 <- mul32(a_lo, m_hi)
  t2 <- mul32(a_hi, m_lo)
  r <- add64(t0$lo, t0$hi)
  r <- add64(r$lo, r$hi, dhi = t1$lo)
  add64(r$lo, r$hi, dhi = t2$lo)
}

FNV1A_OFFSET_RAW <- as.raw(c(0x25, 0x34, 0x22, 0x84, 0xe4, 0x9c, 0xf2, 0xcb))

u32_from_raw4 <- function(r) {
  v <- bit64::as.integer64(as.integer(r[[1L]])) +
    bit64::as.integer64(as.integer(r[[2L]])) * bit64::as.integer64(256) +
    bit64::as.integer64(as.integer(r[[3L]])) * bit64::as.integer64(65536) +
    bit64::as.integer64(as.integer(r[[4L]])) * bit64::as.integer64(16777216)
  as.numeric(as.character(v))
}

raw8_to_limbs <- function(raw8) {
  list(lo = u32_from_raw4(raw8[1:4]), hi = u32_from_raw4(raw8[5:8]))
}

limbs_to_raw8 <- function(lo, hi) {
  c(u32_to_le_raw(lo), u32_to_le_raw(hi))
}

fnv1a64 <- function(payload) {
  payload <- as_raw_input(payload)
  h <- FNV1A_OFFSET_RAW
  prime <- 1099511628211
  for (b in as.integer(payload)) {
    h[[1L]] <- as.raw(bitwXor(as.integer(h[[1L]]), b))
    limbs <- raw8_to_limbs(h)
    nxt <- u64_mul_mod_prime(limbs$lo, limbs$hi, prime)
    h <- limbs_to_raw8(nxt$lo, nxt$hi)
  }
  u64_from_le_bytes(h)
}

dictionary_payload_hash <- function(payload) fnv1a64(payload)
