# Rust interop fixtures (ported from twilic-ruby interop_fixtures.rb)

interop_id_name_map <- function(id, name) {
  new_map(entry("id", new_u64(id)), entry("name", new_string(name)))
}

interop_id_name_role_map <- function(id, name, role) {
  new_map(
    entry("id", new_u64(id)),
    entry("name", new_string(name)),
    entry("role", new_string(role))
  )
}

interop_make_i64_array <- function(length, start) {
  lapply(seq_len(length) - 1L, function(i) new_i64(start + i))
}

interop_make_user_rows <- function(names) {
  lapply(seq_along(names), function(i) {
    new_map(entry("id", new_u64(i)), entry("name", new_string(names[[i]])))
  })
}

interop_bitpack_control_payload <- function() {
  as.raw(vapply(seq_len(512) - 1L, function(i) if (i %% 2L == 0L) 0L else 1L, integer(1L)))
}

interop_huffman_control_payload <- function() {
  as.raw(rep(7L, 512L))
}

interop_fse_control_payload <- function() {
  as.raw((seq_len(512) - 1L) %% 4L)
}

emit_interop_fixtures <- function(out = "") {
  codec <- new_twilic_codec()
  lines <- character()

  alpha <- new_string("alpha")
  lines <- c(lines, emit_interop_value_line("codec", "scalar_string", codec, alpha))

  map_two <- interop_id_name_map(1, "alice")
  lines <- c(lines, emit_interop_value_line("codec", "map_two_fields_first", codec, map_two))
  reset_encode_shape_observation(codec, c("id", "name"))
  lines <- c(lines, emit_interop_value_line("codec", "map_two_fields_second", codec, map_two))

  map_three <- interop_id_name_role_map(1, "alice", "admin")
  lines <- c(lines, emit_interop_value_line("codec", "map_three_fields_first", codec, map_three))
  reset_encode_shape_observation(codec, c("id", "name", "role"))
  lines <- c(lines, emit_interop_value_line("codec", "map_three_fields_second", codec, map_three))

  for (i in 0:7) {
    dynamic <- interop_id_name_map(10 + i, sprintf("user-%d", i))
    lines <- c(lines, emit_interop_value_line("codec", sprintf("bulk_map_%d", i), codec, dynamic))
  }

  scalar <- new_i64(42)
  base_snapshot <- new_message(
    MessageKindBASE_SNAPSHOT,
    base_snapshot = list(
      base_id = 77L,
      schema_or_shape_ref = 0L,
      payload = new_message(MessageKindSCALAR, scalar = scalar)
    )
  )
  lines <- c(lines, emit_interop_message_line("codec", "base_snapshot", codec, base_snapshot))

  enc <- new_session_encoder(default_session_options())
  base_array <- new_array(interop_make_i64_array(100, 0))
  lines <- c(lines, emit_interop_frame_line("session", "session_base_array", enc$encode(base_array)))

  one_change_arr <- interop_make_i64_array(100, 0)
  one_change_arr[[1]] <- new_i64(10000)
  lines <- c(lines, emit_interop_frame_line("session", "session_patch_one_change", enc$encode_patch(new_array(one_change_arr))))

  for (step in 0:3) {
    iter_arr <- interop_make_i64_array(100, 0)
    iter_arr[[step + 1L]] <- new_i64(20000 + step)
    lines <- c(lines, emit_interop_frame_line("session", sprintf("session_patch_iter_%d", step), enc$encode_patch(new_array(iter_arr))))
  }

  many_arr <- interop_make_i64_array(100, 0)
  for (idx in 0:11) many_arr[[idx + 1L]] <- new_i64(10000 + idx)
  lines <- c(lines, emit_interop_frame_line("session", "session_patch_many_changes", enc$encode_patch(new_array(many_arr))))

  rows1 <- interop_make_user_rows(c("a", "b", "c", "d"))
  lines <- c(lines, emit_interop_frame_line("session", "session_micro_batch_first", enc$encode_micro_batch(rows1)))
  rows2 <- interop_make_user_rows(c("aa", "bb", "cc", "dd"))
  lines <- c(lines, emit_interop_frame_line("session", "session_micro_batch_second", enc$encode_micro_batch(rows2)))

  text <- paste0(lines, collapse = "\n")
  if (nzchar(out)) cat(text, file = out)
  invisible(text)
}

emit_interop_value_line <- function(stream, label, codec, value) {
  emit_interop_frame_line(stream, label, codec$encode_value(value))
}

emit_interop_message_line <- function(stream, label, codec, message) {
  emit_interop_frame_line(stream, label, codec$encode_message(message))
}

emit_interop_frame_line <- function(stream, label, bytes) {
  sprintf("%s|%s|%s", stream, label, paste0(sprintf("%02x", as.integer(bytes)), collapse = ""))
}

parse_interop_frames <- function(input) {
  frames <- list()
  lines <- strsplit(input, "\n", fixed = TRUE)[[1]]
  for (line_no in seq_along(lines)) {
    line <- trimws(lines[[line_no]])
    if (!nzchar(line)) next
    parts <- parse_interop_frame_line(line)
    bytes <- decode_interop_hex(parts[[3]])
    frames[[length(frames) + 1L]] <- list(
      stream = parts[[1]],
      label = parts[[2]],
      hex = parts[[3]],
      bytes = bytes
    )
  }
  if (!length(frames)) stop("no fixture frames found", call. = FALSE)
  frames
}

parse_interop_frame_line <- function(line) {
  first <- regexpr("|", line, fixed = TRUE)[1]
  if (first <= 1) stop("invalid frame", call. = FALSE)
  rest <- substring(line, first + 1L)
  second <- regexpr("|", rest, fixed = TRUE)[1]
  if (second <= 1) stop("invalid frame", call. = FALSE)
  list(
    substring(line, 1L, first - 1L),
    substring(rest, 1L, second - 1L),
    substring(rest, second + 1L)
  )
}

decode_interop_hex <- function(hex) {
  if (nchar(hex) %% 2L != 0L) stop("invalid hex length", call. = FALSE)
  chars <- strsplit(hex, "")[[1]]
  pairs <- matrix(chars, ncol = 2, byrow = TRUE)
  as.raw(apply(pairs, 1, function(p) (interop_hex_nibble(p[[1]]) * 16L) + interop_hex_nibble(p[[2]])))
}

interop_hex_nibble <- function(ch) {
  if (ch >= "0" && ch <= "9") return(as.integer(ch))
  if (ch >= "a" && ch <= "f") return(as.integer(charToRaw(ch)) - as.integer(charToRaw("a")) + 10L)
  if (ch >= "A" && ch <= "F") return(as.integer(charToRaw(ch)) - as.integer(charToRaw("A")) + 10L)
  stop("invalid hex", call. = FALSE)
}

interop_expect_codec_value <- function(label) {
  if (label == "scalar_string") return(list(new_string("alpha"), TRUE))
  if (startsWith(label, "map_two_fields_")) return(list(interop_id_name_map(1, "alice"), TRUE))
  if (startsWith(label, "map_three_fields_")) return(list(interop_id_name_role_map(1, "alice", "admin"), TRUE))
  if (startsWith(label, "bulk_map_")) {
    idx <- as.integer(sub("^bulk_map_", "", label))
    return(list(interop_id_name_map(10 + idx, sprintf("user-%d", idx)), TRUE))
  }
  list(NULL, FALSE)
}

interop_expect_control_stream_codec <- function(label) {
  if (label == "control_stream_bitpack") return(list(ControlStreamCodecBITPACK, TRUE))
  if (label == "control_stream_huffman") return(list(ControlStreamCodecHUFFMAN, TRUE))
  if (label == "control_stream_fse") return(list(ControlStreamCodecFSE, TRUE))
  list(NULL, FALSE)
}

interop_expect_control_payload <- function(label) {
  if (label == "control_stream_bitpack") return(list(interop_bitpack_control_payload(), TRUE))
  if (label == "control_stream_huffman") return(list(interop_huffman_control_payload(), TRUE))
  if (label == "control_stream_fse") return(list(interop_fse_control_payload(), TRUE))
  list(NULL, FALSE)
}

assert_interop_codec_decode <- function(codec, label, frame) {
  if (label == "base_snapshot") {
    msg <- codec$decode_message(frame)
    if (msg$kind != MessageKindBASE_SNAPSHOT || is.null(msg$base_snapshot)) {
      stop("expected base snapshot message", call. = FALSE)
    }
    if (msg$base_snapshot$base_id != 77L) stop(sprintf("base_id: got %s want 77", msg$base_snapshot$base_id), call. = FALSE)
    payload <- msg$base_snapshot$payload
    if (payload$kind != MessageKindSCALAR || is.null(payload$scalar) ||
        payload$scalar$kind != ValueKindI64 || payload$scalar$i64 != 42) {
      stop("base snapshot payload mismatch", call. = FALSE)
    }
    return(invisible(NULL))
  }
  ctrl <- interop_expect_control_payload(label)
  if (ctrl[[2]]) {
    msg <- codec$decode_message(frame)
    if (msg$kind != MessageKindCONTROL_STREAM || is.null(msg$control_stream)) {
      stop("expected control stream message", call. = FALSE)
    }
    if (!length(msg$control_stream$payload)) {
      stop(sprintf("control stream payload empty for %s", label), call. = FALSE)
    }
    want_codec <- interop_expect_control_stream_codec(label)
    if (want_codec[[2]] && msg$control_stream$codec != want_codec[[1]]) {
      stop(sprintf("control stream codec mismatch for %s", label), call. = FALSE)
    }
    return(invisible(NULL))
  }
  exp <- interop_expect_codec_value(label)
  if (!exp[[2]]) stop(sprintf("no codec expectation for label %s", label), call. = FALSE)
  got <- codec$decode_value(frame)
  if (!equal(got, exp[[1]])) stop(sprintf("decoded value mismatch for %s", label), call. = FALSE)
  invisible(NULL)
}

assert_interop_session_decode <- function(codec, label, frame) {
  if (label == "session_base_array") {
    got <- codec$decode_value(frame)
    want <- new_array(interop_make_i64_array(100, 0))
    if (!equal(got, want)) stop("session_base_array value mismatch", call. = FALSE)
    return(invisible(NULL))
  }
  if (startsWith(label, "session_patch")) {
    codec$decode_message(frame)
    return(invisible(NULL))
  }
  if (startsWith(label, "session_micro_batch")) {
    msg <- codec$decode_message(frame)
    if (msg$kind != MessageKindTEMPLATE_BATCH || is.null(msg$template_batch)) {
      stop(sprintf("expected template batch message, got %s", msg$kind), call. = FALSE)
    }
    if (msg$template_batch$count != 4L) {
      stop(sprintf("expected 4 rows, got %s", msg$template_batch$count), call. = FALSE)
    }
    return(invisible(NULL))
  }
  stop(sprintf("no session expectation for label %s", label), call. = FALSE)
}
