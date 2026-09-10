# frozen_string_literal: true

require "fileutils"

module Yamine
  # Size-based log rotation. Nothing rotated today: proxy.log grows
  # forever and every managed boot appends to the app log — a Rails app
  # with HMR polling plus a long-lived daemon eventually fills the disk,
  # and ENOSPC on the socket dir looks like our bug. Rotate before write.
  module Log
    # Rotate when the file exceeds this size; keep one generation.
    MAX_BYTES = Integer(ENV.fetch("YAMINE_LOG_MAX_BYTES", 5 * 1024 * 1024))
    KEEP_GENERATIONS = 1

    module_function

    # Open path for appending, rotating first if oversize. Returns the
    # open File so spawn(out:) can take it directly.
    def open_append(path, max_bytes: MAX_BYTES)
      rotate(path, max_bytes: max_bytes)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a")
    end

    def rotate(path, max_bytes: MAX_BYTES)
      return unless File.file?(path)
      return unless File.size(path) > max_bytes

      KEEP_GENERATIONS.downto(1) do |gen|
        src = gen == 1 ? path : "#{path}.#{gen - 1}"
        dst = "#{path}.#{gen}"
        FileUtils.mv(src, dst, force: true) if File.file?(src)
      end
    rescue SystemCallError
      nil
    end

    # Bytes under dir (state dir or app log dir), for doctor reporting.
    def disk_usage(dir)
      total = 0
      Dir.glob(File.join(dir, "**", "*")).each do |f|
        total += File.size(f) if File.file?(f)
      rescue SystemCallError
        nil
      end
      total
    end

    def human_bytes(bytes)
      if bytes >= 1024 * 1024
        format("%.1f MB", bytes.to_f / (1024 * 1024))
      elsif bytes >= 1024
        format("%.1f KB", bytes.to_f / 1024)
      else
        "#{bytes} B"
      end
    end

    # Boot progress sinks. Readiness emits one Event per phase; the sink
    # decides how to render it. Rendering lives here rather than in
    # Readiness so the human stream and the --json stream carry exactly
    # the same events — a phase added to the boot loop shows up in both
    # without touching either renderer.
    module Report
      # "  [web] ok (2.2s) healthcheck /up returned 2xx-3xx" — one line
      # per completed phase, in the boot banner's bracket style.
      class Human
        def initialize(io = $stderr)
          @io = io
        end

        def event(event)
          @io.puts "  [#{event.action}] #{event.status} " \
            "(#{format_seconds(event.duration_ms)})#{detail(event)}"
        end

        def note(message)
          @io.puts "  #{message}"
        end

        private

        def detail(event)
          d = event.detail.to_s.strip
          d.empty? ? "" : " #{d}"
        end

        # Durations are read by humans deciding whether to wait; a
        # sub-second boot should not render as "0.0s".
        def format_seconds(ms)
          return "0ms" if ms.nil? || ms < 1000

          format("%.1fs", ms / 1000.0)
        end
      end

      # One JSON object per line — the agent contract. Same events, no
      # prose.
      class Json
        def initialize(io = $stdout)
          @io = io
        end

        def event(event)
          require "json"
          @io.puts JSON.generate(event.to_h)
        end

        def note(message)
          require "json"
          @io.puts JSON.generate({ note: message })
        end
      end
    end
  end
end
