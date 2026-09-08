# frozen_string_literal: true

require "fileutils"
require "monitor"

module Yamine
  # Daemon-owned supervision for managed socket apps (puma-dev model).
  #
  # The proxy daemon is long-lived and sees every request, so it owns:
  # last-used tracking (idle kill), tmp/restart.txt watching, backend
  # liveness, and boot-on-request for stopped apps. Run-mode (tcp)
  # routes and static aliases are never supervised.
  #
  # State is in-memory (the daemon is the only supervisor); routes.json
  # stays declarative. Killing is graceful-first with a short KILL
  # fallback so puma drains.
  class Supervisor
    DEFAULT_IDLE = 900 # 15 minutes

    attr_reader :interval

    def initialize(store:, runner:, interval: 5.0, idle_timeout: nil, on_event: nil)
      @store = store
      @runner = runner
      @interval = interval
      @idle_timeout = idle_timeout || Supervisor.env_idle || DEFAULT_IDLE
      @on_event = on_event || ->(msg) { warn "[yamine] #{msg}" }
      # Monitor (reentrant): touch → st → state_for nest legitimately.
      @state = {}.extend(MonitorMixin)
      @boot_locks = {}
      @thread = nil
    end

    def self.env_idle
      v = ENV["YAMINE_IDLE_TIMEOUT"]
      return nil unless v && v.to_f >= 0

      v.to_f
    end

    def supervised?(route)
      route["kind"] == "socket" && route["spec"].is_a?(Hash) && route["spec"]["dir"].is_a?(String)
    end

    def touch(hostname)
      @state.synchronize do
        st(hostname)[:last_used] = clock_now
      end
    end

    # Boot a stopped app on demand. Returns the route (unchanged — the
    # target path is deterministic) or nil on boot failure.
    def ensure_running(route, timeout: 60)
      return route unless supervised?(route)

      socket_alive?(route) ? route : boot(route, timeout)
    end

    # Start the background supervision thread.
    def start
      @thread ||= Thread.new do
        loop do
          sleep @interval
          begin
            tick
          rescue StandardError => e
            @on_event.call("supervision error: #{e.message}")
          end
        end
      end
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    # One supervision pass (public for tests): kills idle/dead/restarted
    # backends. Rebooting happens lazily on the next request.
    def tick(now = clock_now)
      @store.load_routes.each do |route|
        next unless supervised?(route)

        hostname = route["hostname"]
        st = state_for(hostname, route, now)
        next if st[:restarting]

        if restart_changed?(route, st)
          @on_event.call("restart.txt changed for #{hostname} — stopping backend")
          kill_backend(route)
          st[:restarting] = true
        elsif !socket_alive?(route)
          @on_event.call("backend for #{hostname} is down — will boot on next request")
          st[:restarting] = true
        elsif idle?(st, now)
          @on_event.call("#{hostname} idle — stopping backend (boots on next request)")
          kill_backend(route)
          st[:restarting] = true
        end
      end
    end

    # Kill every supervised backend (daemon shutdown).
    def shutdown
      @store.load_routes.each do |route|
        kill_backend(route) if supervised?(route)
      end
    end

    def idle?(st, now)
      return false if @idle_timeout.zero?
      return false unless st[:last_used]

      (now - st[:last_used]) > @idle_timeout
    end

    def socket_alive?(route)
      target = route["target"]
      return false unless target && File.socket?(target)

      UNIXSocket.new(target).close
      true
    rescue SystemCallError, IOError
      false
    end

    def backend_pid(route)
      sidecar = File.join(@store.dir, "backend-#{route["hostname"]}.pid")
      return nil unless File.file?(sidecar)

      pid = File.read(sidecar).strip.to_i
      pid.positive? ? pid : nil
    rescue SystemCallError, ArgumentError
      nil
    end

    def kill_backend(route)
      pid = backend_pid(route)
      if pid && pid_alive?(pid)
        begin
          Process.kill("TERM", pid)
          wait_exit(pid, 10)
        rescue SystemCallError
          nil
        end
      end
      FileUtils.rm_f(route["target"]) if route["target"]
      FileUtils.rm_f(File.join(@store.dir, "backend-#{route["hostname"]}.pid"))
    end

    private

    def clock_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def state_for(hostname, route, now)
      @state.synchronize do
        s = st(hostname)
        # First sighting: baseline so a freshly booted app gets a full
        # idle window and an existing restart.txt doesn't count as changed.
        s[:restart_mtime] = restart_mtime(route) if s[:restart_mtime].nil?
        s[:last_used] = now if s[:last_used].nil?
        s
      end
    end

    def st(hostname)
      @state.synchronize { @state[hostname] ||= {} }
    end

    def restart_mtime(route)
      path = restart_path(route)
      path && File.exist?(path) ? File.mtime(path) : nil
    rescue SystemCallError
      nil
    end

    def restart_changed?(route, st)
      path = restart_path(route)
      return false unless path

      current = File.exist?(path) ? File.mtime(path) : nil
      if current != st[:restart_mtime]
        st[:restart_mtime] = current
        true
      else
        false
      end
    rescue SystemCallError
      false
    end

    def restart_path(route)
      dir = route.dig("spec", "dir")
      dir ? File.join(dir, "tmp", "restart.txt") : nil
    end

    def boot(route, timeout)
      hostname = route["hostname"]
      lock = @boot_locks[hostname] ||= Mutex.new
      lock.synchronize do
        # Double-check under the boot lock.
        return route if socket_alive?(route)

        spec = route["spec"]
        @on_event.call("booting #{hostname} on request (#{spec["dir"]})")
        url = Hostname.url(hostname, port: ProxyControl.proxy_port(@store),
          tls: ProxyControl.proxy_tls(@store))
        @runner.boot_supervised(name: hostname, hostname: hostname,
          url: url, dir: spec["dir"])
        st = st(hostname)
        st[:last_used] = clock_now
        route
      end
    rescue StandardError => e
      @on_event.call("boot failed for #{hostname}: #{e.message.lines.first&.strip}")
      nil
    end

    def wait_exit(pid, timeout)
      deadline = clock_now + timeout
      while clock_now < deadline
        return unless pid_alive?(pid)

        sleep 0.2
      end
      begin
        Process.kill("KILL", pid)
      rescue SystemCallError
        nil
      end
    end

    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue SystemCallError
      false
    end
  end
end
