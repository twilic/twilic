#!/usr/bin/env ruby
# frozen_string_literal: true

require "twilic"
require "twilic/core/interop_fixtures"

include Twilic::Core::InteropFixtures

begin
  codec_stream = Twilic.new_twilic_codec
  session_stream = Twilic.new_twilic_codec
  decoded = 0

  $stdin.each_line.with_index do |raw_line, line_no|
    line = raw_line.strip
    next if line.empty?

    stream, label, hex = parse_interop_frame_line(line)
    bytes = decode_interop_hex(hex)
    decoder = case stream
              when "codec" then codec_stream
              when "session" then session_stream
              else
                raise "unknown stream #{stream.inspect}"
              end

    case stream
    when "codec"
      assert_interop_codec_decode(decoder, label, bytes)
    when "session"
      assert_interop_session_decode(decoder, label, bytes)
    end
    decoded += 1
  rescue StandardError => e
    raise "line #{line_no + 1} (#{label || 'unknown'}): #{e.message}"
  end

  raise "no fixture frames found" if decoded.zero?

  puts "Ruby client decode and value checks passed for #{decoded} Rust frames"
rescue StandardError => e
  warn "decode fixtures: #{e.message}"
  exit 1
end
