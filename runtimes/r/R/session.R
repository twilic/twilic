UnknownReferencePolicyFailFast <- 0L
UnknownReferencePolicyStatelessRetry <- 1L
DictionaryFallbackFailFast <- 0L
DictionaryFallbackStatelessRetry <- 1L

dictionary_fallback_from_byte <- function(b) {
  if (b == 0L) return(list(DictionaryFallbackFailFast, TRUE))
  if (b == 1L) return(list(DictionaryFallbackStatelessRetry, TRUE))
  list(DictionaryFallbackFailFast, FALSE)
}

default_session_options <- function() {
  list(
    max_base_snapshots = 8L,
    enable_state_patch = TRUE,
    enable_template_batch = TRUE,
    enable_trained_dictionary = TRUE,
    unknown_reference_policy = UnknownReferencePolicyFailFast
  )
}

new_intern_table <- function() {
  env <- new.env(parent = emptyenv())
  env$by_value <- list()
  env$by_id <- list()
  env
}

intern_table_get_id <- function(table, value) {
  id <- table$by_value[[value]]
  if (!is.null(id)) return(list(id, TRUE))
  list(0L, FALSE)
}

intern_table_get_value <- function(table, ref_id) {
  ref_id <- as.integer(ref_id) + 1L
  if (ref_id > length(table$by_id)) return(list("", FALSE))
  list(table$by_id[[ref_id]], TRUE)
}

intern_table_register <- function(table, value) {
  existing <- table$by_value[[value]]
  if (!is.null(existing)) return(existing)
  ref_id <- length(table$by_id)
  table$by_id[[ref_id + 1L]] <- value
  table$by_value[[value]] <- ref_id
  ref_id
}

intern_table_clear <- function(table) {
  table$by_value <- list()
  table$by_id <- list()
  invisible(NULL)
}

shape_key <- function(keys) {
  if (!length(keys)) return("")
  sep <- rawToChar(as.raw(0L))
  Reduce(function(a, b) paste0(a, sep, b), keys)
}

new_null_byte_map <- function() new.env(parent = emptyenv(), hash = TRUE)

shape_table_get_id <- function(table, keys) {
  sk <- shape_key(keys)
  id <- table$by_keys[[sk]]
  if (!is.null(id)) return(list(id, TRUE))
  list(0L, FALSE)
}

shape_table_get_keys <- function(table, ref_id) {
  keys <- table$by_id[[as.character(ref_id)]]
  if (is.null(keys)) return(list(NULL, FALSE))
  list(keys, TRUE)
}

new_shape_table <- function() {
  list(
    by_keys = new_null_byte_map(),
    by_id = new_null_byte_map(),
    observations = new_null_byte_map(),
    next_id = 0L
  )
}

shape_table_register <- function(table, keys) {
  sk <- shape_key(keys)
  existing <- table$by_keys[[sk]]
  if (!is.null(existing)) return(existing)
  ref_id <- table$next_id
  table$next_id <- table$next_id + 1L
  table$by_id[[as.character(ref_id)]] <- keys
  table$by_keys[[sk]] <- ref_id
  ref_id
}

shape_table_register_with_id <- function(table, shape_id, keys) {
  sk <- shape_key(keys)
  existing <- table$by_id[[as.character(shape_id)]]
  if (!is.null(existing) && shape_key(existing) != sk) return(FALSE)
  existing_id <- table$by_keys[[sk]]
  if (!is.null(existing_id) && existing_id != shape_id) return(FALSE)
  table$by_id[[as.character(shape_id)]] <- keys
  table$by_keys[[sk]] <- shape_id
  if (shape_id + 1L > table$next_id) table$next_id <- shape_id + 1L
  TRUE
}

shape_register_with_id <- shape_table_register_with_id

shape_table_observe <- function(table, keys) {
  sk <- shape_key(keys)
  table$observations[[sk]] <- (table$observations[[sk]] %||% 0L) + 1L
  table$observations[[sk]]
}

shape_table_clear <- function(table) {
  table$by_keys <- new_null_byte_map()
  table$by_id <- new_null_byte_map()
  table$observations <- new_null_byte_map()
  table$next_id <- 0L
  table
}

new_session_state_with_options <- function(options) {
  new_session_state(options)
}

new_session_state <- function(options = NULL) {
  opts <- options %||% default_session_options()
  state <- new.env(parent = emptyenv())
  state$options <- opts
  state$key_table <- new_intern_table()
  state$string_table <- new_intern_table()
  state$shape_table <- new_shape_table()
  state$encode_shape_observations <- new_null_byte_map()
  state$base_snapshots <- list()
  state$templates <- new_null_byte_map()
  state$template_columns <- new_null_byte_map()
  state$field_enums <- new_null_byte_map()
  state$dictionaries <- new_null_byte_map()
  state$dictionary_profiles <- new_null_byte_map()
  state$schemas <- new_null_byte_map()
  state$last_schema_id <- NULL
  state$previous_message <- NULL
  state$previous_message_size <- NULL
  state$next_base_id <- 0L
  state$next_template_id <- 0L
  state$next_dictionary_id <- 0L
  state
}

register_base_snapshot <- function(state, base_id, message) {
  filtered <- Filter(function(e) e$id != base_id, state$base_snapshots)
  filtered[[length(filtered) + 1L]] <- list(id = base_id, message = message_clone(message))
  while (length(filtered) > state$options$max_base_snapshots) filtered <- filtered[-1]
  state$base_snapshots <- filtered
  state
}

allocate_base_id <- function(state) {
  id <- state$next_base_id
  state$next_base_id <- state$next_base_id + 1L
  id
}

allocate_template_id <- function(state) {
  id <- state$next_template_id
  state$next_template_id <- state$next_template_id + 1L
  id
}

allocate_dictionary_id <- function(state) {
  id <- state$next_dictionary_id
  state$next_dictionary_id <- state$next_dictionary_id + 1L
  id
}

get_base_snapshot <- function(state, base_id) {
  for (e in state$base_snapshots) {
    if (e$id == base_id) return(list(message_clone(e$message), TRUE))
  }
  list(NULL, FALSE)
}

reset_tables <- function(state) {
  intern_table_clear(state$key_table)
  intern_table_clear(state$string_table)
  state$shape_table <- shape_table_clear(state$shape_table)
  state$encode_shape_observations <- new_null_byte_map()
  state$field_enums <- new_null_byte_map()
  state
}

reset_state <- function(state) {
  state <- reset_tables(state)
  state$base_snapshots <- list()
  state$templates <- new_null_byte_map()
  state$template_columns <- new_null_byte_map()
  state$dictionaries <- new_null_byte_map()
  state$dictionary_profiles <- new_null_byte_map()
  state$schemas <- new_null_byte_map()
  state$last_schema_id <- NULL
  state$previous_message <- NULL
  state$previous_message_size <- NULL
  state$next_base_id <- 0L
  state$next_template_id <- 0L
  state$next_dictionary_id <- 0L
  state
}
