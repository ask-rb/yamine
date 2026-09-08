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
    # (lib/ask/local -> gem root/bin). Used for daemon spawn and
    # service install; both must resolve identically in dev checkouts
    # and installed gems.
    def bin_path
      File.expand_path("../../../bin/yamine", __dir__)
    end

    def root?
      Process.uid.zero?
    end

    def default_port(tls)
      env = ENV["YAMINE_PORT"]
      return env.to_i if env && env.to_i.between?(1, 65_535)

      tls ? DEFAULT_TLS_PORT : DEFAULT_PLAIN_PORT
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

    def write_pid(store, pid, port, tls)
      store.ensure_dir
      File.write(store.pid_path, "#{pid}\n")
      File.write(store.port_path, "#{port}\n")
      File.write(File.join(store.dir, "proxy.tls"), tls ? "1" : "0")
      Ownership.fix(store.pid_path, store.port_path, File.join(store.dir, "proxy.tls"))
    end

    def clear_pid(store)
      FileUtils.rm_f(store.pid_path)
      FileUtils.rm_f(store.port_path)
    end

    def proxy_port(store)
      return nil unless File.file?(store.port_path)

      port = File.read(store.port_path).strip.to_i
      port.positive? ? port : nil
    rescue SystemCallError, ArgumentError
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
      write_pid(store, pid, port, tls)
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
        return :not_running unless port && listening?(port)

        return :unknown_process
      end
      unless pid_alive?(pid)
        clear_pid(store)
        return :stale
      end
      begin
        Process.kill("TERM", pid)
      rescue SystemCallError
        clear_pid(store)
        return :stale
      end
      clear_pid(store)
      :stopped
    end
  end
end
