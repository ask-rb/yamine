# frozen_string_literal: true

require_relative "test_helper"

# The passwordless grant after the privileged-path rework: it pins the
# root-owned, version-independent staged payload and keeps only what
# can never introduce or modify root-executed code — the data-only
# hosts sync plus uninstall. Staging new root code stays a
# human-authorized interactive sudo. Hermetic: no real sudo.
class SudoersGrantTest < Minitest::Test
  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      Yamine::CLI.run(args)
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def sudoers_output
    _code, out, = run_cli("sudoers")
    out
  end

  def test_grant_pins_the_staged_version_independent_path
    staged = Yamine::PrivilegedPayload.bin_path

    assert_includes sudoers_output, staged
    refute_match(%r{/gems/yamine-}, sudoers_output,
      "the grant must not pin a version-stamped gem path that rots every release")
  end

  def test_grant_keeps_hosts_sync_for_agents
    assert_includes sudoers_output, "hosts sync"
  end

  def test_grant_keeps_uninstall_which_only_removes
    assert_includes sudoers_output, "service uninstall --internal"
  end

  def test_grant_cannot_introduce_or_modify_root_code
    out = sudoers_output

    refute_includes out, "service install",
      "install stages user-writable source into root-owned paths — a grant for it is arbitrary root code execution"
    refute_includes out, Yamine::ProxyControl.bin_path,
      "the grant must never reference the user-writable gem directory"
  end

  def test_grant_says_to_replace_stale_version_stamped_rules
    assert_match(/re-run|replace/i, sudoers_output)
  end
end

# `service install` after the rework: staging user source into
# root-owned paths is never passwordless. Interactive runs sudo once
# (Touch ID); non-interactive runs fail fast pointing at the human
# step instead of attempting `sudo -n` against a grant that no longer
# covers install.
class ServiceInstallElevationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @ctx = Yamine::CLI::Context.new
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
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

  def test_noninteractive_install_fails_fast_without_touching_sudo
    ENV["CI"] = "1"
    $stdin.stubs(:tty?).returns(false)
    Yamine::ProxyControl.stubs(:root?).returns(false)
    Yamine::Command.expects(:run).never

    ok, _out, err = silently { Yamine::CLI::SystemCommand.service_install(@ctx, []) }

    refute ok
    assert_match(/interactive sudo/i, err)
    assert_match(/sudo yamine service install/, err)
  ensure
    ENV.delete("CI")
  end

  def test_interactive_install_sudos_once_for_a_human
    ENV.delete("CI")
    $stdin.stubs(:tty?).returns(true)
    Yamine::ProxyControl.stubs(:root?).returns(false)
    state = "/tmp/yamine-state"
    Yamine::Certs.stubs(:state_dir).returns(state)
    ruby = RbConfig.ruby
    bin = Yamine::ProxyControl.bin_path

    Yamine::Command.expects(:run)
      .with("sudo", "env", "YAMINE_STATE_DIR=#{state}", ruby, bin,
        "service", "install", "--internal")
      .returns(true)

    ok, out, = silently { Yamine::CLI::SystemCommand.service_install(@ctx, []) }

    assert ok
    assert_match(/Installing system service/, out)
  end

  def test_internal_without_root_is_rejected
    Yamine::ProxyControl.stubs(:root?).returns(false)

    assert_raises(Yamine::Error) do
      Yamine::CLI::SystemCommand.service_install(@ctx, ["--internal"])
    end
  end
end

# The root half of install: stage the payload, verify it fail-closed,
# and register a unit that references ONLY the staged path — migrating
# a legacy unit in place. Hermetic: root redirected to a tmpdir,
# launchd dir injected, launchctl stubbed on the Command seam.
class RootInstallTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @orig_root = ENV["YAMINE_PRIVILEGED_ROOT"]
    ENV["YAMINE_PRIVILEGED_ROOT"] = File.join(@dir, "yamine")
    @launchd_dir = File.join(@dir, "LaunchDaemons")
    FileUtils.mkdir_p(@launchd_dir)
    @ctx = Yamine::CLI::Context.new
    Yamine::PrivilegedPayload.stubs(:root_owned?).returns(true)
    Yamine::CLI::SystemCommand.stubs(:ensure_system_ca_trust)
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

  def test_install_registers_a_unit_with_only_root_owned_paths
    Yamine::Command.stubs(:run).returns(true)

    silently { Yamine::CLI::SystemCommand.install_launchd(@ctx, @launchd_dir) }

    plist = File.read(File.join(@launchd_dir, "dev.yamine.plist"))
    staged = Yamine::PrivilegedPayload.bin_path

    assert_includes plist, staged
    assert_includes plist, "--port</string><string>443"
    refute_includes plist, Yamine::ProxyControl.bin_path,
      "the unit must never reference the user-writable gem directory"
  end

  def test_install_migrates_a_legacy_unit_in_place
    legacy_bin = File.expand_path("~/.local/share/mise/installs/ruby/3.4.4/lib/ruby/gems/3.4.0/gems/yamine-0.19.0/bin/yamine")
    File.write(File.join(@launchd_dir, "dev.yamine.plist"),
      "<array><string>/usr/bin/ruby</string><string>#{legacy_bin}</string></array>")
    Yamine::Command.stubs(:run).returns(true)

    silently { Yamine::CLI::SystemCommand.install_launchd(@ctx, @launchd_dir) }

    plist = File.read(File.join(@launchd_dir, "dev.yamine.plist"))
    refute_includes plist, legacy_bin
    refute Yamine::PrivilegedPayload.legacy_ref?(
      Yamine::PrivilegedPayload.payload_ref_from_plist(plist)),
      "no user-writable root-executed path may survive the migration"
  end

  def test_install_clears_the_pre_rename_label
    legacy = File.join(@launchd_dir, "dev.ask.local.plist")
    File.write(legacy, "<plist/>")
    Yamine::Command.stubs(:run).returns(true)

    silently { Yamine::CLI::SystemCommand.install_launchd(@ctx, @launchd_dir) }

    refute File.exist?(legacy)
  end

  def test_failed_staging_registers_nothing
    Yamine::PrivilegedPayload.stubs(:stage!).raises(Yamine::Error.new("not root-owned"))
    Yamine::Command.expects(:run).never

    assert_raises(Yamine::Error) { Yamine::CLI::SystemCommand.install_service!(@ctx) }
    refute File.exist?(File.join(@launchd_dir, "dev.yamine.plist")),
      "fail closed: no unit may point at an unverified payload"
  end

  def test_systemd_unit_references_only_the_staged_path
    unit = Yamine::CLI::SystemCommand.systemd_unit

    assert_includes unit, Yamine::PrivilegedPayload.bin_path
    refute_includes unit, Yamine::ProxyControl.bin_path
  end

  def test_root_uninstall_removes_the_unit_and_the_staged_payload
    Yamine::ProxyControl.stubs(:root?).returns(true)
    Yamine::CLI::SystemCommand.stubs(:uninstall_launchd)
    Yamine::CLI::SystemCommand.stubs(:uninstall_systemd)
    Yamine::PrivilegedPayload.expects(:remove_payload!).returns(true)

    ok, = silently { Yamine::CLI::SystemCommand.service_uninstall(@ctx) }

    assert ok
  end

  def test_uninstall_launchd_removes_the_plist
    path = File.join(@launchd_dir, "dev.yamine.plist")
    File.write(path, "<plist/>")
    legacy = File.join(@launchd_dir, "dev.ask.local.plist")
    File.write(legacy, "<plist/>")
    Yamine::Command.stubs(:run).returns(true)

    silently { Yamine::CLI::SystemCommand.uninstall_launchd(@launchd_dir) }

    refute File.exist?(path)
    refute File.exist?(legacy)
  end
end

# hosts sync elevation runs the STAGED payload, never the gem — and
# says exactly what to do when nothing is staged yet.
class HostsElevationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @orig_root = ENV["YAMINE_PRIVILEGED_ROOT"]
    ENV["YAMINE_PRIVILEGED_ROOT"] = File.join(@dir, "yamine")
    @ctx = Yamine::CLI::Context.new
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
    ENV["YAMINE_PRIVILEGED_ROOT"] = @orig_root
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      Yamine::CLI.run(args)
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def write_route(hostname)
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, "routes.json"),
      JSON.generate([{ "hostname" => hostname, "kind" => "tcp", "target" => "127.0.0.1:3000", "pid" => 0 }]))
  end

  def test_elevation_re_executes_the_staged_payload
    ENV["CI"] = "1"
    write_route("myapp.localhost")
    File.write(File.join(@dir, "proxy.tlds"), "localhost\n")
    Yamine::ProxyControl.stubs(:root?).returns(false)
    Yamine::Hosts.stubs(:synced?).returns(false)
    Yamine::Hosts.stubs(:sync).with(["myapp.localhost"], Yamine::Hosts::PATH, tlds: anything).returns(false)
    Yamine::PrivilegedPayload.stubs(:staged?).returns(true)
    staged = Yamine::PrivilegedPayload.bin_path
    Yamine::Command.expects(:run)
      .with("sudo", "-n", "env", "YAMINE_STATE_DIR=#{@dir}", RbConfig.ruby, staged, "hosts", "sync")
      .returns(true)

    code, out, = run_cli("hosts", "sync")

    assert_equal 0, code
    assert_match(/elevated/i, out)
  ensure
    ENV.delete("CI")
  end

  def test_missing_staged_payload_points_at_the_human_install
    ENV["CI"] = "1"
    write_route("myapp.localhost")
    Yamine::ProxyControl.stubs(:root?).returns(false)
    Yamine::Hosts.stubs(:synced?).returns(false)
    Yamine::Hosts.stubs(:sync).returns(false)
    Yamine::PrivilegedPayload.stubs(:staged?).returns(false)
    Yamine::Command.expects(:run).never

    code, _out, err = run_cli("hosts", "sync")

    assert_equal 1, code
    assert_match(/sudo yamine service install/, err)
  ensure
    ENV.delete("CI")
  end

  def test_out_of_scope_hostnames_fail_with_the_policy
    write_route("github.com")
    Yamine::ProxyControl.stubs(:root?).returns(true)

    code, _out, err = run_cli("hosts", "sync")

    assert_equal 1, code
    assert_match(/refusing hosts sync/i, err)
  end
end
