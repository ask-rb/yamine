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

  # `yamine list` labels each route with the state of the APP, so the
  # fixture has to be a backend: the route's own pid is the yamine
  # process that registered it, and asking that one whether the app is
  # alive is how every crashed backend used to read as "running". The
  # sidecar (state_dir/backend-<hostname>.pid) is where the app's pid
  # lives, so that is what the label is now read from.
  def test_list_shows_liveness_labels
    dir = Dir.mktmpdir
    orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = dir
    store = Yamine::RouteStore.new(dir)
    store.add_route("up.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    # This process is alive, so it stands in for a live backend.
    File.write(File.join(dir, "backend-up.localhost.pid"), "#{Process.pid}\n")
    _code, out = capture { Yamine::CLI.run(["list"]) }
    assert_includes out, "running"
    assert_includes out, "backend #{Process.pid}"
  ensure
    ENV["YAMINE_STATE_DIR"] = orig
    FileUtils.remove_entry(dir) if dir
  end

  # The other half of the same fix, and the case the old label could not
  # express: the process that registered the route is still there, the
  # app it booted is not. That is not "running", and it is not
  # "owner-gone" either.
  def test_list_reports_a_dead_app_under_a_live_owner
    dir = Dir.mktmpdir
    orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = dir
    store = Yamine::RouteStore.new(dir)
    store.add_route("crashed.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp")
    dead = spawn("true")
    Process.wait(dead)
    File.write(File.join(dir, "backend-crashed.localhost.pid"), "#{dead}\n")
    _code, out = capture { Yamine::CLI.run(["list"]) }
    assert_includes out, "backend-gone"
    refute_includes out, "crashed.localhost  ->  127.0.0.1:4002  (pid"
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

# ProcessTree is what makes a stop reach the process BEHIND the `sh -c`
# wrapper that every boot process is spawned behind. The decision under
# test is "given what the kernel says about this pid, what do we
# signal?" — a negative pid means "the process group whose id is that
# number", so a pid that does not lead a group must never be signalled
# that way: the number could be somebody else's group entirely.
class ProcessTreeSignalTest < Minitest::Test
  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue SystemCallError
    false
  end

  def test_a_group_leader_is_signalled_by_group_id
    Process.stubs(:getpgid).returns(4242)

    # The whole tree in one syscall: this negative pid is the fix.
    Process.expects(:kill).with("TERM", -4242)
    assert Yamine::ProcessTree.term(4242)
  end

  def test_a_pid_that_leads_no_group_is_signalled_on_its_own
    # In group 99, not group 4242: the number is not the group.
    Process.stubs(:getpgid).returns(99)

    Process.expects(:kill).with("TERM", 4242)
    assert Yamine::ProcessTree.term(4242)
  end

  def test_a_group_signal_that_fails_falls_back_to_the_pid
    Process.stubs(:getpgid).returns(4242)
    Process.stubs(:kill).with("TERM", -4242).raises(Errno::ESRCH)

    Process.expects(:kill).with("TERM", 4242)
    assert Yamine::ProcessTree.term(4242)
  end

  # A pid that is already gone is the state every stop path wants, so it
  # is a false return and not an exception: `yamine stop` branches on it
  # to report the backend as gone.
  def test_a_dead_pid_is_false_and_not_an_error
    Process.stubs(:getpgid).raises(Errno::ESRCH)
    Process.stubs(:kill).raises(Errno::ESRCH)

    refute Yamine::ProcessTree.term(4242)
  end

  def test_a_missing_pid_is_false_and_signals_nothing
    Process.expects(:kill).never

    refute Yamine::ProcessTree.term(nil)
    refute Yamine::ProcessTree.term(0)
  end

  # The reading the record exists to override. `pgroup: true` puts the
  # setpgid in the child, so "still in my group" can be a true answer
  # about a process that IS a leader — and the stop must not degrade to
  # the single-pid signal on it.
  def test_a_recorded_spawn_is_a_leader_whatever_the_kernel_says
    Process.stubs(:getpgid).returns(99)

    # A command that exits on its own: the signals are stubbed here, so
    # there is nothing to clean up afterwards.
    pid = Yamine::ProcessTree.spawn("true", out: File::NULL)
    Process.detach(pid)

    Process.expects(:kill).with("TERM", -pid)
    assert Yamine::ProcessTree.term(pid)
  end

  # The other reading. A process group outlives its leader: a `sh -c`
  # shell that died on its own leaves the app behind it running in that
  # group, and the group signal is the only handle left on it — ESRCH
  # for the dead shell reads exactly like "leads no group".
  def test_a_recorded_spawn_still_signals_its_group_once_the_leader_is_gone
    Yamine::ProcessTree.note_group_leader(4242)
    Process.stubs(:getpgid).raises(Errno::ESRCH)

    Process.expects(:kill).with("TERM", -4242)
    assert Yamine::ProcessTree.term(4242)
  end

  # ...and the record is about the spawn, not about the pid forever: a
  # pid that gets recycled must fall back to what the kernel says.
  def test_a_recorded_pid_is_forgotten_once_it_has_been_stopped
    pid = Yamine::ProcessTree.spawn("sleep", "30", out: File::NULL)
    Process.detach(pid)
    assert Yamine::ProcessTree.term(pid)

    refute Yamine::ProcessTree.known_group_leader?(pid)
    # Reused pid, now some unrelated process that leads no group.
    Process.stubs(:getpgid).returns(7)
    refute Yamine::ProcessTree.group_leader?(pid)
  end

  # A trap handler is not a normal call site. yamine stops its processes
  # from inside one (BootCommand.trap_cleanup, i.e. Ctrl-C), and
  # Mutex#synchronize raises "can't be called from trap context" there
  # — which turns "the stop ran" into "the whole tree is still up".
  # Delivered to this very process, so the real handler runs.
  def test_a_stop_works_from_inside_a_trap_handler
    pid = Yamine::ProcessTree.spawn("sleep", "30", out: File::NULL)
    Process.detach(pid)
    Signal.trap("USR1") { Yamine::ProcessTree.term(pid) }
    Process.kill("USR1", Process.pid)

    reaped = false
    deadline = Time.now + 5
    until reaped || Time.now > deadline
      sleep 0.05
      reaped = !alive?(pid)
    end
    assert reaped, "a stop issued from a trap handler must actually stop the tree"
  ensure
    Signal.trap("USR1", "DEFAULT")
    Yamine::ProcessTree.term(pid, signal: "KILL") if pid
  end

  # The other half, against the kernel rather than a record: a pgroup
  # spawn really does become a leader. Asked with a bound, because the
  # answer is settled a few microseconds after the spawn returns.
  def test_a_pgroup_spawn_becomes_its_own_leader
    pid = Process.spawn("sleep", "30", pgroup: true, out: File::NULL)
    Process.detach(pid)

    deadline = Time.now + 5
    sleep 0.01 until Yamine::ProcessTree.group_leader?(pid) || Time.now > deadline
    assert Yamine::ProcessTree.group_leader?(pid)
  ensure
    Yamine::ProcessTree.term(pid, signal: "KILL") if pid
  end
end
