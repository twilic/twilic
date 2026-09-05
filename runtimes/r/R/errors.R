
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
