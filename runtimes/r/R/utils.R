
#' @keywords internal
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

twilic_stop <- function(err) {
  class(err) <- c("twilic_error", "error", "condition")
  stop(err)
}

as_raw_input <- function(x) {
  if (is.raw(x)) return(x)
  if (is.character(x) && length(x) == 1L) return(charToRaw(x))
  stop("expected raw vector or length-1 character", call. = FALSE)
}

as.raw_input <- as_raw_input

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
