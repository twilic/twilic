# frozen_string_literal: true

require_relative "lib/twilic/version"

Gem::Specification.new do |spec|
  spec.name = "twilic"
  spec.version = Twilic::VERSION
  spec.authors = ["Twilic"]
  spec.email = ["hello@twilic.dev"]

  spec.summary = "Ruby implementation of a fast, compact binary wire format for modern data transport."
  spec.description = spec.summary
  spec.homepage = "https://github.com/twilic/twilic-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/twilic/twilic-ruby"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.start_with?("test/", ".github/", "scripts/") || f.end_with?(".gem")
    end
  end
  spec.bindir = "exe"
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "rubocop", "~> 1.69"
end
