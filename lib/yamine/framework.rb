# frozen_string_literal: true

require "pathname"

module Yamine
  # Detect what kind of Ruby app lives in a directory so the runner
  # knows how to boot it. Pure filesystem convention, no shell-outs.
  module Framework
    RAILS = :rails
    RACK = :rack
    JEKYLL = :jekyll
    BRIDGETOWN = :bridgetown
    MIDDLEMAN = :middleman
    PROCFILE = :procfile
    UNKNOWN = :unknown

    STATIC_GENERATORS = [JEKYLL, BRIDGETOWN, MIDDLEMAN].freeze

    module_function

    def detect(dir = Dir.pwd)
      path = Pathname.new(File.expand_path(dir))
      return RAILS if rails?(path)
      return JEKYLL if jekyll?(path)
      return BRIDGETOWN if bridgetown?(path)
      return MIDDLEMAN if middleman?(path)
      return RACK if rack?(path)
      return PROCFILE if procfile?(path)

      UNKNOWN
    end

    # Managed mode (unix socket via puma) applies to live Rack apps.
    def managed?(framework)
      framework == RAILS || framework == RACK
    end

    def rails?(path)
      path.join("config", "application.rb").file? &&
        path.join("config", "application.rb").read.match?(/<\s*Rails::Application/)
    rescue SystemCallError
      false
    end

    def rack?(path)
      path.join("config.ru").file?
    end

    def jekyll?(path)
      path.join("_config.yml").file? && gemfile_includes?(path, "jekyll")
    end

    def bridgetown?(path)
      path.join("bridgetown.config.yml").file? ||
        (path.join("config", "initializers").directory? && gemfile_includes?(path, "bridgetown"))
    end

    def middleman?(path)
      path.join("config.rb").file? && gemfile_includes?(path, "middleman")
    end

    def procfile?(path)
      path.join("Procfile.dev").file? || path.join("Procfile").file?
    end

    def gemfile_includes?(path, gem_name)
      gemfile = path.join("Gemfile")
      return false unless gemfile.file?

      gemfile.read.match?(/gem\s+["']#{Regexp.escape(gem_name)}["']/)
    rescue SystemCallError
      false
    end
  end
end
