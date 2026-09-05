# frozen_string_literal: true

require "test_helper"
require "twilic/core/interop_fixtures"

class InteropFixturesTest < Minitest::Test
  include TwilicTestHelpers

  def test_codec_encode_decode_roundtrip
    buf = +""
    Twilic::Core::InteropFixtures.emit_interop_fixtures(buf)
    frames = Twilic::Core::InteropFixtures.parse_interop_frames(buf)

    codec = Twilic.new_twilic_codec
    frames.each do |frame|
      next unless frame.stream == "codec"

      Twilic::Core::InteropFixtures.assert_interop_codec_decode(codec, frame.label, frame.bytes)
      next unless Twilic::Core::InteropFixtures.interop_expect_codec_value?(frame.label)

      iso = replay_codec_state(frames, frame.label)
      got = iso.decode_value(frame.bytes)
      reencoded = iso.encode_value(got)
      roundtrip = iso.decode_value(reencoded)
      assert Twilic.equal(roundtrip, got), "#{frame.label}: roundtrip value mismatch"
    end
  end

  def test_session_encode_decode_roundtrip
    buf = +""
    Twilic::Core::InteropFixtures.emit_interop_fixtures(buf)
    frames = Twilic::Core::InteropFixtures.parse_interop_frames(buf)

    codec = Twilic.new_twilic_codec
    frames.each do |frame|
      next unless frame.stream == "session"

      Twilic::Core::InteropFixtures.assert_interop_session_decode(codec, frame.label, frame.bytes)
    end
  end

  def test_decode_rust_server_frames
    root = interop_module_root
    interop_require_twilic_rust!(root)
    rust_manifest = File.join(root, "scripts", "rust-server-fixtures", "Cargo.toml")
    skip "rust fixtures not available" unless File.exist?(rust_manifest)

    rust_out = IO.popen(["cargo", "run", "--quiet", "--manifest-path", rust_manifest], chdir: root, &:read)
    frames = Twilic::Core::InteropFixtures.parse_interop_frames(rust_out)

    codec_stream = Twilic.new_twilic_codec
    session_stream = Twilic.new_twilic_codec
    frames.each do |frame|
      unless %w[codec session].include?(frame.stream)
        flunk "unknown stream #{frame.stream.inspect}"
      end

      decoder = frame.stream == "session" ? session_stream : codec_stream
      case frame.stream
      when "codec"
        Twilic::Core::InteropFixtures.assert_interop_codec_decode(decoder, frame.label, frame.bytes)
      when "session"
        Twilic::Core::InteropFixtures.assert_interop_session_decode(decoder, frame.label, frame.bytes)
      end
    end
  end

  def test_rust_decodes_ruby_frames_with_same_values
    root = interop_module_root
    interop_require_twilic_rust!(root)
    rust_check = File.join(root, "scripts", "rust-client-check", "Cargo.toml")
    skip "rust client check not available" unless File.exist?(rust_check)

    ruby_buf = +""
    Twilic::Core::InteropFixtures.emit_interop_fixtures(ruby_buf)

    out = IO.popen(
      ["cargo", "run", "--quiet", "--manifest-path", rust_check],
      "r+",
      chdir: root
    ) do |io|
      io.write(ruby_buf)
      io.close_write
      io.read
    end
    assert_includes out, "value checks passed for"
  end

  private

  def replay_codec_state(frames, stop_label)
    iso = Twilic.new_twilic_codec
    frames.each do |prior|
      next unless prior.stream == "codec"
      break if prior.label == stop_label

      if Twilic::Core::InteropFixtures.interop_expect_control_payload?(prior.label) ||
         prior.label == "base_snapshot"
        iso.decode_message(prior.bytes)
      elsif Twilic::Core::InteropFixtures.interop_expect_codec_value?(prior.label)
        iso.decode_value(prior.bytes)
      end
    end
    iso
  end

  def interop_module_root
    dir = __dir__
    loop do
      return dir if File.exist?(File.join(dir, "twilic.gemspec"))

      parent = File.dirname(dir)
      raise "could not find module root" if parent == dir

      dir = parent
    end
  end

  def interop_require_twilic_rust!(module_root)
    skip "cargo not found in PATH" unless system("which cargo > /dev/null 2>&1")

    candidates = [File.join(module_root, "..", "rust")]
    env = ENV["TWILIC_RUST_ROOT"]
    candidates.unshift(env) if env && !env.empty?

    skip "Rust runtime not found (expected ../rust or TWILIC_RUST_ROOT)" unless candidates.any? do |root|
      File.exist?(File.join(root, "Cargo.toml"))
    end
  end
end
