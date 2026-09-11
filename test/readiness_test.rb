# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "rbconfig"

RUBY_BIN = RbConfig.ruby

class ReadinessPhaseTest < Minitest::Test
  def test_phase_success
    e = Yamine::Readiness.phase(:deps, "check") { "dependencies satisfied" }
    assert_equal "ok", e.status
    assert_equal :deps, e.phase
    assert_equal "check", e.action
    assert_equal "dependencies satisfied", e.detail
    refute_nil e.duration_ms
  end

  def test_phase_timeout
    e = Yamine::Readiness.phase(:deps, "check", timeout: 0.05) { sleep 1 }
    assert_equal "timeout", e.status
    assert_match(/exceeded/, e.detail)
  end

  def test_phase_fail
    e = Yamine::Readiness.phase(:deps, "check") { raise "gems missing -- run `bundle install` in /tmp" }
    assert_equal "fail", e.status
    assert_equal "gems missing -- run `bundle install` in /tmp", e.detail
  end

  def test_phase_default_timeouts
    assert_equal 30, Yamine::Readiness::DEFAULT_TIMEOUTS[:deps]
    assert_equal 15, Yamine::Readiness::DEFAULT_TIMEOUTS[:db]
    assert_equal 90, Yamine::Readiness::DEFAULT_TIMEOUTS[:schema]
    assert_equal 45, Yamine::Readiness::DEFAULT_TIMEOUTS[:process]
  end
end

class ReadinessCheckDepsTest < Minitest::Test
  def test_satisfied_when_no_gemfile_or_package
    dir = Dir.mktmpdir
    ok, fix = Yamine::Readiness.check_deps(dir)
    assert ok
    assert_nil fix
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_node_modules_missing_when_package_json_present
    dir = Dir.mktmpdir
    File.write(File.join(dir, "package.json"), '{"name":"x"}')
    ok, fix = Yamine::Readiness.check_deps(dir)
    refute ok
    assert_match(/node_modules missing/, fix)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_gems_missing_when_bundle_check_fails
    dir = Dir.mktmpdir
    File.write(File.join(dir, "Gemfile"), 'source "https://rubygems.org"')
    Open3.stub(:capture2, ["", Struct.new(:success?).new(false)]) do
      ok, fix = Yamine::Readiness.check_deps(dir)
      refute ok
      assert_match(/gems missing/, fix)
    end
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end

class ReadinessWaitAllTest < Minitest::Test
  # Spawn a fake backend that accepts on port — same shape as runner.boot_run
  # (sh -c so Bundler shims don't hide the ruby binary).
  def fake_tcp(port)
    tmp = Tempfile.new(["fake-", ".rb"])
    tmp.write("require \"socket\"; s = TCPServer.new(\"127.0.0.1\", #{port}); loop{c=s.accept; c.write(\"ok\") rescue nil; c.close rescue nil}\n")
    tmp.close
    pid = spawn(RbConfig.ruby, tmp.path)
    Process.detach(pid)
    sleep 0.6
    [pid, tmp]
  end

  def fake_http_up(port)
    tmp = Tempfile.new(["fake-up-", ".rb"])
    tmp.write(<<~RUBY)
      require "socket"
      s = TCPServer.new("127.0.0.1", #{port})
      loop do
        c = s.accept
        req = c.readpartial(4096) rescue ""
        path = req.lines.first.to_s.split(" ")[1]
        body = (path == "/up" ? "ok" : "")
        status = (path == "/up" ? "200 OK" : "404 Not Found")
        c.write("HTTP/1.1 \#{status}\\r\\nContent-Length: \#{body.bytesize}\\r\\n\\r\\n\#{body}") rescue nil
        c.close rescue nil
      end
    RUBY
    tmp.close
    pid = spawn(RbConfig.ruby, tmp.path)
    Process.detach(pid)
    sleep 0.6
    [pid, tmp]
  end

  def fake_http_500(port)
    tmp = Tempfile.new(["fake-500-", ".rb"])
    tmp.write("require \"socket\"; s = TCPServer.new(\"127.0.0.1\", #{port}); loop{c=s.accept; c.readpartial(4096) rescue nil; c.write(\"HTTP/1.1 500 boom\\r\\nContent-Length: 0\\r\\n\\r\\n\") rescue nil; c.close rescue nil}\n")
    tmp.close
    pid = spawn(RbConfig.ruby, tmp.path)
    Process.detach(pid)
    sleep 0.6
    [pid, tmp]
  end

  def test_wait_all_healthy_when_port_accepts
    port = Yamine::Ports.find_free
    pid, tmp = fake_tcp(port)
    apps = { "web" => { item: { entry: {}, hostname: "app.localhost", port: port }, app: Struct.new(:pid).new(pid) } }
    results = Yamine::Readiness.wait_all(apps, sink: nil)
    assert_equal "ok", results.first[:status]
    assert_equal "web", results.first[:name]
  ensure
    Process.kill("TERM", pid) rescue nil
    tmp&.unlink rescue nil
  end

  def test_wait_all_timeout_when_nothing_listening
    port = Yamine::Ports.find_free
    sleeper = fork { sleep 999 }
    apps = { "web" => { item: { entry: { "healthcheck" => { "timeout" => 1 } }, hostname: "app.localhost", port: port }, app: Struct.new(:pid).new(sleeper) } }
    results = Yamine::Readiness.wait_all(apps, sink: nil)
    assert_equal "timeout", results.first[:status]
    assert_match(/no healthy response/, results.first[:detail])
  ensure
    Process.kill("TERM", sleeper) rescue nil
    Process.wait(sleeper) rescue nil
  end

  def test_wait_all_fail_when_pid_dead
    dead = fork { exit 0 }
    Process.wait(dead) rescue nil
    port = Yamine::Ports.find_free
    apps = { "web" => { item: { entry: {}, hostname: "app.localhost", port: port }, app: Struct.new(:pid).new(dead) } }
    results = Yamine::Readiness.wait_all(apps, sink: nil)
    assert_equal "fail", results.first[:status]
    assert_match(/process exited/, results.first[:detail])
  end

  def test_wait_all_healthcheck_path
    port = Yamine::Ports.find_free
    pid, tmp = fake_http_up(port)
    apps = { "web" => { item: { entry: { "healthcheck" => { "path" => "/up", "timeout" => 3 } }, hostname: "app.localhost", port: port }, app: Struct.new(:pid).new(pid) } }
    results = Yamine::Readiness.wait_all(apps, sink: nil)
    assert_equal "ok", results.first[:status]
  ensure
    Process.kill("TERM", pid) rescue nil
    tmp&.unlink rescue nil
  end

  # A healthcheck probes the app's own listener, which is plaintext even
  # when the proxy serves the route over https. Every call site used to
  # pass the proxy's tls flag, so any app declaring `healthcheck: { path: }`
  # could never boot under the default (TLS-on) proxy: the probe started an
  # SSL handshake against a PLAIN puma, which answers each attempt with
  # "Invalid HTTP format... Are you trying to open an SSL connection to a
  # non-SSL Puma?" and the boot died on timeout.
  def test_healthcheck_probes_backend_plaintext_even_with_tls_proxy
    port = Yamine::Ports.find_free
    pid, tmp = fake_http_up(port)
    resolved_tls = fake_tls_proxy_state
    apps = { "web" => { item: { entry: { "healthcheck" => { "path" => "/up", "timeout" => 3 } }, hostname: "app.localhost", port: port }, app: Struct.new(:pid).new(pid) } }
    results = Yamine::Readiness.wait_all(apps, sink: nil)
    assert_equal "ok", results.first[:status],
      "healthcheck must not speak TLS to the backend port (proxy tls=#{resolved_tls})"
  ensure
    Process.kill("TERM", pid) rescue nil
    tmp&.unlink rescue nil
  end

  def fake_tls_proxy_state
    dir = Dir.mktmpdir
    File.write(File.join(dir, "proxy.tls"), "1")
    ENV["YAMINE_STATE_DIR"] = dir
    Yamine::ProxyControl.proxy_tls(Yamine::RouteStore.new(dir))
  ensure
    ENV.delete("YAMINE_STATE_DIR")
    FileUtils.remove_entry(dir) rescue nil
  end

  # The probe surface itself has no tls keyword: TLS is the proxy's job,
  # and Readiness dials localhost backends directly.
  def test_probe_signatures_reject_tls
    refute_includes Yamine::Readiness.method(:probe).parameters.map(&:last), :tls
    refute_includes Yamine::Readiness.method(:probe_http).parameters.map(&:last), :tls
    refute_includes Yamine::Readiness.method(:wait_all).parameters.map(&:last), :tls
    refute_includes Yamine::Readiness.method(:wait_healthy).parameters.map(&:last), :tls
  end

  def test_wait_all_healthcheck_path_non_2xx_is_unhealthy
    port = Yamine::Ports.find_free
    pid, tmp = fake_http_500(port)
    apps = { "web" => { item: { entry: { "healthcheck" => { "path" => "/up", "timeout" => 1 } }, hostname: "app.localhost", port: port }, app: Struct.new(:pid).new(pid) } }
    results = Yamine::Readiness.wait_all(apps, sink: nil)
    assert_includes %w[fail timeout], results.first[:status]
  ensure
    Process.kill("TERM", pid) rescue nil
    tmp&.unlink rescue nil
  end

  def test_wait_all_concurrent_processes
    ports = Array.new(2) { Yamine::Ports.find_free }
    pairs = ports.map { |p| fake_tcp(p) }
    pids = pairs.map(&:first)
    tmps = pairs.map(&:last)
    apps = ports.each_with_index.to_h do |port, i|
      name = "p#{i}"
      [name, { item: { entry: {}, hostname: "#{name}.localhost", port: port }, app: Struct.new(:pid).new(pids[i]) }]
    end
    results = Yamine::Readiness.wait_all(apps, sink: nil)
    assert_equal %w[ok ok], results.map { |r| r[:status] }.sort
  ensure
    pids&.each { |pid| Process.kill("TERM", pid) rescue nil }
    tmps&.each { |t| t.unlink rescue nil }
  end
end

class WaitPayloadTest < Minitest::Test
  def resolved
    Struct.new(:app).new("myapp")
  end

  def test_success_with_db
    r = resolved
    wait = [{ name: "web", status: "ok", duration_ms: 120 }]
    payload = Yamine::WaitPayload.success(r, wait, urls: { "web" => "https://myapp.localhost" },
      db_name: "myapp_development", db_url: "postgres://u@/myapp_development", created: true)
    assert payload[:ok]
    assert_equal "myapp", payload[:service]
    assert_equal "https://myapp.localhost", payload[:urls]["web"]
    assert_equal "myapp_development", payload[:db][:name]
    assert payload[:db][:created]
  end

  def test_success_without_db
    r = resolved
    payload = Yamine::WaitPayload.success(r, [{ name: "web", status: "ok", duration_ms: 5 }],
      urls: { "web" => "https://myapp.localhost" }, db_name: nil, db_url: nil, created: false)
    assert_nil payload[:db]
  end

  def test_failure_payload
    r = resolved
    failed = { name: "web", phase: "process", detail: "no healthy response within 30s (Connection refused)" }
    payload = Yamine::WaitPayload.failure(r,
      [{ name: "web", status: "timeout" }, { name: "worker", status: "ok" }],
      failed: failed, log_tail: { path: "/tmp/log/yamine-web.log", tail: "last lines\n" })
    refute payload[:ok]
    assert_equal "web", payload[:failed_process]
    assert_equal "process", payload[:phase]
    assert_match(/Connection refused/, payload[:detail])
    assert_equal "last lines\n", payload[:log_tail]
  end
end

class FatalLineTest < Minitest::Test
  def log_with(content)
    tmp = Tempfile.new(["fatal-", ".log"])
    tmp.write(content)
    tmp.close
    tmp
  end

  def test_recognizes_already_running_pid
    tmp = log_with("=> Booting Puma\nA server is already running (pid: 28378, file: tmp/pids/server.pid).\nExiting\n")
    detail = Yamine::Readiness.fatal_line(tmp.path)
    assert_match(/another server is already running \(pid 28378\)/, detail)
    assert_match(/stale tmp\/pids\/server\.pid/, detail)
  end

  def test_recognizes_address_in_use
    tmp = log_with("Errno::EADDRINUSE: Address already in use - bind(2) for 127.0.0.1:4563\n")
    assert_match(/address already in use/, Yamine::Readiness.fatal_line(tmp.path))
  end

  def test_recognizes_missing_gems
    tmp = log_with("Bundler::GemNotFound: Could not find rack-3.2.1 in locally installed gems\n")
    assert_match(/gems missing/, Yamine::Readiness.fatal_line(tmp.path))
  end

  def test_recognizes_missing_database
    tmp = log_with("ActiveRecord::NoDatabaseError: We could not find your database: anywaye_development\n")
    assert_match(/database unreachable or missing/, Yamine::Readiness.fatal_line(tmp.path))
  end

  def test_returns_nil_for_ordinary_log
    tmp = log_with("=> Booting Puma\n=> Rails 8.1.3 application starting in development\n")
    assert_nil Yamine::Readiness.fatal_line(tmp.path)
  end

  def test_returns_nil_for_missing_file
    assert_nil Yamine::Readiness.fatal_line("/nonexistent/yamine-web.log")
    assert_nil Yamine::Readiness.fatal_line(nil)
  end

  def test_latest_fatal_wins
    tmp = log_with("A server is already running (pid: 1, file: x).\n...\nA server is already running (pid: 2, file: x).\n")
    assert_match(/pid 2/, Yamine::Readiness.fatal_line(tmp.path))
  end
end

class ServerPidConflictTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "tmp", "pids"))
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def write_pid(content)
    File.write(File.join(@dir, "tmp", "pids", "server.pid"), content)
  end

  def test_no_file_is_no_conflict
    ok, detail, pid = Yamine::Readiness.server_pid_conflict(@dir)
    assert ok
    assert_nil detail
    assert_nil pid
  end

  def test_dead_pid_is_no_conflict
    dead = fork { exit 0 }
    Process.wait(dead)
    write_pid(dead.to_s)
    ok, _detail, _pid = Yamine::Readiness.server_pid_conflict(@dir)
    assert ok, "a stale (dead) pidfile must not block boot — Rails overwrites it"
  end

  def test_live_pid_is_conflict
    write_pid(Process.pid.to_s)
    ok, detail, pid = Yamine::Readiness.server_pid_conflict(@dir)
    refute ok
    assert_equal Process.pid, pid
    assert_match(/already running \(pid #{Process.pid}/, detail)
  end

  def test_garbage_pidfile_is_no_conflict
    write_pid("not-a-pid\n")
    ok, _detail, _pid = Yamine::Readiness.server_pid_conflict(@dir)
    assert ok
  end
end
