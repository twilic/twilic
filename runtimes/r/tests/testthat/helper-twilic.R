TAG_STRING <- 6L

require_twilic_error_kind <- function(err, kind) {
  if (inherits(err, "twilic_error")) {
    expect_equal(err$kind, kind)
    return(err)
  }
  fail(sprintf("expected twilic_error, got %s", paste(class(err), collapse = "/")))
}

expect_twilic_error <- function(expr, kind, msg = NULL) {
  err <- NULL
  tryCatch(
    expr,
    twilic_error = function(e) {
      err <<- e
    },
    error = function(e) {
      err <<- e
    }
  )
  expect_false(is.null(err), info = "expected twilic error")
  te <- require_twilic_error_kind(err, kind)
  if (!is.null(msg)) expect_equal(te$msg, msg)
  invisible(te)
}

scalar_string_mode <- function(bytes) {
  expect_gte(length(bytes), 3L)
  expect_equal(as.integer(bytes[1]), MessageKindSCALAR)
  expect_equal(as.integer(bytes[2]), TAG_STRING)
  as.integer(bytes[3])
}

equal_key_ref <- function(a, b) {
  identical(a$is_id, b$is_id) && identical(a$id, b$id) && identical(a$literal, b$literal)
}

equal_message <- function(a, b) {
  if (a$kind != b$kind) return(FALSE)
  if (a$kind == MessageKindSCALAR) return(equal(a$scalar, b$scalar))
  if (a$kind == MessageKindARRAY) {
    if (length(a$array) != length(b$array)) return(FALSE)
    return(all(mapply(equal, a$array, b$array, SIMPLIFY = TRUE)))
  }
  if (a$kind == MessageKindMAP) {
    if (length(a$map) != length(b$map)) return(FALSE)
    return(all(mapply(function(e1, e2) {
      equal_key_ref(e1$key, e2$key) && equal(e1$value, e2$value)
    }, a$map, b$map, SIMPLIFY = TRUE)))
  }
  if (a$kind == MessageKindCONTROL_STREAM) {
    return(identical(a$control_stream$codec, b$control_stream$codec) &&
      identical(a$control_stream$payload, b$control_stream$payload))
  }
  identical(serialize(a, NULL), serialize(b, NULL))
}

message_map_entry <- function(key, value) {
  list(key = key_ref_literal(key), value = value_clone(value))
}

control_message <- function(opcode,
                            register_keys = character(),
                            register_shape = NULL,
                            register_strings = character(),
                            promote = NULL,
                            reset_tables = FALSE,
                            reset_state = FALSE) {
  list(
    opcode = opcode,
    register_keys = register_keys,
    register_shape = register_shape,
    register_strings = register_strings,
    promote_string_field_to_enum = promote,
    reset_tables = reset_tables,
    reset_state = reset_state
  )
}

encoded_control_stream_len <- function(stream_codec, payload) {
  msg <- new_message(
    MessageKindCONTROL_STREAM,
    control_stream = list(codec = stream_codec, payload = as_raw_input(payload))
  )
  length(new_twilic_codec()$encode_message(msg))
}

empty_typed_vector_data <- function(kind) {
  list(
    kind = kind,
    bools = list(),
    i64s = list(),
    u64s = list(),
    f64s = list(),
    strings = list(),
    binary = list(),
    values = list()
  )
}

sample_schema <- function() {
  list(
    schema_id = 41L,
    name = "User",
    fields = list(
      list(number = 1L, name = "id", logical_type = "u64", required = TRUE, min = 1000, max = 1100),
      list(number = 2L, name = "name", logical_type = "string", required = TRUE),
      list(number = 3L, name = "score", logical_type = "i64", required = FALSE, min = 0, max = 100)
    )
  )
}

interop_module_root <- function() {
  normalizePath(file.path(testthat::test_path(".."), ".."), winslash = "/", mustWork = TRUE)
}

interop_require_twilic_rust <- function(module_root) {
  if (Sys.which("cargo") == "") {
    skip("cargo not found in PATH")
  }
  env <- Sys.getenv("TWILIC_RUST_ROOT", unset = "")
  sibling <- normalizePath(file.path(module_root, "..", "rust"), mustWork = FALSE)
  found <- (nzchar(env) && file.exists(file.path(env, "Cargo.toml"))) ||
    file.exists(file.path(sibling, "Cargo.toml"))
  if (!found) skip("Rust runtime not found (expected ../rust or TWILIC_RUST_ROOT)")
}

interop_run_process <- function(dir, stdin, command) {
  owd <- getwd()
  on.exit(setwd(owd), add = TRUE)
  setwd(dir)
  out <- system2(
    command[1L],
    args = command[-1L],
    stdout = TRUE,
    stderr = TRUE,
    input = stdin %||% ""
  )
  status <- attr(out, "status")
  if (!is.null(status) && status != 0L) {
    stop(sprintf("command failed (%s): %s\n%s", status, paste(command, collapse = " "), paste(out, collapse = "\n")))
  }
  paste(out, collapse = "\n")
}

replay_codec_state <- function(frames, stop_label) {
  iso <- new_twilic_codec()
  for (frame in frames) {
    if (frame$stream != "codec") next
    if (frame$label == stop_label) break
    if (frame$label == "base_snapshot") {
      iso$decode_message(frame$bytes)
    } else if (interop_expect_codec_value(frame$label)[[2]]) {
      iso$decode_value(frame$bytes)
    }
  }
  iso
}

interop_expect_codec_value <- function(label) {
  if (label == "scalar_string") return(list(new_string("alpha"), TRUE))
  if (startsWith(label, "map_two_fields_")) return(list(new_map(entry("id", new_u64(1)), entry("name", new_string("alice"))), TRUE))
  if (startsWith(label, "map_three_fields_")) {
    return(list(
      new_map(
        entry("id", new_u64(1)),
        entry("name", new_string("alice")),
        entry("role", new_string("admin"))
      ),
      TRUE
    ))
  }
  if (startsWith(label, "bulk_map_")) {
    idx <- as.integer(sub("^bulk_map_", "", label))
    return(list(new_map(entry("id", new_u64(10 + idx)), entry("name", new_string(sprintf("user-%d", idx)))), TRUE))
  }
  list(NULL, FALSE)
}
