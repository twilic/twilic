# Public API for the twilic R package

#' @keywords internal
.onLoad <- function(libname, pkgname) {
  invisible(NULL)
}

encode <- function(value) encode_v2(value)
decode <- function(bytes) decode_v2(bytes)
encode_with_schema <- function(schema, value) {
  enc <- new_session_encoder(default_session_options())
  session_encoder_encode_with_schema(enc, schema, value)
}
encode_batch <- function(values) {
  enc <- new_session_encoder(default_session_options())
  session_encoder_encode_batch(enc, values)
}
