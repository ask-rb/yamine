# frozen_string_literal: true

require_relative "lib/yamine/version"

Gem::Specification.new do |spec|
  spec.name = "yamine"
  spec.version = Yamine::VERSION
  spec.authors = ["Kaka Ruto"]
  spec.email = ["kaka@myrrlabs.com"]

  spec.summary = "Stable named .localhost URLs for Ruby development"
  spec.description = "Gives every Ruby app a stable https://<app>.localhost URL " \
                     "instead of a memorized port. Explicit-run reverse proxy with " \
                     "zero-config name inference, git-worktree variants, per-host TLS, " \
                     "and agent-friendly list/get/doctor commands. Ruby stdlib only."
  spec.homepage = "https://github.com/ask-rb/yamine"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "bin/yamine", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.bindir = "bin"
  spec.executables = %w[yamine]
  spec.require_paths = ["lib"]

  # Intentionally near-zero runtime dependencies: proxy, TLS, and process
  # supervision are built on ruby's stdlib (openssl, socket, open3).

  # base64.rb requires base64, which left the default gems in Ruby 3.4.
  spec.add_dependency "base64", "~> 0.2"

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mocha", "~> 3.1"
  spec.add_development_dependency "rake", "~> 13.0"
end
