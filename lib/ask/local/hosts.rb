# frozen_string_literal: true

require "resolv"
require "timeout"

module Ask
  module Local
    # /etc/hosts sync for Safari + custom TLDs (.localhost resolves natively
    # in Chrome/Firefox/Edge; Safari uses the system resolver).
    # Same managed-block approach as portless hosts.ts.
    module Hosts
      BEGIN_MARKER = "# --- ask-local begin ---"
      END_MARKER = "# --- ask-local end ---"
      PATH = "/etc/hosts"

      module_function

      def managed_block(hostnames)
        lines = [BEGIN_MARKER]
        hostnames.uniq.sort.each { |h| lines << "127.0.0.1 #{h}" }
        lines << END_MARKER
        "#{lines.join("\n")}\n"
      end

      def read(path = PATH)
        File.read(path)
      rescue SystemCallError
        ""
      end

      def managed_hostnames(content = read)
        inside = false
        names = []
        content.each_line do |line|
          inside = true if line.strip == BEGIN_MARKER
          next unless inside
          break if line.strip == END_MARKER

          parts = line.split
          names.concat(parts[1..]) if parts.first == "127.0.0.1"
        end
        names
      end

      def sync(hostnames, path = PATH)
        content = read(path)
        block = managed_block(hostnames)
        if content.include?(BEGIN_MARKER)
          updated = content.sub(/#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}\n?/m, block)
        else
          updated = "#{content.rstrip}\n#{block}"
        end
        File.write(path, updated)
        true
      rescue SystemCallError
        false
      end

      # True when /etc/hosts already carries exactly the managed block for
      # these hostnames. The root service install syncs under elevation;
      # plain re-runs of setup must not fail trying to rewrite it
      # unprivileged when nothing changed.
      def synced?(hostnames, path = PATH)
        read(path).include?(managed_block(hostnames))
      end

      def clean(path = PATH)
        content = read(path)
        updated = content.sub(/#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}\n?/m, "")
        File.write(path, updated)
        true
      rescue SystemCallError
        false
      end

      def resolves?(hostname)
        Timeout.timeout(2) { Resolv.getaddress(hostname) }
        true
      rescue Resolv::ResolvError, SystemCallError, Timeout::Error
        false
      end

      def unresolved(hostnames)
        hostnames.reject { |h| resolves?(h) }
      end
    end
  end
end
