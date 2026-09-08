# frozen_string_literal: true

module Yamine
  # Read-only health checks: proxy, routes, DNS, CA trust.
  # Never changes state; safe for agents to call any time.
  module Doctor
    Check = Struct.new(:name, :ok, :message, keyword_init: true)

    module_function

    def run(store:, port: nil, tls: nil)
      checks = []
      port ||= ProxyControl.proxy_port(store)
      tls = ProxyControl.proxy_tls(store) if tls.nil?

      checks << check_state_dir(store)
      checks << check_disk(store)
      checks << check_proxy(port, tls: tls)
      checks << check_routes(store)
      checks << check_dns(store)
      checks << check_ca
      checks
    end

    # ENOSPC on the state dir looks like our bug (socket bind fails,
    # route writes vanish). Warn well before that: 100MB is already
    # unreasonable for route files plus a rotated proxy log.
    DISK_WARN_BYTES = 100 * 1024 * 1024

    def check_disk(store)
      used = Log.disk_usage(store.dir)
      if used > DISK_WARN_BYTES
        Check.new(name: "disk", ok: false,
          message: "state dir uses #{Log.human_bytes(used)} — " \
            "check #{File.join(store.dir, "proxy.log*")} for runaway logging")
      else
        Check.new(name: "disk", ok: true,
          message: "state dir uses #{Log.human_bytes(used)}")
      end
    end

    # Root-owned state files lock the unprivileged CLI out of its own
    # state — the failure then looks like corruption, not permissions.
    # Say so plainly.
    def check_state_dir(store)
      dir = store.dir
      begin
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        probe = File.join(dir, ".writability-probe")
        File.write(probe, "1")
        File.unlink(probe)
        Check.new(name: "state", ok: true, message: "#{dir} writable")
      rescue SystemCallError => e
        Check.new(name: "state", ok: false,
          message: "#{dir} not writable (#{e.message}) — " \
            "if a root proxy wrote here, run: sudo chown -R $USER #{dir}")
      end
    end

    def check_proxy(port, tls:)
      if port.nil?
        return Check.new(name: "proxy", ok: false,
          message: "not running — run: yamine proxy start")
      end
      unless ProxyControl.listening?(port)
        return Check.new(name: "proxy", ok: false,
          message: "port #{port} not listening — run: yamine proxy start")
      end
      if ProxyControl.ours?(port, tls: tls)
        Check.new(name: "proxy", ok: true, message: "listening on port #{port}")
      else
        Check.new(name: "proxy", ok: false,
          message: "port #{port} is in use by another process")
      end
    end

    def check_routes(store)
      routes = store.load_routes
      if routes.empty?
        Check.new(name: "routes", ok: true, message: "no active routes")
      else
        stale = store.load_routes_raw.length - routes.length
        msg = "#{routes.length} active route(s)"
        msg += " (#{stale} stale pruned)" if stale.positive?
        Check.new(name: "routes", ok: true, message: msg)
      end
    end

    def check_dns(store)
      hostnames = store.load_routes.map { |r| r["hostname"] }
      return Check.new(name: "dns", ok: true, message: "no routes to resolve") if hostnames.empty?

      missing = Hosts.unresolved(hostnames)
      if missing.empty?
        Check.new(name: "dns", ok: true, message: "all #{hostnames.length} hostname(s) resolve")
      else
        Check.new(name: "dns", ok: false,
          message: "#{missing.join(", ")} do not resolve — run: yamine hosts sync")
      end
    end

    def check_ca
      dir = Certs.state_dir
      paths = Certs.ca_paths(dir)
      unless File.file?(paths[:cert])
        return Check.new(name: "ca", ok: false, message: "no CA yet — run: yamine trust")
      end
      if Certs.trusted?(dir)
        Check.new(name: "ca", ok: true, message: "CA trusted")
      else
        Check.new(name: "ca", ok: false, message: "CA not trusted — run: yamine trust")
      end
    end

    def print(checks, out: $stdout, json: false)
      if json
        require "json"
        out.puts JSON.generate({
          checks: checks.map { |c| { name: c.name, ok: c.ok, message: c.message } },
          failed: checks.count { |c| !c.ok }
        })
        return checks.count { |c| !c.ok }
      end
      failed = 0
      checks.each do |c|
        mark = c.ok ? "ok" : "FAIL"
        failed += 1 unless c.ok
        out.puts "  [#{mark}] #{c.name}: #{c.message}"
      end
      failed
    end
  end
end
