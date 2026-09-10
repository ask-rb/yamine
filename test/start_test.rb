# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class StartCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @state = Dir.mktmpdir
    ENV["YAMINE_STATE_DIR"] = @state
  end

  def teardown
    ENV.delete("YAMINE_STATE_DIR")
    FileUtils.remove_entry(@dir) rescue nil
    FileUtils.remove_entry(@state) rescue nil
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

  def test_help_lists_usage_and_examples
    _code, out, = capture { Yamine::CLI::SystemCommand.start(Yamine::CLI::Context.new, ["--help"]) }
    assert_includes out, "yamine start"
    assert_includes out, "--no-wait"
    assert_includes out, "--variant"
    assert_includes out, "--wait"
  end

  def test_fast_path_skips_setup_when_healthy
    # All doctor checks ok => ensure_workstation! must NOT be called.
    Yamine::Doctor.stubs(:run).returns([
      Yamine::Doctor::Check.new(name: "state", ok: true, message: "writable"),
      Yamine::Doctor::Check.new(name: "disk", ok: true, message: "uses 0 B"),
      Yamine::Doctor::Check.new(name: "proxy", ok: true, message: "listening on port 443"),
      Yamine::Doctor::Check.new(name: "routes", ok: true, message: "no active routes"),
      Yamine::Doctor::Check.new(name: "dns", ok: true, message: "no routes to resolve"),
      Yamine::Doctor::Check.new(name: "ca", ok: true, message: "CA trusted")
    ])
    Yamine::CLI::SystemCommand.expects(:ensure_workstation!).never
    # Stub the boot so we don't actually try to bind a port.
    Yamine::CLI::BootCommand.expects(:run_inferred)
      .with { |ctx, _args| ctx.is_a?(Yamine::CLI::Context) }
      .returns(nil)

    Yamine::CLI::SystemCommand.start(Yamine::CLI::Context.new, [])
  end

  def test_triggers_setup_when_doctor_fails
    Yamine::Doctor.stubs(:run).returns([
      Yamine::Doctor::Check.new(name: "proxy", ok: false, message: "not running")
    ])
    Yamine::CLI::SystemCommand.expects(:ensure_workstation!).with { |ctx| ctx.is_a?(Yamine::CLI::Context) }
    Yamine::CLI::BootCommand.expects(:run_inferred).returns(nil)

    Yamine::CLI::SystemCommand.start(Yamine::CLI::Context.new, [])
  end

  def test_ensure_workstation_covers_ca_proxy_and_hosts
    ctx = Yamine::CLI::Context.new
    Yamine::Certs.stubs(:trusted?).returns(false)
    Yamine::Trust.stubs(:trust).returns({ trusted: true })
    Yamine::ProxyControl.stubs(:listening?).returns(false)
    Yamine::ProxyControl.stubs(:root?).returns(false)
    ctx.stubs(:interactive?).returns(false)
    code, _out, err = capture { Yamine::CLI::SystemCommand.ensure_workstation!(ctx) }
    assert_equal 1, code
    assert_includes err, "yamine setup"
  end

  def test_setup_reached_via_noninteractive_proxy_error_points_at_setup
    Yamine::Certs.stubs(:trusted?).returns(true)
    Yamine::ProxyControl.stubs(:listening?).returns(false)
    Yamine::CLI::Context.any_instance.stubs(:interactive?).returns(false)
    ctx = Yamine::CLI::Context.new
    _code, _out, err = capture do
      Yamine::CLI::SystemCommand.ensure_workstation!(ctx)
    end
    assert_includes err, "yamine setup"
  end

  # ensure_workstation! hardcoded port 443, so YAMINE_PORT — the
  # documented escape hatch for CI and sandboxes "where 443 is
  # impossible" — was ignored by `yamine start`: it demanded root for a
  # port the user had already chosen to avoid.
  def test_ensure_workstation_uses_configured_port_not_443
    ENV["YAMINE_PORT"] = "8443"
    Yamine::Certs.stubs(:trusted?).returns(true)
    Yamine::ProxyControl.stubs(:listening?).returns(false)
    Yamine::ProxyControl.stubs(:ours?).returns(false)
    Yamine::ProxyControl.stubs(:root?).returns(false)
    ctx = Yamine::CLI::Context.new
    ctx.stubs(:interactive?).returns(false)
    spawned = nil
    Yamine::ProxyControl.stubs(:spawn_daemon)
      .with { |**kw| spawned = kw; true }
    Yamine::CLI::SystemCommand.stubs(:wait_for_ours).returns(true)
    Yamine::Hosts.stubs(:sync).returns(true)

    Yamine::CLI::SystemCommand.ensure_workstation!(ctx)

    assert_equal 8443, spawned[:port],
      "an unprivileged YAMINE_PORT must be used, not 443"
    assert_equal false, spawned[:sudo],
      "8443 needs no elevation"
  ensure
    ENV.delete("YAMINE_PORT")
  end

  # The privileged path must still demand sudo and point at setup.
  def test_ensure_workstation_still_requires_setup_for_default_port
    ENV.delete("YAMINE_PORT")
    Yamine::Certs.stubs(:trusted?).returns(true)
    Yamine::ProxyControl.stubs(:listening?).returns(false)
    Yamine::ProxyControl.stubs(:ours?).returns(false)
    Yamine::ProxyControl.stubs(:root?).returns(false)
    ctx = Yamine::CLI::Context.new
    ctx.stubs(:interactive?).returns(false)
    Yamine::CLI::Context.any_instance.stubs(:proxy_port).returns(443)
    _code, _out, err = capture do
      Yamine::CLI::SystemCommand.ensure_workstation!(ctx)
    end

    assert_includes err, "needs root"
    assert_includes err, "yamine setup"
  end
end
