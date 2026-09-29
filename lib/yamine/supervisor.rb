# frozen_string_literal: true

require "fileutils"
require "monitor"
require "socket"

module Yamine
  # Daemon-owned supervision for managed apps (puma-dev model).
  #
  # The proxy daemon is long-lived and sees every request, so it owns:
  # last-used tracking (idle kill), tmp/restart.txt watching, backend
  # liveness, and boot-on-request for stopped apps.
  #
  # What it watches is any route that names a directory to boot from
  # (spec.dir) — socket and tcp alike, because a `yamine start` tree
  # registers tcp routes and was therefore invisible to all of it. What
  # it may DO with a route is not the same set: see rebootable?.
  # Static aliases (pid 0, no spec) are never supervised.
  #
  # State is in-memory (the daemon is the only supervisor); routes.json
  # stays declarative. Killing is graceful-first with a short KILL
  # fallback so puma drains.
  class Supervisor
    DEFAULT_IDLE = 900 # 15 minutes
    # Bound on the connect that decides whether a tcp backend is
    # answering. A local port answers in microseconds or not at all; the
    # case that actually blocks is a full accept backlog, and this loop
    # supervises every route on the machine.
    CONNECT_TIMEOUT = 2

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

    # The daemon watches a route when it knows where the app lives on
    # disk, because that is all restart.txt and the boot path need. Both
    # kinds qualify, and the tcp half is not a nicety: `yamine start`
    # registers kind "tcp" (Runner#boot_run, Runner#adopt), so excluding
    # it made `yamine restart` a no-op for every app yamine itself
    # started — it touched tmp/restart.txt and announced "managed app
    # restarts on next request" for a tree nothing was watching. A spec
    # is required, so static aliases and hand-written routes stay out:
    # there is no directory to watch and no app to restart.
    def supervised?(route)
      %w[socket tcp].include?(route["kind"]) &&
        route["spec"].is_a?(Hash) && route["spec"]["dir"].is_a?(String)
    end

    # Can the daemon put this app back on its feet by itself?
    #
    # Only a socket route: its target is derived (dir/tmp/sockets/
    # yamine.sock), so a fresh backend can be pointed at the same route,
    # and the proxy asks the supervisor about socket routes by design. A
    # tcp route's port is a free port chosen at boot and the route
    # records no command to re-run, so there is nothing to rebuild it
    # from — the two halves of "stopped, boots on next request" cannot
    # both be true for one, and the half that is true is the half that
    # matters.
    def rebootable?(route)
      route["kind"] == "socket"
    end

    def touch(hostname)
      @state.synchronize do
        st(hostname)[:last_used] = clock_now
      end
    end

    # Boot a stopped app on demand. Returns the route (unchanged — the
    # target path is deterministic) or nil on boot failure.
    #
    # A tcp route returns unchanged even when its backend is down: the
    # proxy only ever asks about socket routes, and there is nothing this
    # could rebuild (see rebootable?).
    def ensure_running(route, timeout: 60)
      return route unless supervised?(route) && rebootable?(route)

      backend_alive?(route) ? route : boot(route, timeout)
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
        alive = backend_alive?(route)
        # The latch below only exists to stop a second kill landing on a
        # backend that is already down, and it is cleared the moment the
        # app is back — booted on request, or `yamine start` again in that
        # directory. Left one-way (as it was) a route was supervised for
        # exactly one event in the life of the daemon, so the second
        # `yamine restart` was the no-op this method exists to remove.
        st[:restarting] = false if alive
        next if st[:restarting]

        if restart_changed?(route, st)
          @on_event.call("restart.txt changed for #{hostname} — stopping backend")
          kill_backend(route)
          st[:restarting] = true
        elsif !alive
          @on_event.call("backend for #{hostname} is down — #{recovery(route)}")
          st[:restarting] = true
        elsif idle?(st, now) && idle_kill?(route)
          @on_event.call("#{hostname} idle — stopping backend, #{recovery(route)}")
          kill_backend(route)
          st[:restarting] = true
        end
      end
    end

    # Kill every backend the daemon booted (daemon shutdown).
    #
    # Only the ones it would have booted back. A socket app exists
    # because the daemon started it, so it goes down with it — that is
    # the puma-dev contract and the reason this method exists. A
    # `yamine start` app has a supervising process of its own and a
    # lifecycle of its own: the proxy is the listener in front of it, not
    # its parent, and restarting the proxy is no reason to take every
    # developer's app on the machine down. Supervised (watched) is not
    # the same set as owned (booted by us and answerable to us).
    def shutdown
      @store.load_routes.each do |route|
        kill_backend(route) if supervised?(route) && rebootable?(route)
      end
    end

    def idle?(st, now)
      return false if @idle_timeout.zero?
      return false unless st[:last_used]

      (now - st[:last_used]) > @idle_timeout
    end

    # Is the app behind this route serving right now? Both kinds, one
    # question: a socket route answers a connect on its socket file, a
    # tcp route answers a connect on its port. The daemon needs this
    # rather than a socket-only probe because tcp routes are now watched
    # (see supervised?) — and it is the same question
    # CLI::Context#backend_alive? answers for `yamine list`, which is
    # what makes the two surfaces able to disagree about one app.
    def backend_alive?(route)
      case route["kind"]
      when "socket" then socket_alive?(route)
      when "tcp"
        host, port = route["target"].to_s.split(":", 2)
        # Bounded: this runs in the daemon's single supervision loop, so
        # a connect that hangs on a full accept backlog would stall every
        # other route's supervision behind it.
        Socket.tcp(host, port.to_i, connect_timeout: CONNECT_TIMEOUT) { |sock| sock.close }
        true
      else
        false
      end
    rescue SystemCallError, IOError
      false
    end

    # Stop an idle backend only when the daemon can bring it back.
    #
    # Idle-kill is the half of puma-dev that depends on the other half: it
    # promises "stopped, boots on next request", and for a tcp route the
    # daemon cannot keep that promise (see rebootable?). Killing one
    # anyway would take a developer's app down for an afternoon and leave
    # a 503 in place of it, so it is opt-in — YAMINE_IDLE_TCP=1 — rather
    # than a default nobody asked for. Watched is not idle-killed:
    # restart.txt and crash detection still work for these routes.
    def idle_kill?(route)
      return true if rebootable?(route)

      idle_tcp_opt_in?
    end

    def idle_tcp_opt_in?
      %w[1 true yes on].include?(ENV["YAMINE_IDLE_TCP"].to_s.strip.downcase)
    end

    # What happens next, in the one form that is true for both kinds: a
    # socket app is rebooted on the next request, a tcp app has to be
    # started again by hand. Saying "will boot on next request" for a
    # route nothing will reboot is the exact lie this file stopped
    # telling when tcp routes became supervised.
    def recovery(route)
      return "will boot on next request" if rebootable?(route)

      "run `yamine start` in #{route.dig("spec", "dir") || "its directory"} again"
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
        # By group when the pid leads one, by pid when it does not. A tcp
        # route's sidecar names the `sh -c` shell that `yamine start`
        # wraps every command in, and TERM to that shell alone leaves the
        # app behind it running (linux) — which would make a restarted
        # tcp app keep serving while the route was re-registered, i.e. the
        # old process under a new pid's name (ProcessTree). One syscall,
        # no sleeping: the wait below still owns "and make sure it is
        # gone".
        begin
          ProcessTree.term(pid)
          wait_exit(pid, 10)
        rescue SystemCallError
          nil
        end
      end
      # Only a socket target is a file we own and can leave behind; a tcp
      # target is an address, and unlinking the string would only ever
      # unlink a coincidence in the daemon's working directory.
      FileUtils.rm_f(route["target"]) if route["kind"] == "socket" && route["target"]
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
        #
        # Keyed on :baselined rather than on the mtime being nil, because
        # "no restart.txt" IS a value here: a nil mtime re-baselined on
        # every pass absorbs the first `yamine restart` an app ever gets
        # — the file appears between two ticks, the new mtime becomes the
        # baseline, and the change that was asked for is the change that
        # gets missed. `yamine restart` in an app that had never been
        # restarted did nothing at all, for either kind of route.
        unless s[:baselined]
          s[:restart_mtime] = restart_mtime(route)
          s[:baselined] = true
        end
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
