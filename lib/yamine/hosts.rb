# frozen_string_literal: true

require "socket"
require "timeout"

module Yamine
  # /etc/hosts sync for the client classes that cannot resolve the routes
  # on their own: custom TLDs, and resolvers that read only the hosts file
  # (a CGO-disabled Go binary is the common case — no system resolver, no
  # RFC 6761 special-casing). Same managed-block approach as portless
  # hosts.ts.
  module Hosts
    BEGIN_MARKER = "# --- yamine begin ---"
    END_MARKER = "# --- yamine end ---"
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

    # Bring the managed block to exactly these hostnames. Idempotent: when
    # the block already matches, this is a no-op returning true.
    #
    # The sync short-circuit is load-bearing, not an optimization. /etc/hosts is
    # root-owned on a normal machine, so a rewrite fails without sudo — and
    # `setup` and every boot's workstation check run this. Without the
    # guard, a machine whose hosts file was already correct got a
    # "could not write /etc/hosts (try sudo yamine hosts sync)" warning on
    # every run, sending people to an elevated write for a file that
    # needed nothing.
    def sync(hostnames, path = PATH)
      return true if synced?(hostnames, path)

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

    # Loopback mappings that count as "this name reaches the proxy".
    LOOPBACK = %w[127.0.0.1 ::1].freeze

    # Does the hosts file map this hostname to loopback? That is the one
    # resolution source every client shares — browsers and curl, the
    # system resolver, and resolvers that read only the file (a
    # CGO-disabled Go binary is the common case). The whole file is
    # searched, not just the managed block, so a hand-added entry counts;
    # only loopback mappings count, since the proxy serves on loopback
    # and any other address points the name away from yamine.
    def hosts_entry?(hostname, path = PATH)
      target = hostname.to_s.downcase
      File.foreach(path) do |line|
        parts = line.split("#", 2).first.to_s.split
        next unless parts.length > 1 && LOOPBACK.include?(parts.first.downcase)
        return true if parts[1..].any? { |name| name.downcase == target }
      end
      false
    rescue SystemCallError
      false
    end

    # Where one hostname stands for the clients that will actually use
    # it — a question with three answers no single resolver probe can
    # produce:
    #
    #   :ok   — every client resolves it: mapped in the hosts file, or
    #           found by the system resolver without it (real DNS or an
    #           /etc/resolver entry for a custom TLD).
    #   :warn — browsers and curl handle it (the RFC 6761 .localhost
    #           special case), but file-only resolvers cannot see it.
    #   :fail — nothing resolves it.
    #
    # .localhost names are classified :warn on file absence alone. The
    # system resolver answers any .localhost unconditionally, so probing
    # it carries no information — and acting on that probe is how doctor
    # and boot once reported every .localhost as fully resolved while a
    # CGO-disabled Go binary could not resolve any of them.
    def classification(hostname, path = PATH)
      return :ok if hosts_entry?(hostname, path)
      return :warn if hostname.to_s.downcase.end_with?(".localhost")

      Timeout.timeout(2) { Addrinfo.getaddrinfo(hostname, nil) }
      :ok
    rescue SocketError, SystemCallError, Timeout::Error
      :fail
    end

    # Partition hostnames into { ok:, warn:, fail: } for the consumers
    # that report one line per state (doctor, boot).
    def resolution(hostnames, path = PATH)
      groups = { ok: [], warn: [], fail: [] }
      hostnames.each { |h| groups[classification(h, path)] << h }
      groups
    end
  end
end
