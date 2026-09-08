# frozen_string_literal: true

# End-to-end tests that boot real backends (Puma). Slow by design:
# run with `rake test:e2e`, not the default `rake test`.

require_relative "../test_helper"

class BackendSidecarTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
    @runner = Yamine::Runner.new(store: @store, on_log: ->(m) {})
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_boot_writes_sidecar
    app_dir = Dir.mktmpdir
    File.write(File.join(app_dir, "config.ru"),
      "run ->(env) { [200, {}, ['hi']] }\n")
    app = @runner.boot_managed(name: "sidecar", hostname: "sidecar.localhost",
      url: "https://sidecar.localhost", dir: app_dir)
    sidecar = File.join(@dir, "backend-sidecar.localhost.pid")
    assert File.file?(sidecar)
    assert_equal app.pid.to_s, File.read(sidecar).strip
    Process.kill("TERM", app.pid)
  ensure
    FileUtils.remove_entry(app_dir) if app_dir
  end
end

class SupervisorBootOnRequestIntegrationTest < Minitest::Test
  # The full puma-dev cycle: request -> 200; backend killed; supervisor
  # marks dead; next request transparently boots a new backend -> 200.
  def test_boot_on_request_after_crash
    app_dir = "/Users/kaka/Code/ask-rb/yamine-apps/bare-rack"
    skip "fixture fleet not present" unless File.file?(File.join(app_dir, "config.ru"))

    state = Dir.mktmpdir
    new_pid = nil
    store = Yamine::RouteStore.new(state)
    runner = Yamine::Runner.new(store: store, on_log: ->(m) {})
    app = runner.boot_managed(name: "bare-rack", hostname: "crash-test.localhost",
      url: "https://crash-test.localhost", dir: app_dir)
    first_pid = app.pid

    sup = Yamine::Supervisor.new(store: store, runner: runner,
      interval: 0.2, idle_timeout: 900, on_event: ->(m) { })
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false, supervisor: sup)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accept = Thread.new do
      loop do
        begin
          s = server.accept
          Thread.new { proxy.send(:handle, s) }
        rescue StandardError
          break
        end
      end
    end
    sleep 0.3

    assert_equal "200", get_status(port, "crash-test.localhost")

    Process.kill("KILL", first_pid)
    sup.tick
    sleep 0.1

    assert_equal "200", get_status(port, "crash-test.localhost"),
      "proxy should boot-on-request after crash"
    new_pid = File.read(File.join(state, "backend-crash-test.localhost.pid")).to_i
    refute_equal first_pid, new_pid, "a new backend should have been booted"
  ensure
    accept&.kill
    server&.close
    if new_pid
      Process.kill("TERM", new_pid) rescue nil
    else
      FileUtils.rm_f(File.join(app_dir, "tmp", "sockets", "yamine.sock"))
    end
    FileUtils.remove_entry(state) if state
  end

  def get_status(port, host)
    sock = TCPSocket.new("127.0.0.1", port)
    sock.write("GET / HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
    sock.read.lines.first.split(" ")[1]
  ensure
    sock&.close
  end
end
