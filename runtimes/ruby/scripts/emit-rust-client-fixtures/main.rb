#!/usr/bin/env ruby
# frozen_string_literal: true

require "twilic/core/interop_fixtures"

begin
  Twilic::Core::InteropFixtures.emit_interop_fixtures($stdout)
rescue StandardError => e
  warn "emit fixtures: #{e.message}"
  exit 1
end
