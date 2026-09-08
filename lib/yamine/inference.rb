# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

module Yamine
  # Zero-flag app name inference.
  #
  # Order: yamine.json "name" -> Rails module in config/application.rb ->
  # gemspec name -> package.json name (for hybrid apps) -> git root basename
  # -> directory basename. First non-empty sanitized name wins.
  module Inference
    CONFIG_FILENAME = "yamine.json"

    module_function

    # Returns [name, source].
    def infer(cwd = Dir.pwd)
      from_config(cwd) ||
        from_rails_module(cwd) ||
        from_gemspec(cwd) ||
        from_package_json(cwd) ||
        from_git_root(cwd) ||
        from_directory(cwd)
    end

    def from_config(cwd)
      path = File.join(cwd, CONFIG_FILENAME)
      return nil unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      name = parsed["name"] || parsed.dig("apps", ".", "name")
      return nil if name.nil? || name.strip.empty?

      [Sanitize.hostname_label(name), "yamine.json"]
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # Myapp::Application -> myapp (walks up for config/application.rb).
    def from_rails_module(cwd)
      dir = Pathname.new(cwd)
      until dir.root?
        candidate = dir.join("config", "application.rb")
        if candidate.file?
          mod = parse_rails_module(candidate.read)
          return [Sanitize.hostname_label(mod), "config/application.rb"] if mod
        end
        dir = dir.parent
      end
      nil
    end

    def parse_rails_module(source)
      match = source.match(/module\s+([A-Z][A-Za-z0-9_]*)/)
      return nil unless match

      # CamelCase with digit runs -> kebab: Rails8Min => rails-8-min,
      # MyApp => my-app. Underscores become hyphens as well.
      match[1].gsub(/([a-z0-9])([A-Z])/, '\1-\2')
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1-\2')
        .gsub(/([a-zA-Z])(\d)/, '\1-\2')
        .gsub(/(\d)([a-zA-Z])/, '\1-\2')
        .tr("_", "-").downcase
    end

    # First *.gemspec with a name in cwd (non-recursive, top level only).
    def from_gemspec(cwd)
      Dir.glob(File.join(cwd, "*.gemspec")).sort.each do |path|
        name = parse_gemspec_name(File.read(path))
        next if name.nil? || name.empty?

        base = name.split("/").last
        labeled = Sanitize.hostname_label(base)
        return [labeled, File.basename(path)] unless labeled.empty?
      end
      nil
    rescue SystemCallError
      nil
    end

    def parse_gemspec_name(source)
      match = source.match(/\.name\s*=\s*["']([^"']+)["']/)
      match && match[1]
    end

    def from_package_json(cwd)
      dir = Pathname.new(cwd)
      until dir.root?
        pkg = dir.join("package.json")
        if pkg.file?
          parsed = JSON.parse(pkg.read)
          raw = parsed["name"]
          if raw.is_a?(String) && !raw.empty?
            base = raw.sub(%r{\A@[^/]+/}, "")
            labeled = Sanitize.hostname_label(base)
            return [labeled, "package.json"] unless labeled.empty?
          end
        end
        dir = dir.parent
      end
      nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def from_git_root(cwd)
      root = git_root(cwd)
      return nil unless root

      labeled = Sanitize.hostname_label(File.basename(root))
      labeled.empty? ? nil : [labeled, "git root"]
    end

    def from_directory(cwd)
      labeled = Sanitize.hostname_label(File.basename(File.expand_path(cwd)))
      raise Error, "Could not infer a project name from #{cwd}" if labeled.empty?

      [labeled, "directory name"]
    end

    def git_root(cwd)
      out, status = Open3.capture2("git", "rev-parse", "--show-toplevel",
        chdir: cwd, err: File::NULL)
      return out.strip if status.success? && !out.strip.empty?

      walk_up_for_git(cwd)
    rescue SystemCallError, ArgumentError
      walk_up_for_git(cwd)
    end

    def walk_up_for_git(cwd)
      dir = Pathname.new(File.expand_path(cwd))
      until dir.root?
        return dir.to_s if dir.join(".git").exist?
        dir = dir.parent
      end
      nil
    end
  end
end
