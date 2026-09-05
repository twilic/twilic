encode_varuint <- function(value, out) {
  value <- as.numeric(value)
  if (value < 0x80) {
    return(raw_append_byte(out, as.integer(value)))
  }
  repeat {
    b <- as.integer(u64_and(value, 127))
    value <- u64_shr(value, 7L)
    if (value != 0) b <- b + 0x80L
    out <- raw_append_byte(out, b)
    if (value == 0) break
  }
  out
}

encode_zigzag <- function(value) {
  value <- as.numeric(value)
  bitwXor(value * 2, ifelse(value < 0, -1, 0))
}

decode_zigzag <- function(value) {
  value <- as.numeric(value)
  bitwXor(floor(value / 2), -bitwAnd(value, 1))
}

encode_bytes <- function(data, out) {
  data <- as_raw_input(data)
  out <- encode_varuint(length(data), out)
  raw_append_bytes(out, data)
}

encode_string <- function(value, out) {
  encode_bytes(charToRaw(enc2utf8(value)), out)
}

encode_bitmap <- function(bits, out) {
  out <- encode_varuint(length(bits), out)
  current <- 0L
  for (i in seq_along(bits)) {
    idx <- i - 1L
    if (isTRUE(bits[[i]])) current <- current + bitwShiftL(1L, idx %% 8L)
    if (idx %% 8L == 7L) {
      out <- raw_append_byte(out, current)
      current <- 0L
    }
  }
  if (length(bits) %% 8L != 0L) out <- raw_append_byte(out, current)
  out
}

new_reader <- function(input_data) {
  input <- as_raw_input(input_data)
  st <- new.env(parent = emptyenv())
  st$input <- input
  st$offset <- 1L
  st$depth <- 0L
  st$budget <- min(length(input), 1024) * 1024
  reader <- list()
  reader$claim_output <- function(count) {
    if (length(count) != 1L || !is.finite(count) || count < 0 || count != floor(count) || count > 2^20)
      twilic_stop(invalid_data("decode count limit exceeded"))
    if (count > st$budget / 8) twilic_stop(invalid_data("decode output ratio exceeded"))
    st$budget <- st$budget - count * 8
  }
  reader$read_count <- function(maximum = 2^20) {
    count <- reader$read_varuint()
    if (!is.finite(count) || count < 0 || count > maximum) twilic_stop(invalid_data("decode count limit exceeded"))
    reader$claim_output(count)
    count
  }
  reader$enter_depth <- function() {
    if (st$depth >= 64L) twilic_stop(invalid_data("decode depth limit exceeded"))
    st$depth <- st$depth + 1L
  }
  reader$leave_depth <- function() { st$depth <- st$depth - 1L }
  reader$position <- function() st$offset - 1L
  reader$is_eof <- function() st$offset > length(st$input)
  reader$read_u8 <- function() {
    if (st$offset > length(st$input)) twilic_stop(unexpected_eof())
    b <- as.integer(st$input[st$offset])
    st$offset <- st$offset + 1L
    b
  }
  reader$read_exact <- function(n) {
    if (length(n) != 1L || !is.finite(n) || n < 0 || n != floor(n) || n > length(st$input) - st$offset + 1)
      twilic_stop(unexpected_eof())
    if (n == 0) return(raw())
    n <- as.integer(n)
    end <- st$offset + n - 1L
    slice <- st$input[st$offset:end]
    st$offset <- end + 1L
    slice
  }
  reader$read_varuint <- function() {
    shift <- 0L
    result <- 0
    repeat {
      if (shift >= 64L) twilic_stop(invalid_data("varuint too large"))
      if (st$offset > length(st$input)) twilic_stop(unexpected_eof())
      b <- as.integer(st$input[st$offset])
      st$offset <- st$offset + 1L
      if (shift == 63L && bitwAnd(b, 0x7EL) != 0L) twilic_stop(invalid_data("varuint too large"))
      chunk <- bitwAnd(b, 0x7FL)
      if (shift == 0L) {
        result <- chunk
      } else {
        result <- u64_add(result, u64_shl_small(chunk, shift))
      }
      if (bitwAnd(b, 0x80L) == 0L) return(result)
      shift <- shift + 7L
    }
  }
  reader$read_i64_zigzag <- function() decode_zigzag(reader$read_varuint())
  reader$read_bytes <- function() reader$read_exact(reader$read_varuint())
  reader$read_string <- function() {
    data <- reader$read_exact(reader$read_varuint())
    out <- rawToChar(data)
    if (!validUTF8(out)) twilic_stop(utf8_error())
    out
  }
  reader$read_bitmap <- function() {
    bit_count <- reader$read_count()
    byte_count <- (bit_count + 7L) %/% 8L
    raw <- reader$read_exact(byte_count)
    bits <- vector("list", bit_count)
    for (i in seq_len(bit_count)) {
      bits[[i]] <- bitwAnd(
        bitwShiftR(as.integer(raw[(i - 1L) %/% 8L + 1L]), (i - 1L) %% 8L),
        1L
      ) == 1L
    }
    bits
  }
  reader
}

U64_BYTE_WEIGHTS <- c(
  1, 256, 65536, 16777216, 4294967296, 1099511627776,
  281474976710656, 72057594037927936
)

u64_from_le_bytes <- function(b) {
  sum(as.integer(b[1:8]) * U64_BYTE_WEIGHTS)
}

u32_to_le_raw <- function(v) {
  v <- as.numeric(v) %% 4294967296
  if (v <= 2147483647) {
    return(writeBin(as.integer(v), raw(4), size = 4, endian = "little"))
  }
  h <- bit64::as.integer64(as.character(format(v, scientific = FALSE)))
  lo16 <- as.integer(h %% bit64::as.integer64(65536))
  hi16 <- as.integer(h %/% bit64::as.integer64(65536))
  c(
    writeBin(lo16, raw(2), size = 2, endian = "little"),
    writeBin(hi16, raw(2), size = 2, endian = "little")
  )
}

u64_to_le_bytes <- function(v) {
  if (is.raw(v) && length(v) == 8L) return(v)
  v <- as.numeric(v)
  if (v < 0) twilic_stop(invalid_data("u64 value out of range"))
  lo <- v %% 4294967296
  hi <- floor(v / 4294967296)
  c(u32_to_le_raw(lo), u32_to_le_raw(hi))
}

xor_raw8 <- function(a, b) {
  as.raw(bitwXor(as.integer(a), as.integer(b)))
}

u64_xor <- function(a, b) {
  ba <- if (is.raw(a)) a else u64_to_le_bytes(a)
  bb <- if (is.raw(b)) b else u64_to_le_bytes(b)
  u64_from_le_bytes(xor_raw8(ba, bb))
}

u64_or <- function(a, b) {
  u64_from_le_bytes(as.raw(bitwOr(as.integer(u64_to_le_bytes(a)), as.integer(u64_to_le_bytes(b)))))
}

u64_and <- function(a, b) {
  u64_from_le_bytes(as.raw(bitwAnd(as.integer(u64_to_le_bytes(a)), as.integer(u64_to_le_bytes(b)))))
}

u64_shr <- function(v, n) {
  n <- as.integer(n)
  if (n <= 0L) return(as.numeric(v))
  if (n >= 64L) return(0)
  bits <- u64_to_bits(v)
  u64_from_bits(c(bits[(n + 1L):64], rep(0L, n)))
}

u64_mask_low <- function(width) {
  width <- as.integer(width)
  if (width >= 64L) return(18446744073709551615)
  if (width <= 0L) return(0)
  u64_from_bits(c(rep(1L, width), rep(0L, 64L - width)))
}

u64_to_bits <- function(v) {
  b <- as.integer(u64_to_le_bytes(v))
  bits <- integer(64)
  for (i in seq_len(8)) {
    byte <- b[i]
    base <- (i - 1L) * 8L
    for (j in 0:7) bits[base + j + 1L] <- bitwAnd(bitwShiftR(byte, j), 1L)
  }
  bits
}

bits_to_raw8 <- function(bits) {
  b <- raw(8)
  for (i in 1:8) {
    byte <- 0L
    for (j in 0:7) {
      if (bits[[(i - 1L) * 8L + j + 1L]] != 0L) byte <- byte + bitwShiftL(1L, j)
    }
    b[i] <- as.raw(byte)
  }
  b
}

raw8_to_bits <- function(b) {
  bits <- integer(64)
  for (i in 1:8) {
    byte <- as.integer(b[i])
    for (j in 0:7) bits[[(i - 1L) * 8L + j + 1L]] <- bitwAnd(bitwShiftR(byte, j), 1L)
  }
  bits
}

u64_from_bits <- function(bits) {
  b <- raw(8)
  for (i in 1:8) {
    byte <- 0L
    for (j in 0:7) {
      if (bits[[(i - 1L) * 8L + j + 1L]] != 0L) byte <- byte + bitwShiftL(1L, j)
    }
    b[i] <- as.raw(byte)
  }
  u64_from_le_bytes(b)
}

u64_add <- function(a, b) {
  a <- as.numeric(a)
  b <- as.numeric(b)
  alo <- a %% 4294967296
  ahi <- floor(a / 4294967296)
  blo <- b %% 4294967296
  bhi <- floor(b / 4294967296)
  lo <- alo + blo
  carry <- floor(lo / 4294967296)
  lo <- lo %% 4294967296
  hi <- ahi + bhi + carry
  hi * 4294967296 + lo
}

u64_shl_small <- function(v, bits) {
  bits <- as.integer(bits)
  if (bits <= 0L) return(as.numeric(v))
  if (bits >= 64L) return(0)
  b <- u64_to_bits(v)
  u64_from_bits(c(rep(0L, bits), b[1:(64L - bits)]))
}

leading_zeros64 <- function(x) {
  if (x == 0) return(64L)
  bits <- u64_to_bits(x)
  for (i in 64:1) {
    if (bits[[i]]) return(64L - i)
  }
  64L
}

trailing_zeros64 <- function(x) {
  if (x == 0) return(64L)
  bits <- u64_to_bits(x)
  for (i in seq_len(64)) {
    if (bits[[i]]) return(i - 1L)
  }
  64L
}

read_u64_le <- function(reader) {
  u64_from_le_bytes(reader$read_exact(8L))
}

read_f64_le <- function(reader) {
  readBin(reader$read_exact(8L), what = double(), size = 8, endian = "little")
}

append_u64_le <- function(out, v) {
  raw_append_bytes(out, u64_to_le_bytes(v))
}

append_f64_le <- function(out, v) {
  raw_append_bytes(out, writeBin(as.double(v), raw(8), size = 8, endian = "little"))
}
