# frozen_string_literal: true

require_relative "test_helper"

class CommandSplitTest < Minitest::Test
  def test_dispatcher_routes_new_commands
    assert_includes Yamine::CLI::SUBCOMMANDS, "status"
    assert_includes Yamine::CLI::SUBCOMMANDS, "open"
  end

  def test_old_helpers_still_work_via_cli
    cli = Yamine::CLI.new
    cmd = ["bundle", "exec", "jekyll", "serve"]
    assert_equal cmd + ["--port", "4123", "--host", "127.0.0.1"],
      cli.send(:inject_port_flags, cmd, 4123)
  end

  def test_status_prints_effective_context
    dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(dir, "config")); File.write(File.join(dir, "config", "local.yml"), "service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  api:\n    cmd: s\n    proxy: true")
    code, out = nil, nil
    Dir.chdir(dir) do
      code, out = capture { Yamine::CLI.run(["status"]) }
    end
    assert_equal 0, code
    assert_includes out, "app:"
    assert_includes out, "myapp"
    assert_includes out, "myapp.localhost"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_stop_exit_codes
    dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "local.yml"),
      "service: myapp\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    state = Dir.mktmpdir
    orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = state
    Dir.chdir(dir) do
      # No route here -> exit 2.
      code, out = capture { Yamine::CLI.run(["stop"]) }
      assert_equal 2, code
      assert_includes out, "No yamine app running here"
    end
  ensure
    ENV["YAMINE_STATE_DIR"] = orig
    FileUtils.remove_entry(dir) if dir
    FileUtils.remove_entry(state) if state
  end

  def test_list_shows_liveness_labels
    dir = Dir.mktmpdir
    orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = dir
    store = Yamine::RouteStore.new(dir)
    store.add_route("up.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    _code, out = capture { Yamine::CLI.run(["list"]) }
    assert_includes out, "running"
  ensure
    ENV["YAMINE_STATE_DIR"] = orig
    FileUtils.remove_entry(dir) if dir
  end

  def capture
    out = StringIO.new
    orig = $stdout
    $stdout = out
    result = begin
      yield
    rescue SystemExit => e
      e.status
    end
    [result, out.string]
  ensure
    $stdout = orig
  end
end

class OwnershipTest < Minitest::Test
  def test_noop_when_not_root_or_no_sudo_user
    # In test env we are not root-via-sudo: fix must be a silent no-op.
    dir = Dir.mktmpdir
    file = File.join(dir, "x")
    File.write(file, "1")
    Yamine::Ownership.fix(file)
    assert File.file?(file)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_invoking_user_nil_without_sudo
    orig = ENV.delete("SUDO_USER")
    assert_nil Yamine::Ownership.invoking_user
  ensure
    ENV["SUDO_USER"] = orig if orig
  end

  def test_doctor_state_check_passes_on_writable_dir
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    check = Yamine::Doctor.check_state_dir(store)
    assert check.ok
    assert_includes check.message, "writable"
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end

class ProxyHardeningTest < Minitest::Test
  def test_connection_cap_rejects_with_503
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false, max_connections: 0)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accept = Thread.new do
      s = server.accept
      # Simulate the accept loop's admit? path directly.
      admitted = proxy.send(:admit?)
      refute admitted, "cap of 0 must refuse"
      s.close
    end
    sock = TCPSocket.new("127.0.0.1", port)
    sock.close
    accept.join(2)
  ensure
    server&.close
    FileUtils.remove_entry(dir) if dir
  end

  def test_route_cache_reflects_mtime_changes
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    store.add_route("a.localhost", "127.0.0.1:4001", 0, kind: "tcp")
    proxy = Yamine::Proxy.new(store: store, port: 0, tls: false)
    first = proxy.send(:cached_routes)
    assert_equal ["a.localhost"], first.map { |r| r["hostname"] }
    # Mutating the file bumps mtime: the next read sees it immediately
    # (no TTL race for boot-then-curl agents). Ensure distinct mtime.
    sleep 0.05
    File.write(File.join(dir, "routes.json"), "[]")
    second = proxy.send(:cached_routes)
    assert_equal [], second.map { |r| r["hostname"] }
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_oversize_hostname_not_routed
    proxy = Yamine::Proxy.new(store: nil)
    routes = [{ "hostname" => "myapp.localhost" }]
    assert_nil proxy.route("#{"a" * 300}.localhost", routes)
  end

  def test_ours_probes_ipv6_too
    # ours? must try both loopbacks: a v6-only listener is still ours.
    server = TCPServer.new("::1", 0)
    port = server.addr[1]
    Thread.new do
      loop do
        s = server.accept
        head = +""
        while (l = s.gets)
          head << l
          break if head =~ /\r\n\r\n\z/
        end
        s.write("HTTP/1.1 404 Not Found\r\nX-Yamine: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        s.close
      rescue StandardError
        break
      end
    end
    assert Yamine::ProxyControl.ours?(port, tls: false),
      "health check must succeed against an IPv6 loopback listener"
  ensure
    server&.close
  end
end

class RailsDevHostTest < Minitest::Test
  def test_child_env_sets_rails_development_hosts
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, dir, url: "https://myapp.localhost",
      port: 4001, rails_dev_host: "myapp.localhost")
    assert_equal "myapp.localhost", env["RAILS_DEVELOPMENT_HOSTS"]
    assert_equal "https://myapp.localhost", env["YAMINE_URL"]
    assert_equal "4001", env["PORT"]
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_child_env_without_rails_dev_host_sets_nothing
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, dir, url: "http://x.localhost", port: 4001)
    refute env.key?("RAILS_DEVELOPMENT_HOSTS")
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_boot_run_forwards_rails_dev_host
    dir = Dir.mktmpdir
    store = Yamine::RouteStore.new(dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    app = runner.boot_run(name: "web", hostname: "myapp.localhost",
      url: "http://myapp.localhost:4001", dir: dir,
      command: ["sh", "-c", "exit 0"], port: 4001,
      rails_dev_host: "myapp.localhost")
    assert_equal "myapp.localhost", app.hostname
    # The route is registered with the store.
    assert store.find("myapp.localhost")
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
