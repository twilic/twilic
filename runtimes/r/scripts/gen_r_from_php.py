#!/usr/bin/env python3
"""Generate twilic-r R sources from twilic-php (behavior reference)."""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

PHP_ROOT = Path(__file__).resolve().parents[2] / "php" / "src" / "Twilic"
R_ROOT = Path(__file__).resolve().parents[1] / "R"


def write(name: str, body: str) -> None:
    path = R_ROOT / name
    path.write_text(body.rstrip() + "\n")
    print(f"wrote {path} ({len(path.read_text().splitlines())} lines)")


def utils_r() -> str:
    return textwrap.dedent(
        """
        #' @keywords internal
        `%||%` <- function(x, y) {
          if (is.null(x)) y else x
        }

        twilic_stop <- function(err) {
          stop(err$message, call. = FALSE, twilic = err)
        }

        as_raw_input <- function(x) {
          if (is.raw(x)) return(x)
          if (is.character(x) && length(x) == 1L) return(charToRaw(x))
          stop("expected raw vector or length-1 character", call. = FALSE)
        }

        raw_append_byte <- function(buf, byte) {
          c(buf, as.raw(byte %% 256L))
        }

        raw_append_bytes <- function(buf, bytes) {
          c(buf, as.raw(bytes))
        }

        new_buffer <- function() {
          raw(0)
        }

        buffer_bytes <- function(buf) {
          buf
        }
        """
    )


def errors_r() -> str:
    return textwrap.dedent(
        """
        ERR_UNEXPECTED_EOF <- 0L
        ERR_INVALID_KIND <- 1L
        ERR_INVALID_TAG <- 2L
        ERR_INVALID_DATA <- 3L
        ERR_UTF8 <- 4L
        ERR_UNKNOWN_REFERENCE <- 5L
        ERR_STATELESS_RETRY_REQUIRED <- 6L

        twilic_error <- function(kind, byte = 0L, msg = "", ref_kind = "", ref_id = 0L) {
          message <- switch(
            as.integer(kind) + 1L,
            "unexpected end of input",
            sprintf("invalid message kind: 0x%02x", byte),
            sprintf("invalid value tag: 0x%02x", byte),
            paste0("invalid data: ", msg),
            "utf8 decode error",
            sprintf("unknown reference: %s=%s", ref_kind, ref_id),
            sprintf("stateless retry required for reference: %s=%s", ref_kind, ref_id),
            "twilic error"
          )
          structure(
            list(kind = kind, byte = byte, msg = msg, ref_kind = ref_kind, ref_id = ref_id, message = message),
            class = c("twilic_error", "error", "condition")
          )
        }

        unexpected_eof <- function() twilic_error(ERR_UNEXPECTED_EOF)
        invalid_kind <- function(b) twilic_error(ERR_INVALID_KIND, byte = as.integer(b))
        invalid_tag <- function(b) twilic_error(ERR_INVALID_TAG, byte = as.integer(b))
        invalid_data <- function(msg) twilic_error(ERR_INVALID_DATA, msg = msg)
        utf8_error <- function() twilic_error(ERR_UTF8)
        unknown_reference <- function(kind, ref_id) {
          twilic_error(ERR_UNKNOWN_REFERENCE, ref_kind = kind, ref_id = as.numeric(ref_id))
        }
        stateless_retry_required <- function(kind, ref_id) {
          twilic_error(ERR_STATELESS_RETRY_REQUIRED, ref_kind = kind, ref_id = as.numeric(ref_id))
        }

        is_twilic_error <- function(x) inherits(x, "twilic_error")
        is_stateless_retry <- function(err) is_twilic_error(err) && err$kind == ERR_STATELESS_RETRY_REQUIRED
        is_unknown_reference <- function(err) is_twilic_error(err) && err$kind == ERR_UNKNOWN_REFERENCE
        """
    )


def wire_r() -> str:
    return textwrap.dedent(
        """
        encode_varuint <- function(value, out) {
          value <- as.numeric(value)
          if (value < 0x80) {
            return(raw_append_byte(out, as.integer(value)))
          }
          repeat {
            b <- as.integer(bitwAnd(value, 0x7F))
            value <- floor(value / 128)
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
          list(
            position = function() st$offset - 1L,
            is_eof = function() st$offset > length(st$input),
            read_u8 = function() {
              if (st$offset > length(st$input)) twilic_stop(unexpected_eof())
              b <- as.integer(st$input[st$offset])
              st$offset <- st$offset + 1L
              b
            },
            read_exact = function(n) {
              n <- as.integer(n)
              end <- st$offset + n - 1L
              if (end > length(st$input)) twilic_stop(unexpected_eof())
              slice <- st$input[st$offset:end]
              st$offset <- end + 1L
              slice
            },
            read_varuint = function() {
              shift <- 0L
              result <- 0
              repeat {
                if (shift >= 64L) twilic_stop(invalid_data("varuint too large"))
                b <- as.integer(st$input[st$offset])
                st$offset <- st$offset + 1L
                if (st$offset - 1L > length(st$input)) twilic_stop(unexpected_eof())
                b <- as.integer(st$input[st$offset - 1L])
                result <- result + bitwShiftL(bitwAnd(b, 0x7FL), shift)
                if (bitwAnd(b, 0x80L) == 0L) return(result)
                shift <- shift + 7L
              }
            },
            read_i64_zigzag = function() decode_zigzag(read_varuint()),
            read_bytes = function() read_exact(read_varuint()),
            read_string = function() {
              data <- read_exact(read_varuint())
              rawToChar(data, multiple = TRUE)
              out <- rawToChar(data)
              if (is.na(out) || !validUTF8(out)) twilic_stop(utf8_error())
              out
            },
            read_bitmap = function() {
              bit_count <- read_varuint()
              byte_count <- (bit_count + 7L) %/% 8L
              raw <- read_exact(byte_count)
              bits <- vector("list", bit_count)
              for (i in seq_len(bit_count)) {
                bits[[i]] <- bitwAnd(bitwShiftR(as.integer(raw[(i - 1L) %/% 8L + 1L]), (i - 1L) %% 8L), 1L) == 1L
              }
              bits
            }
          )
        }

        read_u64_le <- function(reader) {
          b <- reader$read_exact(8L)
          lo <- readBin(b[1:4], what = integer(), size = 4, endian = "little", signed = FALSE)
          hi <- readBin(b[5:8], what = integer(), size = 4, endian = "little", signed = FALSE)
          lo + hi * 4294967296
        }

        read_f64_le <- function(reader) {
          readBin(reader$read_exact(8L), what = double(), size = 8, endian = "little")
        }

        append_u64_le <- function(out, v) {
          v <- as.numeric(v)
          lo <- as.integer(v %% 4294967296)
          hi <- as.integer(floor(v / 4294967296))
          raw_append_bytes(out, as.raw(c(
            writeBin(lo, raw(4), size = 4, endian = "little"),
            writeBin(hi, raw(4), size = 4, endian = "little")
          )))
        }

        append_f64_le <- function(out, v) {
          raw_append_bytes(out, writeBin(as.double(v), raw(8), size = 8, endian = "little"))
        }
        """
    )


def main() -> None:
    R_ROOT.mkdir(parents=True, exist_ok=True)
    write("utils.R", utils_r())
    write("errors.R", errors_r())
    write("wire.R", wire_r())
    print("partial generation complete — run full port script for remaining modules")


if __name__ == "__main__":
    main()
