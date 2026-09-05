#!/usr/bin/env python3
"""Generate R/codec.R from twilic-python codec.py."""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python" / "src" / "twilic" / "codec.py"
OUT = Path(__file__).resolve().parents[1] / "R" / "codec.R"

HEADER = """
SIMPLE8B_SLOTS <- list(
  c(60L, 1L), c(30L, 2L), c(20L, 3L), c(15L, 4L), c(12L, 5L), c(10L, 6L),
  c(8L, 7L), c(7L, 8L), c(6L, 10L), c(5L, 12L), c(4L, 15L), c(3L, 20L),
  c(2L, 30L), c(1L, 60L)
)
U64_MAX <- 18446744073709551615
"""

# Hand-ported from twilic-python/src/twilic/codec.py — keep in sync with Python behavior.
BODY = r'''
encode_i64_vector <- function(values, codec, out) {
  switch(
    as.integer(codec) + 1L,
    encode_i64_rle(values, out),
    encode_i64_direct_bitpack(values, out),
    encode_i64_direct_bitpack(delta(values), out),
    {
      if (!length(values)) return(encode_varuint(0, out))
      min_value <- min(values)
      out <- encode_varuint(encode_zigzag(min_value), out)
      encode_i64_direct_bitpack(values - min_value, out)
    },
    {
      d <- delta(values)
      if (!length(d)) return(encode_varuint(0, out))
      min_value <- min(d)
      out <- encode_varuint(encode_zigzag(min_value), out)
      encode_i64_direct_bitpack(d - min_value, out)
    },
    encode_i64_delta_delta(values, out),
    encode_i64_patched_for(values, out),
    encode_i64_simple8b(values, out),
    encode_i64_plain(values, out),
    encode_i64_plain(values, out),
    encode_i64_plain(values, out),
    encode_i64_plain(values, out),
    encode_i64_plain(values, out)
  )
}

decode_i64_vector <- function(reader, codec) {
  switch(
    as.integer(codec) + 1L,
    decode_i64_rle(reader),
    decode_i64_direct_bitpack(reader),
    undelta(decode_i64_direct_bitpack(reader)),
    {
      min_value <- decode_zigzag(reader$read_varuint())
      if (reader$is_eof()) return(integer())
      decode_i64_direct_bitpack(reader) + min_value
    },
    {
      min_value <- decode_zigzag(reader$read_varuint())
      if (reader$is_eof()) return(integer())
      undelta(decode_i64_direct_bitpack(reader) + min_value)
    },
    decode_i64_delta_delta(reader),
    decode_i64_patched_for(reader),
    decode_i64_simple8b(reader),
    decode_i64_plain(reader),
    decode_i64_plain(reader),
    decode_i64_plain(reader),
    decode_i64_plain(reader),
    decode_i64_plain(reader),
    twilic_stop(invalid_data("unsupported vector codec"))
  )
}

encode_u64_vector <- function(values, codec, out) {
  switch(
    as.integer(codec) + 1L,
    encode_u64_rle(values, out),
    encode_u64_direct_bitpack(values, out),
    {
      if (!length(values)) return(encode_varuint(0, out))
      min_value <- min(values)
      out <- encode_varuint(min_value, out)
      encode_u64_direct_bitpack(values - min_value, out)
    },
    encode_u64_plain(values, out),
    encode_u64_simple8b(values, out),
    encode_u64_plain(values, out),
    encode_u64_plain(values, out),
    encode_u64_plain(values, out),
    encode_u64_plain(values, out),
    encode_u64_plain(values, out),
    encode_u64_plain(values, out),
    encode_u64_plain(values, out),
    encode_u64_plain(values, out)
  )
}

decode_u64_vector <- function(reader, codec) {
  switch(
    as.integer(codec) + 1L,
    decode_u64_rle(reader),
    decode_u64_direct_bitpack(reader),
    {
      min_value <- reader$read_varuint()
      if (reader$is_eof()) return(numeric())
      shifted <- decode_u64_direct_bitpack(reader)
      out <- numeric(length(shifted))
      for (i in seq_along(shifted)) {
        total <- shifted[i] + min_value
        if (total > U64_MAX) twilic_stop(invalid_data("u64 FOR overflow"))
        out[i] <- total
      }
      out
    },
    decode_u64_plain(reader),
    decode_u64_simple8b(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    decode_u64_plain(reader),
    twilic_stop(invalid_data("unsupported vector codec"))
  )
}

encode_f64_vector <- function(values, codec, out) {
  if (codec == VectorCodecXorFloat) return(encode_xor_float(values, out))
  out <- encode_varuint(length(values), out)
  for (v in values) out <- append_f64_le(out, v)
  out
}

decode_f64_vector <- function(reader, codec) {
  if (codec == VectorCodecXorFloat) return(decode_xor_float(reader))
  length <- reader$read_varuint()
  vapply(seq_len(length), function(i) read_f64_le(reader), numeric(1))
}

encode_u64_plain <- function(values, out) {
  out <- encode_varuint(length(values), out)
  for (value in values) out <- encode_varuint(value, out)
  out
}

decode_u64_plain <- function(reader) {
  length <- reader$read_varuint()
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
  runs_len <- reader$read_varuint()
  out <- numeric()
  for (i in seq_len(runs_len)) {
    value <- reader$read_varuint()
    count <- reader$read_varuint()
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
  length <- reader$read_varuint()
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
  length <- reader$read_varuint()
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

encode_u64_simple8b_inner <- function(values, out) {
  out <- encode_varuint(length(values), out)
  if (!length(values)) return(out)
  max_value <- max(values)
  if (max_value > (bitwShiftL(1L, 60) - 1L)) {
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
      word <- if (take == 240L) 0 else bitwShiftL(1L, 60)
      out <- append_u64_le(out, word)
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
      max_encodable <- if (slot_width == 64L) U64_MAX else bitwShiftL(1L, slot_width) - 1L
      if (any(slice > max_encodable)) next
      selector <- selector_idx + 1L
      payload <- 0
      shift <- 0L
      for (value in slice) {
        payload <- payload + bitwShiftL(as.numeric(value), shift)
        shift <- shift + slot_width
      }
      word <- bitwOr(bitwShiftL(selector, 60), payload)
      out <- append_u64_le(out, word)
      idx <- idx + count
      packed <- TRUE
      break
    }
    if (!packed) {
      selector <- 15L
      word <- bitwOr(bitwShiftL(selector, 60), bitwAnd(values[idx], bitwShiftL(1L, 60) - 1L))
      out <- append_u64_le(out, word)
      idx <- idx + 1L
    }
  }
  out
}

decode_u64_simple8b_inner <- function(reader) {
  length <- reader$read_varuint()
  if (length == 0L) return(numeric())
  mode <- reader$read_u8()
  if (mode == 0L) return(vapply(seq_len(length), function(i) reader$read_varuint(), numeric(1)))
  if (mode != 1L) twilic_stop(invalid_data("simple8b mode"))
  out <- numeric()
  while (length(out) < length) {
    packed <- read_u64_le(reader)
    selector <- bitwShiftR(packed, 60)
    payload <- bitwAnd(packed, bitwShiftL(1L, 60) - 1L)
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
      mask <- if (width == 64L) U64_MAX else bitwShiftL(1L, width) - 1L
      shift <- 0L
      remain <- length - length(out)
      limit <- min(count, remain)
      for (i in seq_len(limit)) {
        out <- c(out, bitwAnd(bitwShiftR(payload, shift), mask))
        shift <- shift + width
      }
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
  runs_len <- reader$read_varuint()
  out <- numeric()
  for (i in seq_len(runs_len)) {
    value <- decode_zigzag(reader$read_varuint())
    count <- reader$read_varuint()
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
  length <- reader$read_varuint()
  if (length == 0L) return(integer())
  base <- decode_zigzag(reader$read_varuint())
  reader$read_u8()
  values <- vapply(seq_len(length), function(i) reader$read_varuint(), numeric(1))
  patch_count <- reader$read_varuint()
  for (i in seq_len(patch_count)) {
    pos <- reader$read_varuint()
    patch <- reader$read_varuint()
    if (pos < length(values)) values[pos + 1L] <- patch
  }
  values + base
}

leading_zeros64 <- function(x) {
  if (x == 0) return(64L)
  64L - bit_length64(x)
}

trailing_zeros64 <- function(x) {
  if (x == 0) return(64L)
  bit_length64(bitwAnd(x, bitwAnd(-x, U64_MAX))) - 1L
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

encode_xor_float <- function(values, out) {
  out <- encode_varuint(length(values), out)
  if (!length(values)) return(out)
  first_bits <- f64_to_u64(values[[1]])
  out <- append_u64_le(out, first_bits)
  prev <- first_bits
  if (length(values) > 1L) {
    for (value in values[-1]) {
      bits_value <- f64_to_u64(value)
      x <- bitwXor(prev, bits_value)
      if (x == 0) {
        out <- raw_append_byte(out, 0L)
      } else {
        leading <- leading_zeros64(x)
        trailing <- trailing_zeros64(x)
        width <- 64L - (leading + trailing)
        out <- encode_varuint(leading, out)
        out <- encode_varuint(trailing, out)
        out <- encode_varuint(width, out)
        payload <- if (width == 64L) x else bitwAnd(bitwShiftR(x, trailing), bitwShiftL(1L, width) - 1L)
        out <- encode_varuint(payload, out)
      }
      prev <- bits_value
    }
  }
  out
}

decode_xor_float <- function(reader) {
  length <- reader$read_varuint()
  if (length == 0L) return(numeric())
  first_bits <- read_u64_le(reader)
  out <- list(u64_to_f64(first_bits))
  prev <- first_bits
  if (length > 1L) {
    for (i in 2:length) {
      flag <- reader$read_u8()
      bits_value <- prev
      if (flag != 0L) {
        leading <- reader$read_varuint()
        trailing <- reader$read_varuint()
        width <- reader$read_varuint()
        payload <- reader$read_varuint()
        if (leading + trailing + width > 64L) twilic_stop(invalid_data("xor-float bit widths"))
        x <- if (width == 64L) payload else bitwShiftL(payload, trailing)
        bits_value <- bitwXor(prev, x)
      }
      out[[length(out) + 1L]] <- u64_to_f64(bits_value)
      prev <- bits_value
    }
  }
  unlist(out)
}

f64_to_u64 <- function(v) {
  readBin(writeBin(as.double(v), raw(8), size = 8, endian = "little"), what = numeric(), size = 8, endian = "little")
}

u64_to_f64 <- function(u) {
  readBin(writeBin(as.numeric(u), raw(8), size = 8, endian = "little"), what = double(), size = 8, endian = "little")
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
  length <- reader$read_varuint()
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
  length <- reader$read_varuint()
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

bit_width <- function(v) {
  if (v == 0) return(1L)
  bit_length64(v)
}

checked_add_u64 <- function(a, b) {
  total <- a + b
  if (total > U64_MAX) return(list(0, FALSE))
  list(total, TRUE)
}

checked_add_i64 <- function(a, b) {
  total <- a + b
  if ((b > 0 && total < a) || (b < 0 && total > a)) return(list(0, FALSE))
  list(total, TRUE)
}
'''


def main() -> None:
    OUT.write_text(HEADER + BODY)
    print("wrote", OUT, len(OUT.read_text().splitlines()), "lines")


if __name__ == "__main__":
    main()
