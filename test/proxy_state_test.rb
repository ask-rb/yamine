# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "socket"

# The proxy records its own pid/port/tls/version so every other command
# has one source of truth. The launchd/systemd service runs
# `proxy start --foreground`, which recorded NOTHING — so after `yamine
# setup` the files still held the previous daemon's port, and a machine
# serving clean https://<app>.localhost on 443 had `yamine start` baking
# :8443 into URLs, doctor warning about the dead 8443, and `proxy stop`
# aiming at a pid that was already gone.
class ProxyStateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  def test_records_pid_port_tls_and_version
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: 443, tls: true)

    assert_equal 4321, Yamine::ProxyControl.read_pid(@store)
    assert_equal 443, Yamine::ProxyControl.proxy_port(@store)
    assert Yamine::ProxyControl.proxy_tls(@store)
    assert_equal Yamine::VERSION, Yamine::ProxyControl.proxy_version(@store)
  end

  def test_records_plaintext_scheme
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: 80, tls: false)

    refute Yamine::ProxyControl.proxy_tls(@store)
  end

  def test_clear_removes_the_version_marker_too
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: 443, tls: true)
    Yamine::ProxyControl.clear_pid(@store)

    assert_nil Yamine::ProxyControl.proxy_version(@store)
    assert_nil Yamine::ProxyControl.proxy_port(@store)
  end

  # serving_port proves ownership; active_port only proves liveness.
  # NOTE: these must not assume the scheme default (443) is free — on a
  # workstation with the root service installed it is not, and these
  # tests would then be asserting against the real proxy.
  def test_serving_port_nil_when_nothing_listens
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: 49_001, tls: true)
    Yamine::ProxyControl.stubs(:ours?).returns(false)

    assert_equal 49_001, Yamine::ProxyControl.proxy_port(@store)
    assert_nil Yamine::ProxyControl.serving_port(@store)
  end

  # The stale-state shape: an old port recorded, nothing of ours on it,
  # and the real proxy on the scheme default. serving_port must find the
  # default rather than reporting the stale port as serving.
  def test_serving_port_falls_back_to_scheme_default
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: 49_002, tls: true)
    # Ours on the default, not ours on the stale port.
    Yamine::ProxyControl.stubs(:ours?).with(49_002, tls: true).returns(false)
    Yamine::ProxyControl.stubs(:ours?).with(443, tls: true).returns(true)

    assert_equal 443, Yamine::ProxyControl.serving_port(@store),
      "the live default port must win over the stale recorded one"
  end

  # The case that matters after `yamine setup`: the root service serves
  # 443 while a leftover daemon from before still sits on another port.
  # Reporting the leftover would present the downgraded URL as the state
  # of the machine, which is exactly what the user just fixed.
  def test_serving_port_prefers_default_over_a_lingering_other_port
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: 8443, tls: true)
    Yamine::ProxyControl.stubs(:ours?).with(8443, tls: true).returns(true)
    Yamine::ProxyControl.stubs(:ours?).with(443, tls: true).returns(true)

    assert_equal 443, Yamine::ProxyControl.serving_port(@store),
      "the clean default must be reported even while an old port lingers"
  end

  # ...but with no default-port proxy, the deliberate non-default one is
  # the answer (CI/sandbox, where 443 is impossible).
  def test_serving_port_reports_recorded_when_no_default_proxy
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: 8443, tls: true)
    Yamine::ProxyControl.stubs(:ours?).with(8443, tls: true).returns(true)
    Yamine::ProxyControl.stubs(:ours?).with(443, tls: true).returns(false)

    assert_equal 8443, Yamine::ProxyControl.serving_port(@store)
  end

  # active_port (the hot path) keeps the recorded port while it is live,
  # and falls back to the default once it is not.
  def test_active_port_stale_file_falls_back_to_default
    port = free_port
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: port, tls: true)

    assert_equal 443, Yamine::ProxyControl.active_port(@store),
      "a recorded port nobody serves must not be reused"
  end

  def test_active_port_honores_live_recorded_port
    port = free_port
    server = TCPServer.new("127.0.0.1", port)
    Yamine::ProxyControl.write_proxy_state(@store, pid: 4321, port: port, tls: true)

    assert_equal port, Yamine::ProxyControl.active_port(@store)
  ensure
    server&.close
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end

# doctor must report the proxy that is actually serving, and name state
# that disagrees with reality — neither is visible from the URL bar.
class DoctorProxyStateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  def test_warns_when_state_port_disagrees_with_serving
    Yamine::ProxyControl.write_proxy_state(@store, pid: 1, port: 8443, tls: true)
    check = Yamine::Doctor.check_proxy_state(@store, 443)

    assert check.warn?
    assert_match(/state says port 8443/, check.message)
    assert_match(/proxy is on 443/, check.message)
  end

  def test_warns_when_state_port_has_no_proxy_behind_it
    Yamine::ProxyControl.write_proxy_state(@store, pid: 1, port: 8443, tls: true)
    check = Yamine::Doctor.check_proxy_state(@store, nil)

    assert check.warn?
    assert_match(/no yamine proxy is serving/, check.message)
  end

  def test_warns_when_the_running_proxy_is_an_older_version
    Yamine::ProxyControl.write_proxy_state(@store, pid: 1, port: 443, tls: true)
    File.write(File.join(@dir, "proxy.version"), "0.0.1\n")
    check = Yamine::Doctor.check_proxy_state(@store, 443)

    assert check.warn?
    assert_match(/running proxy is v0\.0\.1/, check.message)
    assert_match(/service install/, check.message)
  end

  # The service that prompted this check: installed by a gem older than
  # the version marker, so it reports no version at all. Silence here was
  # the version check being blind to its own motivating case.
  def test_warns_when_a_serving_proxy_reports_no_version
    check = Yamine::Doctor.check_proxy_state(@store, 443)

    assert check.warn?
    assert_match(/does not report a version/, check.message)
    assert_match(/service install/, check.message)
  end

  # ...but no version AND nothing serving is just a machine with no proxy.
  def test_no_version_without_a_serving_proxy_is_not_a_warning
    check = Yamine::Doctor.check_proxy_state(@store, nil)

    assert check.ok
    refute check.warn?
  end

  def test_consistent_state_is_ok_not_warn
    Yamine::ProxyControl.write_proxy_state(@store, pid: 1, port: 443, tls: true)
    check = Yamine::Doctor.check_proxy_state(@store, 443)

    assert check.ok
    refute check.warn?
    assert_equal "consistent", check.message
  end

  def test_no_state_at_all_is_ok
    check = Yamine::Doctor.check_proxy_state(@store, nil)

    assert check.ok
    refute check.warn?
  end
end

# A root service cannot be signalled by the unprivileged CLI. Reporting
# success there would leave the proxy serving with nothing on disk to
# find it by.
class ProxyStopPermissionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  def test_stop_reports_needs_root_instead_of_claiming_success
    Yamine::ProxyControl.write_proxy_state(@store, pid: 42_424, port: 443, tls: true)
    Yamine::ProxyControl.stubs(:pid_alive?).returns(true)
    Process.stubs(:kill).raises(Errno::EPERM)

    assert_equal :needs_root, Yamine::ProxyControl.stop(@store)
    assert_equal 443, Yamine::ProxyControl.proxy_port(@store),
      "state must survive a stop we could not perform"
  end

  # Nothing recorded, but our proxy is serving — the shape left by a
  # root service installed by a gem that did not record state. Saying
  # "not running" would send someone hunting for a process that is right
  # there on 443.
  def test_stop_reports_needs_root_when_only_the_service_is_serving
    Yamine::ProxyControl.stubs(:serving_port).returns(443)

    assert_equal :needs_root, Yamine::ProxyControl.stop(@store)
  end

  def test_stop_reports_not_running_when_truly_nothing_is_there
    Yamine::ProxyControl.stubs(:serving_port).returns(nil)

    assert_equal :not_running, Yamine::ProxyControl.stop(@store)
  end

  def test_stop_clears_state_on_a_normal_stop
    Yamine::ProxyControl.write_proxy_state(@store, pid: 42_424, port: 443, tls: true)
    Yamine::ProxyControl.stubs(:pid_alive?).returns(true)
    Process.stubs(:kill).returns(1)

    assert_equal :stopped, Yamine::ProxyControl.stop(@store)
    assert_nil Yamine::ProxyControl.proxy_port(@store)
  end
end

# spawn_daemon tells the truth: never spawn over a live proxy, never
# record a dead pid, and surface the daemon's own log when it dies
# (EACCES on 443, EADDRINUSE on a taken port) instead of a timeout.
class SpawnGuardTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  # The incident: a root service answered the readiness probe while our
  # child died of EACCES, and the dead pid was recorded over real state.
  def test_does_not_spawn_when_proxy_already_serves
    Yamine::ProxyControl.stubs(:ours?).returns(true)
    Yamine::ProxyControl.expects(:spawn).never

    error = assert_raises(Yamine::ProxyAlreadyRunningError) do
      Yamine::ProxyControl.spawn_daemon(store: @store, port: 443, tls: true)
    end
    assert_match(/already serving on port 443/, error.message)
    assert_nil Yamine::ProxyControl.read_pid(@store),
      "nothing may be recorded when nothing was spawned"
  end

  def test_dead_child_raises_with_log_tail
    Yamine::ProxyControl.stubs(:ours?).returns(false)
    Yamine::ProxyControl.stubs(:spawn).returns(999_999)
    Process.stubs(:detach)
    Yamine::ProxyControl.stubs(:pid_alive?).returns(false)
    File.write(File.join(@dir, "proxy.log"),
      "bind failed: Address already in use (EADDRINUSE)\n")

    error = assert_raises(Yamine::ProxyNotRunningError) do
      Yamine::ProxyControl.spawn_daemon(store: @store, port: 443, tls: true)
    end
    assert_match(/exited before serving/, error.message)
    assert_match(/EADDRINUSE/, error.message,
      "the message must carry the log tail showing why the child died")
    assert_nil Yamine::ProxyControl.read_pid(@store)
  end

  # The probe passes, but on another proxy's behalf: our child is dead
  # (the pre-spawn check missed a service that started answering after
  # we spawned). Its pid must never reach the state files.
  def test_never_records_a_pid_that_is_not_alive
    Yamine::ProxyControl.stubs(:ours?).returns(false, true)
    Yamine::ProxyControl.stubs(:spawn).returns(999_999)
    Process.stubs(:detach)
    Yamine::ProxyControl.stubs(:pid_alive?).returns(false)

    error = assert_raises(Yamine::ProxyNotRunningError) do
      Yamine::ProxyControl.spawn_daemon(store: @store, port: 443, tls: true)
    end
    assert_match(/not recording/, error.message)
    assert_nil Yamine::ProxyControl.read_pid(@store),
      "a dead pid must never be written over live state"
  end
end

# `stop` on a dead recorded pid must probe the recorded port first: a
# root service the CLI cannot signal may still be serving it, and
# clearing the state then orphans the live proxy.
class StopDeadPidProbeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  def test_dead_pid_with_serving_proxy_returns_needs_root_and_keeps_state
    Yamine::ProxyControl.write_proxy_state(@store, pid: 42_424, port: 443, tls: true)
    Yamine::ProxyControl.stubs(:pid_alive?).returns(false)
    Yamine::ProxyControl.stubs(:ours?).with(443, tls: true).returns(true)

    assert_equal :needs_root, Yamine::ProxyControl.stop(@store)
    assert_equal 443, Yamine::ProxyControl.proxy_port(@store),
      "state must survive a stop we could not perform"
    assert_equal 42_424, Yamine::ProxyControl.read_pid(@store)
  end

  def test_dead_pid_with_nothing_serving_clears_stale
    Yamine::ProxyControl.write_proxy_state(@store, pid: 42_424, port: 443, tls: true)
    Yamine::ProxyControl.stubs(:pid_alive?).returns(false)
    Yamine::ProxyControl.stubs(:ours?).with(443, tls: true).returns(false)

    assert_equal :stale, Yamine::ProxyControl.stop(@store)
    assert_nil Yamine::ProxyControl.proxy_port(@store)
  end
end

# `clean` must refuse while a proxy it cannot stop is serving: deleting
# the state dir (and untrusting the CA) then would orphan the live
# proxy and break its TLS.
class CleanRootProxyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
    @ctx = Yamine::CLI::Context.new
    @ctx.stubs(:store).returns(@store)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  def capture
    out, err = StringIO.new, StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      yield
      0
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def test_clean_refuses_while_root_proxy_serves
    Yamine::ProxyControl.write_proxy_state(@store, pid: 42_424, port: 443, tls: true)
    Yamine::ProxyControl.stubs(:stop).returns(:needs_root)
    Yamine::Trust.expects(:untrust).never
    Yamine::Hosts.expects(:clean).never

    code, _out, err = capture { Yamine::CLI::SystemCommand.clean(@ctx, []) }

    assert_equal 1, code
    assert_match(%r{kickstart -k system/dev\.yamine}, err)
    assert_match(/service uninstall/, err)
    assert Dir.exist?(@dir), "state must survive a clean that refused"
    assert_equal 443, Yamine::ProxyControl.proxy_port(@store)
  end

  def test_clean_proceeds_after_a_real_stop
    Yamine::ProxyControl.stubs(:stop).returns(:stopped)
    Yamine::Trust.stubs(:untrust).returns({ removed: false })
    Yamine::Hosts.stubs(:clean)

    code, out, = capture { Yamine::CLI::SystemCommand.clean(@ctx, []) }

    assert_equal 0, code
    assert_match(/Cleaned yamine state/, out)
    refute Dir.exist?(@dir)
  end
end

# A bare `proxy start` on a privileged port behaves like the boot path:
# elevate when interactive, fail with the setup hint when not — never a
# doomed unprivileged child, never a false "started".
class ProxyStartPrivilegeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
    @ctx = Yamine::CLI::Context.new
    @ctx.stubs(:store).returns(@store)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  def capture
    out, err = StringIO.new, StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      yield
      0
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def test_privileged_start_without_tty_fails_with_setup_hint_and_spawns_nothing
    Yamine::ProxyControl.stubs(:root?).returns(false)
    @ctx.stubs(:interactive?).returns(false)
    Yamine::ProxyControl.expects(:spawn_daemon).never

    code, _out, err = capture do
      Yamine::CLI::SystemCommand.proxy(@ctx, ["start", "-p", "443"])
    end

    assert_equal 1, code
    assert_match(/needs root/, err)
    assert_match(/yamine setup/, err)
    assert_nil Yamine::ProxyControl.read_pid(@store)
  end

  def test_privileged_start_with_tty_elevates_like_boot
    Yamine::ProxyControl.stubs(:root?).returns(false)
    @ctx.stubs(:interactive?).returns(true)
    spawned = nil
    Yamine::ProxyControl.stubs(:spawn_daemon)
      .with { |**kw| spawned = kw; true }.returns(1234)

    code, out, = capture do
      Yamine::CLI::SystemCommand.proxy(@ctx, ["start", "-p", "443"])
    end

    assert_equal 0, code
    assert_equal true, spawned[:sudo], "privileged ports elevate, like the boot path"
    assert_match(/Proxy started on port 443/, out)
  end

  def test_already_serving_is_reported_not_claimed
    Yamine::ProxyControl.stubs(:spawn_daemon).raises(
      Yamine::ProxyAlreadyRunningError,
      "A yamine proxy is already serving on port 8443 — not starting another.")

    code, out, = capture do
      Yamine::CLI::SystemCommand.proxy(@ctx, ["start", "-p", "8443"])
    end

    assert_equal 0, code
    assert_match(/already serving on port 8443/, out)
    refute_match(/Proxy started/, out)
  end

  def test_failed_spawn_points_at_setup
    Yamine::ProxyControl.stubs(:spawn_daemon).raises(
      Yamine::ProxyNotRunningError, "Proxy did not start on port 8443.")

    code, _out, err = capture do
      Yamine::CLI::SystemCommand.proxy(@ctx, ["start", "-p", "8443"])
    end

    assert_equal 1, code
    assert_match(/yamine setup/, err)
  end
end
