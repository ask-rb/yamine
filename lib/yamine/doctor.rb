# frozen_string_literal: true

module Yamine
  # Read-only health checks: proxy, routes, DNS, CA trust.
  # Never changes state; safe for agents to call any time.
  module Doctor
    # `warn` is a third state between ok and FAIL: the check passed, but
    # something is configured in a way the user should know about and
    # probably did not choose (a port-suffixed URL). Warnings never
    # affect the exit status — only failures do.
    Check = Struct.new(:name, :ok, :message, :warn, keyword_init: true) do
      def warn?
        warn ? true : false
      end
    end

    module_function

    def run(store:, port: nil, tls: nil)
      checks = []
      tls = ProxyControl.proxy_tls(store) if tls.nil?
      # Prove ownership rather than trusting the port file: doctor is
      # where a wrong answer is expensive, and a connection is cheap. This
      # finds the proxy on the scheme default even when a stale port file
      # says otherwise, which is how a root service serving clean 443 went
      # unreported while doctor warned about a dead 8443.
      port ||= ProxyControl.serving_port(store)

      checks << check_state_dir(store)
      checks << check_disk(store)
      checks << check_proxy(port, tls: tls)
      checks << check_proxy_state(store, port)
      checks << check_routes(store)
      checks << check_dns(store)
      checks << check_ca
      checks << check_ca_bundle
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
      unless ProxyControl.ours?(port, tls: tls)
        return Check.new(name: "proxy", ok: false,
          message: "port #{port} is in use by another process")
      end

      # A proxy on a non-default port is legitimate — CI and sandboxes
      # opt in with `-p` — but it makes EVERY url carry :PORT, which is
      # the one thing yamine exists to avoid. Reporting that as a bare
      # "[ok] listening on port 1355" let a stale dev proxy quietly
      # downgrade every project on the machine.
      notice = ProxyControl.port_notice(port, tls)
      if notice
        Check.new(name: "proxy", ok: true, warn: true,
          message: "listening on port #{port} — #{notice}")
      else
        Check.new(name: "proxy", ok: true, message: "listening on port #{port}")
      end
    end

    # The recorded port, and whether the proxy serving is the version we
    # have installed.
    #
    # A file that disagrees with reality is the failure mode this whole
    # area keeps producing: a stopped daemon's port outliving it made
    # `yamine start` bake :8443 into URLs while the machine served clean
    # 443, and a root service left from an old gem keeps serving old code
    # after an upgrade (`sudo yamine service install` re-registers it).
    # Neither is visible from the URL bar, so both are named here.
    def check_proxy_state(store, serving)
      recorded = ProxyControl.proxy_port(store)
      version = ProxyControl.proxy_version(store)
      problems = []

      if recorded && serving && recorded != serving
        problems << "state says port #{recorded} but the proxy is on #{serving}" \
          " — run: yamine proxy stop"
      elsif recorded && serving.nil?
        problems << "state says port #{recorded}, but no yamine proxy is serving" \
          " — run: yamine proxy stop"
      end

      if version && version != Yamine::VERSION
        problems << "the running proxy is v#{version}, this CLI is v#{Yamine::VERSION}" \
          " — re-register it: sudo yamine service install"
      elsif version.nil? && serving
        # A serving proxy that recorded no version predates the marker
        # (added in 0.9.0), so it is definitely not the code we ship with
        # now. Without this the version check was blind to exactly the
        # service it exists to catch — an old root service keeps serving
        # old code until it is re-registered.
        problems << "the running proxy does not report a version (installed before " \
          "v0.9.0), this CLI is v#{Yamine::VERSION}" \
          " — re-register it: sudo yamine service install"
      end

      if problems.empty?
        Check.new(name: "proxy state", ok: true, message: "consistent")
      else
        Check.new(name: "proxy state", ok: true, warn: true,
          message: problems.join("; "))
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
      unless Certs.trusted?(dir)
        return Check.new(name: "ca", ok: false, message: "CA not trusted — run: yamine trust")
      end

      # Trusted CAs that are not the one now on disk. They accumulate from
      # CA regeneration (missing, expiring, or renamed — the ask-local
      # rename regenerates every machine's CA), and a trusted root whose
      # superseded private key is still on disk is a liability. Pruning
      # only happens when `trust` runs, so after a rename it would wait
      # for the next missing-CA event — i.e. possibly forever. Surface it
      # here with the one command that clears it.
      stale = stale_ca_count(dir)
      if stale.positive?
        Check.new(name: "ca", ok: true, warn: true,
          message: "CA trusted, but #{stale} superseded CA(s) are still trusted" \
            " — run: yamine trust")
      else
        Check.new(name: "ca", ok: true, message: "CA trusted")
      end
    end

    # The child-process trust bundle. Its absence is not theoretical: an
    # app whose process was started before the bundle existed (or with a
    # regenerated CA) fails every call to another *.localhost with
    # "certificate verify failed". Regenerating it here is safe and is
    # exactly what the next boot would do anyway.
    def check_ca_bundle
      dir = Certs.state_dir
      return Check.new(name: "bundle", ok: false, message: "no CA yet — run: yamine trust") unless File.file?(Certs.ca_paths(dir)[:cert])

      target = Certs.ensure_bundle(dir)
      count = File.read(target).scan("BEGIN CERTIFICATE").size
      Check.new(name: "bundle", ok: true, message: "#{count} certificates (system roots + yamine CA)")
    rescue StandardError => e
      Check.new(name: "bundle", ok: false, message: "could not build #{Certs.bundle_path(dir)}: #{e.message}")
    end

    # How many trusted certificates carry one of our CA names without
    # being the CA currently on disk. Best-effort: 0 when the keychain
    # cannot be read (doctor must never fail on a read-only probe).
    def stale_ca_count(dir = Certs.state_dir)
      return 0 unless Trust.respond_to?(:keychain_certs)

      current = Trust.fingerprint_of(Certs.ca_paths(dir)[:cert])
      return 0 unless current

      names = Certs.ca_common_names
      Trust.keychains.sum do |keychain|
        Trust.keychain_certs(keychain).count do |entry|
          entry[:fingerprint] != current &&
            names.any? { |n| entry[:subject].include?(n) }
        end
      end
    rescue StandardError
      0
    end

    def print(checks, out: $stdout, json: false)
      if json
        require "json"
        out.puts JSON.generate({
          checks: checks.map { |c| { name: c.name, ok: c.ok, warn: c.warn?, message: c.message } },
          failed: checks.count { |c| !c.ok },
          warnings: checks.count(&:warn?)
        })
        return checks.count { |c| !c.ok }
      end
      failed = 0
      checks.each do |c|
        mark = if !c.ok then "FAIL"
        elsif c.warn? then "warn"
        else "ok"
        end
        failed += 1 unless c.ok
        out.puts "  [#{mark}] #{c.name}: #{c.message}"
      end
      failed
    end
  end
end
