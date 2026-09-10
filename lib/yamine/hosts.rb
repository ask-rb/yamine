# frozen_string_literal: true

require "socket"
require "timeout"

module Yamine
  # /etc/hosts sync for Safari + custom TLDs (.localhost resolves natively
  # in Chrome/Firefox/Edge; Safari uses the system resolver).
  # Same managed-block approach as portless hosts.ts.
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
    # The short-circuit is load-bearing, not an optimization. /etc/hosts is
    # root-owned on a normal machine, so a rewrite fails without sudo — and
    # `setup` and every boot's workstation check run this. Without the
    # guard, a machine whose hosts file was already correct got a
    # "could not write /etc/hosts (try sudo yamine hosts sync)" warning on
    # every run, sending people to an elevated write for a file that
    # needed nothing. (Chrome/Firefox/Edge resolve *.localhost natively;
    # /etc/hosts only matters for Safari and custom TLDs.)
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

    # Does the hostname resolve for the programs that will actually use
    # it — browsers, curl, the app's own HTTP clients? That question can
    # only be answered by the SYSTEM resolver (getaddrinfo), which reads
    # nsswitch (so /etc/hosts counts) and implements the RFC 6761
    # special-use TLDs.
    #
    # Ruby's Resolv is a pure-Ruby DNS client: it never sees /etc/hosts
    # and knows nothing about RFC 6761, so it reports "no address for
    # myapp.localhost" on a machine where .localhost resolves perfectly.
    # That false negative sent users to `sudo yamine hosts sync` — an
    # elevated write to /etc/hosts — to fix a problem they did not have.
    def resolves?(hostname)
      Timeout.timeout(2) { Addrinfo.getaddrinfo(hostname, nil) }
      true
    rescue SocketError, SystemCallError, Timeout::Error
      false
    end

    def unresolved(hostnames)
      hostnames.reject { |h| resolves?(h) }
    end
  end
end
