test_that("codec encode decode roundtrip", {
  buf <- twilic:::emit_interop_fixtures()
  frames <- twilic:::parse_interop_frames(buf)
  codec <- new_twilic_codec()
  for (frame in frames) {
    if (frame$stream != "codec") next
    twilic:::assert_interop_codec_decode(codec, frame$label, frame$bytes)
    exp <- interop_expect_codec_value(frame$label)
    if (!exp[[2]]) next
    iso <- replay_codec_state(frames, frame$label)
    got <- iso$decode_value(frame$bytes)
    reencoded <- iso$encode_value(got)
    roundtrip <- iso$decode_value(reencoded)
    expect_true(equal(roundtrip, got), info = frame$label)
  }
})

test_that("session encode decode roundtrip", {
  buf <- twilic:::emit_interop_fixtures()
  frames <- twilic:::parse_interop_frames(buf)
  codec <- new_twilic_codec()
  session_count <- 0L
  for (frame in frames) {
    if (frame$stream != "session") next
    session_count <- session_count + 1L
    twilic:::assert_interop_session_decode(codec, frame$label, frame$bytes)
  }
  expect_gt(session_count, 0L)
})

test_that("decode rust server frames", {
  root <- interop_module_root()
  interop_require_twilic_rust(root)
  rust_manifest <- file.path(root, "scripts", "rust-server-fixtures", "Cargo.toml")
  skip_if_not(file.exists(rust_manifest), "rust fixtures not available")
  rust_out <- interop_run_process(
    root,
    NULL,
    c("cargo", "run", "--quiet", "--manifest-path", rust_manifest)
  )
  frames <- twilic:::parse_interop_frames(rust_out)
  codec_stream <- new_twilic_codec()
  session_stream <- new_twilic_codec()
  for (frame in frames) {
    expect_true(frame$stream %in% c("codec", "session"))
    decoder <- if (frame$stream == "session") session_stream else codec_stream
    if (frame$stream == "codec") {
      twilic:::assert_interop_codec_decode(decoder, frame$label, frame$bytes)
    } else {
      twilic:::assert_interop_session_decode(decoder, frame$label, frame$bytes)
    }
  }
  expect_gt(length(frames), 0L)
})

test_that("rust decodes r frames with same values", {
  root <- interop_module_root()
  interop_require_twilic_rust(root)
  rust_check <- file.path(root, "scripts", "rust-client-check", "Cargo.toml")
  skip_if_not(file.exists(rust_check), "rust client check not available")
  r_buf <- twilic:::emit_interop_fixtures()
  out <- interop_run_process(
    root,
    r_buf,
    c("cargo", "run", "--quiet", "--manifest-path", rust_check)
  )
  expect_match(out, "value checks passed for")
})
