# frozen_string_literal: true

require "fileutils"
require "openssl"
require "socket"
require "timeout"

module Yamine
  # Proxy daemon lifecycle: pid/port/tls files, liveness verification,
  # spawn (with sudo for privileged ports), stop.
  module ProxyControl
    DEFAULT_TLS_PORT = 443
    DEFAULT_PLAIN_PORT = 80
    LOG_NAME = "proxy.log"

    module_function

    # Path to the yamine executable relative to this file
    # (lib/yamine -> gem root/bin). Used for daemon spawn and
    # service install; both must resolve identically in dev checkouts
    # and installed gems.
    def bin_path
      File.expand_path("../../bin/yamine", __dir__)
    end

    def root?
      Process.uid.zero?
    end

    def default_port(tls)
      env = ENV["YAMINE_PORT"]
      return env.to_i if env && env.to_i.between?(1, 65_535)

      tls ? DEFAULT_TLS_PORT : DEFAULT_PLAIN_PORT
    end

    # Is this port the clean default for the current scheme — 443 for
    # https, 80 for http? A default port yields bare
    # `https://myapp.localhost` URLs; any other port appends :PORT to
    # every one of them.
    def default_port?(port, tls)
      port == (tls ? DEFAULT_TLS_PORT : DEFAULT_PLAIN_PORT)
    end

    # Human explanation for a non-default port, or nil when the port is
    # the clean default. Callers use this to surface the downgrade
    # honestly instead of implying the proxy is misconfigured.
    def port_notice(port, tls)
      return nil if default_port?(port, tls)

      "every URL carries :#{port} instead of a clean " \
        "#{tls ? "https" : "http"}://<app>.localhost. Stop it and run " \
        "`yamine setup` (or `yamine proxy start`) to move to port " \
        "#{default_port(tls)}."
    end

    def proxy_tls(store)
      marker = File.join(store.dir, "proxy.tls")
      return false if ENV["YAMINE_HTTPS"] == "0"
      return true if ENV["YAMINE_HTTPS"] == "1"
      return false if File.file?(marker) && File.read(marker).strip == "0"

      true
    rescue SystemCallError
      true
    end

    # Anything TCP-listening on the port (either loopback)?
    def listening?(port)
      ["127.0.0.1", "::1"].any? do |host|
        begin
          TCPSocket.new(host, port).close
          true
        rescue SystemCallError
          false
        end
      end
    end

    # Is the thing on this port OUR proxy? Health requests hit an
    # unregistered host; our proxy answers 404 with X-Yamine: 1.
    # Probes both loopbacks: the proxy binds v4+IPv6, and on machines
    # where only one family answers the check must still succeed.
    # An explicit regression test pins this (health_test pinning
    # ensure_proxy's "is that ours" logic against future proxy changes).
    #
    # Probe order matters: plain HTTP first (our proxy byte-peeks and
    # answers plain HTTP even on the TLS port), TLS second. A TLS-first
    # handshake against a foreign plain-HTTP server blocks in connect
    # waiting for a ServerHello that never comes — and connect used to
    # sit outside the timeout, hanging ensure_proxy for over a minute.
    #
    # Speed: if the plain probe gets ANY HTTP response without our
    # header, the server is definitively foreign — no TLS retry. The
    # slow TLS retry only happens when plain yielded zero bytes
    # (connection error, EOF, or timeout against a silent server).
    def ours?(port, tls:)
      ["127.0.0.1", "::1"].any? do |host|
        case probe_once(port, tls: false, host: host)
        when :ours then true
        when :foreign then false
        else tls ? probe_once(port, tls: true, host: host) == :ours : false
        end
      end
    end

    # Three outcomes: :ours (our header present), :foreign (an HTTP
    # response without it), :unknown (no response at all).
    def probe_once(port, tls:, host:)
      sock = nil
      Timeout.timeout(5) do
        sock = TCPSocket.new(host, port)
        if tls
          ctx = OpenSSL::SSL::SSLContext.new
          ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
          sock = OpenSSL::SSL::SSLSocket.new(sock, ctx)
          sock.connect
        end
        sock.write("GET / HTTP/1.1\r\nHost: yamine-health.invalid\r\nConnection: close\r\n\r\n")
        head = +""
        while (chunk = sock.readpartial(4096))
          head << chunk
          break if head.include?("\r\n\r\n")
        end
        return :unknown if head.empty?

        return head.downcase.include?("x-yamine: 1") ? :ours : :foreign
      end
    rescue SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, IOError, EOFError
      :unknown
    ensure
      begin
        sock&.close
      rescue StandardError
        nil
      end
    end

    def probe_ours(port, tls:, host:)
      probe_once(port, tls: tls, host: host) == :ours
    end

    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue SystemCallError
      false
    end

    def read_pid(store)
      return nil unless File.file?(store.pid_path)

      pid = File.read(store.pid_path).strip.to_i
      pid.positive? ? pid : nil
    rescue SystemCallError, ArgumentError
      nil
    end

    # Record this process as THE running proxy: pid, port, scheme, and the
    # gem version serving it.
    #
    # Every reader trusts these files — doctor reports the port, Context
    # and the supervisor build URLs from it, `proxy stop` signals the pid
    # — so a proxy that serves without recording is worse than one that
    # fails to start: it leaves the previous proxy's state on disk and the
    # whole CLI acts on it. The launchd/systemd service used to take
    # exactly that path (it runs `proxy start --foreground`, which
    # recorded nothing), so a stopped 8443 daemon's port stayed on disk
    # and `yamine start` baked :8443 into URLs while the machine served
    # clean https://<app>.localhost on 443.
    def write_proxy_state(store, pid:, port:, tls:)
      store.ensure_dir
      version_path = File.join(store.dir, "proxy.version")
      File.write(store.pid_path, "#{pid}\n")
      File.write(store.port_path, "#{port}\n")
      File.write(File.join(store.dir, "proxy.tls"), tls ? "1" : "0")
      File.write(version_path, "#{Yamine::VERSION}\n")
      Ownership.fix(store.pid_path, store.port_path,
        File.join(store.dir, "proxy.tls"), version_path)
    end

    def clear_pid(store)
      FileUtils.rm_f(store.pid_path)
      FileUtils.rm_f(store.port_path)
      FileUtils.rm_f(File.join(store.dir, "proxy.version"))
    end

    def proxy_port(store)
      return nil unless File.file?(store.port_path)

      port = File.read(store.port_path).strip.to_i
      port.positive? ? port : nil
    rescue SystemCallError, ArgumentError
      nil
    end

    # The gem version of the proxy that recorded its state, or nil when
    # nothing is recorded. Compared against Yamine::VERSION so a service
    # left behind by an older install is visible instead of silently
    # serving stale code.
    def proxy_version(store)
      path = File.join(store.dir, "proxy.version")
      return nil unless File.file?(path)

      version = File.read(path).strip
      version.empty? ? nil : version
    rescue SystemCallError
      nil
    end

    # Cheap resolution for the hot paths (URL building on every boot):
    # the recorded port while something is listening there, else the
    # scheme default. Proves liveness, not ownership — a foreign process
    # on the recorded port still wins here and is then caught by
    # `ensure_proxy!` ("port in use by another process"). Use
    # `serving_port` when the answer must be OUR proxy.
    def active_port(store)
      recorded = proxy_port(store)
      return recorded if recorded && listening?(recorded)

      default_port(proxy_tls(store))
    end

    # Where OUR proxy is actually serving, or nil when it is not running.
    # Proves ownership, so it costs a probe — doctor-only, where an
    # occasional connection is free and a wrong answer is not.
    #
    # The default port wins when our proxy serves there, because that is
    # the configuration yamine exists to produce: after `yamine setup`
    # installs the 443 service, a leftover daemon on another port must not
    # make doctor report the downgraded URL as the state of the machine.
    # Only when the default has no proxy do we report the recorded port —
    # which is the deliberate CI/sandbox case (`proxy start -p 1355`).
    def serving_port(store)
      tls = proxy_tls(store)
      default = default_port(tls)
      return default if ours?(default, tls: tls)

      recorded = proxy_port(store)
      return recorded if recorded && recorded != default && ours?(recorded, tls: tls)

      nil
    end

    # Start the proxy as a detached daemon. Sudo is used for privileged
    # ports (portless auto-elevate pattern); the state dir is passed
    # explicitly because sudo does not preserve the environment.
    # Returns pid.
    def spawn_daemon(store:, port:, tls:, sudo: false, tlds: nil)
      store.ensure_dir
      log_path = File.join(store.dir, LOG_NAME)
      Log.rotate(log_path)
      args = [RbConfig.ruby, bin_path,
        "proxy", "start", "--foreground", "--port", port.to_s]
      args << "--no-tls" unless tls
      Array(tlds).each { |t| args.concat(["--tld", t]) }
      state_arg = "YAMINE_STATE_DIR=#{store.dir}"
      cmd = sudo ? ["sudo", "env", state_arg, *args] : [*args]
      pid = spawn({ "YAMINE_STATE_DIR" => store.dir }, *cmd,
        out: log_path, err: [:child, :out])
      Process.detach(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until ours?(port, tls: tls)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise ProxyNotRunningError,
            "Proxy did not start on port #{port}. " \
            "Log (#{log_path}):\n#{log_tail(log_path)}"
        end

        sleep 0.25
      end
      write_proxy_state(store, pid: pid, port: port, tls: tls)
      pid
    end

    def log_tail(path, lines: 15)
      return "(no log yet)" unless File.file?(path)

      File.readlines(path).last(lines).join
    rescue SystemCallError
      "(unreadable log)"
    end

    def stop(store)
      pid = read_pid(store)
      port = proxy_port(store)
      if pid.nil?
        # Nothing recorded, but a service can still be serving — a
        # root-installed proxy from an older gem recorded no state at all,
        # and "Proxy is not running." while 443 answers would be a lie
        # that sends people looking for a process that is right there.
        return :needs_root if serving_port(store)

        return :not_running unless port && listening?(port)

        return :unknown_process
      end
      unless pid_alive?(pid)
        clear_pid(store)
        return :stale
      end
      begin
        Process.kill("TERM", pid)
      rescue Errno::EPERM
        # The proxy runs as root (launchd/systemd service) and we do not.
        # Clearing the state here would be a lie: the proxy keeps serving,
        # now with nothing on disk to find or stop it by.
        return :needs_root
      rescue SystemCallError
        clear_pid(store)
        return :stale
      end
      clear_pid(store)
      :stopped
    end
  end
end
