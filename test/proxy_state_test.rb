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
