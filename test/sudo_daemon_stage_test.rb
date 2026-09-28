# frozen_string_literal: true

require_relative "test_helper"

# The --no-service sudo-daemon fallback must not reintroduce
# root-executes-user-writable-code: a privileged spawn runs the staged
# root-owned payload, staging it first under the same
# human-authorized sudo when missing. The unprivileged spawn path is
# untouched. Hermetic: argv is asserted without spawning anything, and
# sudo is stubbed on the Command seam.
class SudoDaemonSpawnTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @orig_root = ENV["YAMINE_PRIVILEGED_ROOT"]
    ENV["YAMINE_PRIVILEGED_ROOT"] = File.join(@dir, "yamine")
    @store = Yamine::RouteStore.new(@dir)
    @ctx = Yamine::CLI::Context.new
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
    ENV["YAMINE_PRIVILEGED_ROOT"] = @orig_root
    FileUtils.remove_entry(@dir)
  end

  def silently
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = StringIO.new, StringIO.new
    result = yield
    [result, $stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  # Everything sudo executes, minus the invocation wrapping: the
  # `sudo`/`env` prefix and VAR=value data are how it is invoked, not
  # what runs as root (no grant rule covers this path, so exact-argv
  # matching is irrelevant here — the payload is the point).
  def executed_argv(cmd)
    rest = cmd.dup
    rest.shift if rest.first == "sudo"
    rest.shift if rest.first == "env"
    rest.reject! { |w| w.include?("=") }
    rest
  end

  def test_privileged_spawn_executes_the_staged_payload
    cmd = Yamine::ProxyControl.daemon_cmd(store: @store, port: 443, tls: true, sudo: true)
    exe = executed_argv(cmd)

    assert_equal [RbConfig.ruby, Yamine::PrivilegedPayload.bin_path,
      "proxy", "start", "--foreground", "--port", "443"], exe
    payload = exe[1]
    refute_match(%r{/gems/yamine-}, payload,
      "root must not execute a version-stamped gem path")
    refute payload.start_with?(Yamine::Certs.home + "/"),
      "root must not execute a payload from a user home"
  end

  def test_unprivileged_spawn_is_unchanged
    cmd = Yamine::ProxyControl.daemon_cmd(store: @store, port: 1355, tls: true, sudo: false)

    assert_equal [RbConfig.ruby, Yamine::ProxyControl.bin_path,
      "proxy", "start", "--foreground", "--port", "1355"], cmd
  end

  def test_privileged_spawn_stages_first_when_missing
    Yamine::PrivilegedPayload.stubs(:staged?).returns(false).then.returns(true)
    Yamine::Command.expects(:run)
      .with("sudo", "env", "YAMINE_STATE_DIR=#{@dir}",
        RbConfig.ruby, Yamine::ProxyControl.bin_path,
        "service", "stage", "--internal")
      .returns(true)

    assert Yamine::ProxyControl.ensure_staged_payload!(@store)
  end

  def test_privileged_spawn_skips_staging_when_present
    Yamine::PrivilegedPayload.stubs(:staged?).returns(true)
    Yamine::Command.expects(:run).never

    assert Yamine::ProxyControl.ensure_staged_payload!(@store)
  end

  def test_failed_staging_fails_with_the_fix_not_a_spawn
    Yamine::PrivilegedPayload.stubs(:staged?).returns(false)
    Yamine::Command.stubs(:run).returns(false)

    err = assert_raises(Yamine::ProxyNotRunningError) do
      silently { Yamine::ProxyControl.ensure_staged_payload!(@store) }
    end

    assert_match(/sudo yamine service install|yamine setup/, err.message)
  end

  def test_stage_refuses_non_root
    Yamine::ProxyControl.stubs(:root?).returns(false)

    assert_raises(Yamine::Error) do
      Yamine::CLI::SystemCommand.service_stage(@ctx, ["--internal"])
    end
  end

  def test_stage_refuses_root_without_the_internal_marker
    Yamine::ProxyControl.stubs(:root?).returns(true)

    assert_raises(Yamine::Error) do
      Yamine::CLI::SystemCommand.service_stage(@ctx, [])
    end
  end

  def test_stage_root_half_stages_and_reports
    Yamine::ProxyControl.stubs(:root?).returns(true)
    Yamine::PrivilegedPayload.expects(:stage!).with(state_dir: @dir).returns(Yamine::VERSION)

    ok, out, = silently { Yamine::CLI::SystemCommand.service_stage(@ctx, ["--internal"]) }

    assert ok
    assert_match(/Staged privileged payload v#{Regexp.escape(Yamine::VERSION)}/, out)
  end
end
