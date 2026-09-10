# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "socket"
require "timeout"
require "uri"

module Yamine
  # Phased boot readiness: every boot step emits a structured event
  # (phase, action, status, duration_ms, detail) so agents get one call
  # with a definitive answer instead of polling logs and guessing.
  #
  # Phases: deps (bundle check etc) -> db (create) -> schema (load) ->
  # process (spawn + healthcheck per process). Each phase has its own
  # timeout; a timeout reports that phase's logs, not the whole tree's.
  #
  # `start --wait` blocks until every HTTP route is healthy and exits 0
  # with a summary payload, or non-zero with the failed phase + log tail.
  module Readiness
    module_function

    DEFAULT_TIMEOUTS = {
      deps: 30,
      db: 15,
      schema: 90,
      process: 45
    }.freeze

    Event = Struct.new(:phase, :action, :status, :duration_ms, :detail,
      keyword_init: true) do
      def to_h
        { phase: phase, action: action, status: status,
          duration_ms: duration_ms, detail: detail }.compact
      end
    end

    # Run a phase with timing + timeout. Yields; returns the Event.
    # On timeout or raise, status is "fail" with the error as detail.
    def phase(name, action, timeout: nil, out: nil)
      timeout ||= DEFAULT_TIMEOUTS.fetch(name, 30)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      event = nil
      begin
        result = Timeout.timeout(timeout) { yield }
        ms = elapsed_ms(started)
        event = Event.new(phase: name, action: action, status: "ok",
          duration_ms: ms, detail: result.is_a?(String) ? result : nil)
      rescue Timeout::Error
        ms = elapsed_ms(started)
        event = Event.new(phase: name, action: action, status: "timeout",
          duration_ms: ms, detail: "exceeded #{timeout}s")
      rescue StandardError => e
        ms = elapsed_ms(started)
        event = Event.new(phase: name, action: action, status: "fail",
          duration_ms: ms, detail: e.message.lines.first&.strip)
      end
      out&.puts(JSON.generate(event.to_h)) if out
      event
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    # Pre-flight: verify runtime dependencies before spawning anything.
    # Ruby (bundle check), Node (node_modules present). Returns [ok, fix].
    # Fast-fails with the fix instead of letting Puma crash-loop for 60s.
    def check_deps(dir = Dir.pwd)
      gemfile = File.join(dir, "Gemfile")
      if File.file?(gemfile)
        _out, status = Open3.capture2("bundle", "check", chdir: dir,
          err: File::NULL)
        unless status.success?
          return [false, "gems missing — run `bundle install` in #{dir}"]
        end
      end
      package = File.join(dir, "package.json")
      if File.file?(package) && !File.directory?(File.join(dir, "node_modules"))
        return [false, "node_modules missing — run `npm install` in #{dir}"]
      end
      [true, nil]
    rescue SystemCallError => e
      [false, e.message.lines.first&.strip]
    end

    # Poll an HTTP route until healthy or timeout. Healthy = healthcheck
    # path returns 2xx-3xx, or (no healthcheck) TCP accept on the port.
    # Returns [healthy, detail].
    #
    # Probes are plaintext by construction: the target is the app's OWN
    # listener (127.0.0.1:$PORT). TLS is terminated by the proxy, which
    # dials backends with a bare TCPSocket (Proxy#connect_backend), so a
    # `tls:` flag taken from the proxy must never reach here — an
    # https:// URL in the banner does not mean the backend speaks TLS.
    def wait_healthy(hostname, port:, path: nil, timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      last_error = "not yet attempted"
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        ok, detail = probe(hostname, port, path: path)
        return [true, nil] if ok

        last_error = detail
        sleep 0.5
      end
      [false, last_error]
    end

    def probe(hostname, port, path: nil)
      if path
        probe_http(hostname, port, path: path)
      else
        probe_tcp(port)
      end
    end

    def probe_tcp(port)
      TCPSocket.new("127.0.0.1", port).close
      [true, nil]
    rescue SystemCallError => e
      [false, e.message.lines.first&.strip]
    end

    def probe_http(hostname, port, path:)
      http = Net::HTTP.new("127.0.0.1", port)
      http.open_timeout = 3
      http.read_timeout = 5
      res = http.get(path, { "Host" => hostname })
      if res.code.to_i.between?(200, 399)
        [true, nil]
      else
        [false, "HTTP #{res.code} on #{path}"]
      end
    rescue StandardError => e
      [false, e.message.lines.first&.strip]
    end

    # Wait for every spawned app concurrently. Each entry: name =>
    # { item: {entry, hostname, port...}, app: <Runner::App> }.
    # Returns an array of result hashes: {name, status, phase, detail,
    # duration_ms}. status is "ok", "fail" (died with log tail hint),
    # or "timeout" (never answered within its healthcheck timeout).
    # Dead-pid short-circuit: a reaped backend fails immediately
    # instead of burning its full timeout on connection-refused.
    def wait_all(apps, out: nil)
      threads = apps.map do |name, slot|
        Thread.new do
          Thread.current[:result] = wait_one(name, slot, out: out)
        end
      end
      threads.each(&:join)
      threads.map { |t| t[:result] }
    end

    def wait_one(name, slot, out:)
      item = slot[:item]
      app = slot[:app]
      hc = item[:entry]["healthcheck"] || {}
      path = hc["path"]
      timeout = hc["timeout"] || DEFAULT_TIMEOUTS[:process]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + timeout
      last_error = "not yet attempted"
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        unless process_alive?(app.pid)
          ms = elapsed_ms(started)
          return fail_result(name, started, ms,
            "process exited before becoming healthy — see log/yamine-#{name}.log", out)
        end
        ok, detail = probe(item[:hostname], item[:port], path: path)
        if ok
          ms = elapsed_ms(started)
          return ok_result(name, started, ms, path, out)
        end
        last_error = detail
        sleep 0.5
      end
      ms = elapsed_ms(started)
      status = process_alive?(app.pid) ? "timeout" : "fail"
      detail = process_alive?(app.pid) ? "no healthy response within #{timeout}s (#{last_error})" :
        "process exited before becoming healthy — see log/yamine-#{name}.log"
      event = Event.new(phase: "process", action: name, status: status,
        duration_ms: ms, detail: detail)
      out&.puts(JSON.generate(event.to_h)) if out
      { name: name, status: status, phase: "process", detail: detail, duration_ms: ms }
    end

    def ok_result(name, started, ms, path, out)
      detail = path ? "healthcheck #{path} returned 2xx-3xx" : "port accepted connection"
      event = Event.new(phase: "process", action: name, status: "ok",
        duration_ms: ms, detail: detail)
      out&.puts(JSON.generate(event.to_h)) if out
      { name: name, status: "ok", phase: "process", detail: detail, duration_ms: ms }
    end

    def fail_result(name, started, ms, detail, out)
      event = Event.new(phase: "process", action: name, status: "fail",
        duration_ms: ms, detail: detail)
      out&.puts(JSON.generate(event.to_h)) if out
      { name: name, status: "fail", phase: "process", detail: detail, duration_ms: ms }
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue SystemCallError
      false
    end
  end

  # Machine-readable --wait payloads. Success carries URLs + per-process
  # health + db provenance; failure names the first failed process, its
  # phase, and the tail of its own log.
  module WaitPayload
    module_function

    def success(resolved, wait_result, urls:, db_name:, db_url:, created:)
      { ok: true, service: resolved.app,
        urls: urls,
        processes: wait_result.map { |r|
          { name: r[:name], status: r[:status], duration_ms: r[:duration_ms] }
        },
        db: db_url ? { name: db_name, url: db_url, created: created } : nil }.compact
    end

    def failure(resolved, wait_result, failed:, log_tail:)
      { ok: false, service: resolved.app,
        failed_process: failed[:name], phase: failed[:phase],
        detail: failed[:detail],
        processes: wait_result.map { |r| { name: r[:name], status: r[:status] } },
        log_path: log_tail[:path], log_tail: log_tail[:tail] }.compact
    end
  end
end
