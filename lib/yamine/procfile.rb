# frozen_string_literal: true

module Yamine
  # Procfile.dev multi-process support: parse every line, classify each
  # process as HTTP (gets a .localhost URL) or background (supervised,
  # no URL), and boot them all with one command.
  #
  # Classification is deliberately permissive (portless lesson: proxy by
  # default): a process is background only when its NAME says so
  # (worker/job/sidekiq/watch/tunnel/build/css) or an yamine.json
  # override says so. Everything else is HTTP. A misclassified worker
  # harmlessly gets an unvisited route; a misclassified server with NO
  # route is a broken dev day — so the bias is toward HTTP, and the boot
  # banner always prints the classification so the fix is obvious.
  #
  # The Procfile stays canonical: Heroku, Docker, and plain
  # `foreman start` keep working. yamine.json only overrides
  # classification, ports, and env — it never replaces the Procfile.
  module Procfile
    HTTP = :http
    BACKGROUND = :background

    # Name fragments that mark a background process. Matched against
    # the process NAME (left of the colon), not the command.
    BACKGROUND_HINTS = %w[
      worker job sidekiq solid_queue mission_control
      watch tailwind css esbuild vite assets
      tunnel cloudflared ngrok expose
      build compile
    ].freeze

    COMPOUND = /&&|\|\||[|;]/.freeze

    module_function

    # Parsed line: {name, command, compound?}. Compound lines (shell
    # operators) cannot be safely injected with PORT — refused loudly
    # by the caller, never silently rewritten.
    Line = Struct.new(:name, :command, :compound, keyword_init: true)

    def parse_file(path)
      lines = File.readlines(path, chomp: true)
      entries = []
      lines.each do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")
        next unless stripped.include?(":")

        name, cmd = stripped.split(":", 2).map(&:strip)
        next if name.nil? || name.empty? || cmd.nil? || cmd.empty?

        entries << Line.new(name: name, command: cmd, compound: cmd.match?(COMPOUND))
      end
      entries
    rescue SystemCallError
      []
    end

    def find_file(dir = Dir.pwd)
      %w[Procfile.dev Procfile].each do |name|
        path = File.join(dir, name)
        return path if File.file?(path)
      end
      nil
    end

    # Classify one process. Overrides win: {"processes": {"worker":
    # {"type": "background"}}} in yamine.json. Otherwise background
    # on name hints, HTTP for everything else.
    def classify(name, overrides: {})
      override = overrides[name] || overrides[name.to_s]
      if override.is_a?(Hash) && override["type"]
        return override["type"].to_s == "background" ? BACKGROUND : HTTP
      end
      lowered = name.to_s.downcase
      return BACKGROUND if BACKGROUND_HINTS.any? { |hint| lowered.include?(hint) }

      HTTP
    end

    # Per-process overrides from yamine.json "processes" map:
    # {"web": {"type": "http", "port": 3000, "env": {...}}, ...}.
    # Unknown keys warn; the Procfile stays the source of the command.
    def load_overrides(dir = Dir.pwd)
      config = Config.load(dir)
      return {} unless config

      procs = config.data["processes"]
      return {} unless procs.is_a?(Hash)

      procs
    end

    # Split command string into argv for spawn (no shell). Returns nil
    # for compound lines the caller must refuse.
    def to_argv(command)
      return nil if command.match?(COMPOUND)

      split_command(command)
    end

    # Minimal shell-word split (quotes + backslash escapes), matching
    # Config.split_command semantics for Procfile lines.
    def split_command(command)
      args = []
      current = +""
      in_single = false
      in_double = false
      escaped = false
      command.each_char do |ch|
        if escaped
          current << ch
          escaped = false
          next
        end
        if ch == "\\" && !in_single
          escaped = true
          next
        end
        if ch == "'" && !in_double
          in_single = !in_single
        elsif ch == '"' && !in_single
          in_double = !in_double
        elsif ch.match?(/\s/) && !in_single && !in_double
          unless current.empty?
            args << current
            current = +""
          end
        else
          current << ch
        end
      end
      args << current unless current.empty?
      args
    end
  end
end
