#!/usr/bin/env python3
"""Generate session.R, dictionary.R, v2.R from twilic-python (mechanical port)."""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python" / "src" / "twilic"
OUT = Path(__file__).resolve().parents[1] / "R"


def py_to_r_block(py: str) -> str:
    r = py
    r = re.sub(r"^from \..*|^import .*", "", r, flags=re.M)
    r = r.replace("bytearray()", "new_buffer()")
    r = r.replace("bytearray", "raw")
    r = r.replace("bytes", "raw")
    r = r.replace("True", "TRUE")
    r = r.replace("False", "FALSE")
    r = r.replace("None", "NULL")
    r = re.sub(r"def (\w+)\(", r"\1 <- function(", r)
    r = re.sub(r"self\.", "", r)
    r = re.sub(r"raise (\w+)\(", r"twilic_stop(\1(", r)
    r = re.sub(r"\.read_(\w+)\(", r"$read_\1(", r)
    r = re.sub(r"\.is_eof\(\)", r"$is_eof()", r)
    r = re.sub(r"\.append\(", r"<- raw_append_byte(out, ", r)
    r = re.sub(r"out\.extend\(", r"out <- raw_append_bytes(out, ", r)
    r = re.sub(r"match (\w+):", r"switch(as.integer(\1) + 1L,", r)
    r = re.sub(r"case ([\w.]+):", r"# case \1", r)
    return r


def write_session() -> None:
    text = (PY / "session.py").read_text()
    # Hand-written session.R is smaller/safer
    body = textwrap.dedent(
        """
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

        shape_key <- function(keys) paste(keys, collapse = "\\0")

        new_shape_table <- function() {
          list(by_keys = list(), by_id = list(), observations = list(), next_id = 0L)
        }

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

        shape_table_observe <- function(table, keys) {
          sk <- shape_key(keys)
          table$observations[[sk]] <- (table$observations[[sk]] %||% 0L) + 1L
          table$observations[[sk]]
        }

        shape_table_clear <- function(table) {
          table$by_keys <- list()
          table$by_id <- list()
          table$observations <- list()
          table$next_id <- 0L
          table
        }

        new_session_state <- function(options = NULL) {
          opts <- options %||% default_session_options()
          list(
            options = opts,
            key_table = new_intern_table(),
            string_table = new_intern_table(),
            shape_table = new_shape_table(),
            encode_shape_observations = list(),
            base_snapshots = list(),
            templates = list(),
            template_columns = list(),
            field_enums = list(),
            dictionaries = list(),
            dictionary_profiles = list(),
            schemas = list(),
            last_schema_id = NULL,
            previous_message = NULL,
            previous_message_size = NULL,
            next_base_id = 0L,
            next_template_id = 0L,
            next_dictionary_id = 0L
          )
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
          state$encode_shape_observations <- list()
          state$field_enums <- list()
          state
        }

        reset_state <- function(state) {
          state <- reset_tables(state)
          state$base_snapshots <- list()
          state$templates <- list()
          state$template_columns <- list()
          state$dictionaries <- list()
          state$dictionary_profiles <- list()
          state$schemas <- list()
          state$last_schema_id <- NULL
          state$previous_message <- NULL
          state$previous_message_size <- NULL
          state$next_base_id <- 0L
          state$next_template_id <- 0L
          state$next_dictionary_id <- 0L
          state
        }
        """
    )
    (OUT / "session.R").write_text(body.strip() + "\n")
    print("session.R")


def write_dictionary() -> None:
    body = (PY / "dictionary.py").read_text()
    # Emit dictionary.R by copying Python with light edits - use exec on template
    r = body
    r = re.sub(r'^"""[\s\S]*?"""\n', '', r)
    r = re.sub(r'^from \..*\n', '', r, flags=re.M)
    r = re.sub(r'^import struct\n', '', r, flags=re.M)
    r = r.replace("class _WideU128:", "# WideU128 helpers\nwide_u128 <- function(lo=0, hi=0) list(lo=lo, hi=hi)")
    r = re.sub(r"def (\w+)\(", r"\1 <- function(", r)
    r = r.replace("bytearray()", "new_buffer()")
    r = r.replace("-> None:", ") {")
    r = r.replace("-> bytes:", ") {")
    r = r.replace("-> list[str]:", ") {")
    r = r.replace("-> tuple[", ") # tuple[")
    r = r.replace("raise invalid_data", "twilic_stop(invalid_data")
    r = r.replace("reader.read_", "reader$read_")
    r = r.replace("reader.is_eof()", "reader$is_eof()")
    r = r.replace("reader.position()", "reader$position()")
    (OUT / "dictionary.R").write_text("# Ported from twilic-python dictionary.py\n" + r)
    print("dictionary.R", len(r.splitlines()))


def write_v2() -> None:
    py = (PY / "v2.py").read_text()
    consts = re.findall(r"^([A-Z0-9_]+) = (0x[0-9A-Fa-f]+)", py, re.M)
    lines = ["# Ported from twilic-python v2.py"]
    for name, val in consts:
        lines.append(f"{name} <- {val}L")
    lines.append("")
    lines.append("new_v2_encode_state <- function() list(key_ids=list(), str_ids=list(), shape_ids=list(), next_key_id=0L, next_str_id=0L, next_shape_id=0L)")
    lines.append("new_v2_decode_state <- function() list(keys=list(), strings=list(), shapes=list())")
    lines.append("encode_v2 <- function(value) { out <- new_buffer(); st <- new_v2_encode_state(); encode_v2_value(value, out, st); out }")
    lines.append("decode_v2 <- function(data) { reader <- new_reader(data); st <- new_v2_decode_state(); value <- decode_v2_value(reader, st); if (!reader$is_eof()) twilic_stop(invalid_data('trailing bytes in v2 decode')); value }")
    lines.append("# TODO: full v2 encode/decode helpers - see v2.py")
    (OUT / "v2.R").write_text("\n".join(lines) + "\n")
    print("v2.R stub")


def main() -> None:
    write_session()
    write_dictionary()
    write_v2()


if __name__ == "__main__":
    main()
