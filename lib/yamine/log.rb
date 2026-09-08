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
  end
end
