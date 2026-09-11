# frozen_string_literal: true

require_relative "test_helper"

# Port-443 provisioning: the `sudoers` command prints the scoped NOPASSWD
# rules that let agents and repeat machines run `service install` without a
# TTY, and the non-interactive boot path points at them instead of hanging.
class SudoersTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    Yamine::Hosts.stubs(:resolution).returns(ok: [], warn: [], fail: [])
  end

  def teardown
    FileUtils.remove_entry(@dir)
    ENV["YAMINE_STATE_DIR"] = @orig_state
  end

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = begin
      Yamine::CLI.run(args)
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout = orig_out
    $stderr = orig_err
  end

  def write_local_yml(dir)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "local.yml"),
      "service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true\n")
  end

  def test_sudoers_prints_scoped_nopasswd_rules_for_service_install
    user = ENV.fetch("USER", Etc.getlogin)
    code, out, = run_cli("sudoers")

    assert_equal 0, code
    assert_includes out, "#{user} ALL=(root) NOPASSWD:"
    assert_includes out, "service install --internal"
    assert_includes out, "service uninstall --internal"
    assert_includes out, RbConfig.ruby
    assert_includes out, Yamine::ProxyControl.bin_path
    # The whole point: the grant is the gem's own re-exec, not a bare
    # interpreter an attacker could point anywhere.
    assert_includes out, "not a bare interpreter"
  end

  def test_non_interactive_privileged_boot_points_at_sudoers
    write_local_yml(@dir)
    # Deterministic regardless of the real machine: a dev box may already
    # run our own proxy on 443 (installed via setup), which would make
    # ensure_proxy! short-circuit instead of hitting the hard error.
    Yamine::ProxyControl.stubs(:listening?).returns(false)

    code, _out, err = nil
    Dir.chdir(@dir) do
      # No proxy state file -> ctx.proxy_port defaults to 443; $stdin is not
      # a TTY under the test runner -> the non-interactive privileged path.
      code, _out, err = run_cli
    end

    assert_equal 1, code
    assert_includes err, "port 443 needs root"
    assert_includes err, "yamine setup"
    assert_includes err, "yamine sudoers"
    assert_includes err, "/etc/sudoers.d/yamine"
  end

  def test_non_interactive_setup_path_points_at_sudoers
    write_local_yml(@dir)
    # Stub the trust step so no real `security` command (and no keychain
    # popup) runs; --no-service uses the sudo daemon path, and with no TTY
    # it must point at the sudoers fix instead of hanging.
    Yamine::Trust.stubs(:trust).returns({ trusted: true })

    code, _out, err = nil
    Dir.chdir(@dir) do
      code, _out, err = run_cli("setup", "--no-service")
    end

    assert_equal 1, code
    assert_includes err, "no TTY available for the sudo prompt"
    assert_includes err, "yamine sudoers"
    assert_includes err, "/etc/sudoers.d/yamine"
  end
end


class LaunchctlVerbsTest < Minitest::Test
  # Regression: the root service install used the legacy `launchctl load`/
  # `unload` verbs, which current macOS rejects with error 5 — and can exit
  # 0 while failing, so the old code reported success with no service
  # running. The verbs must be the modern system-domain bootstrap/bootout.
  # The real launchctl sequence needs root, so this pins the source of the
  # extracted helpers (the behavior seam the privileged commands live in).
  def test_install_uses_modern_bootstrap_verbs
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "cli", "system.rb"))
    bootstrap = source[/def launchctl_bootstrap(.*?)^      end/m, 1]
    install = source[/def install_launchd(.*?)^      end/m, 1]

    assert bootstrap, "launchctl_bootstrap helper must exist"
    assert_includes bootstrap, '"launchctl", "bootout", "system"'
    assert_includes bootstrap, '"launchctl", "bootstrap", "system"'
    assert_includes bootstrap, '"launchctl", "enable"'
    assert_includes bootstrap, '"launchctl", "kickstart"'
    assert_includes bootstrap, "launchctl bootstrap failed"
    assert_includes bootstrap, "err: File::NULL",
      "the best-effort pre-bootout must not print error-5 noise on a first install"
    refute_includes bootstrap, '"launchctl", "load"'
    refute_includes install, '"launchctl", "load"'
    refute_includes install, '"launchctl", "unload"'
  end

  def test_uninstall_uses_bootout
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "cli", "system.rb"))
    bootout = source[/def launchctl_bootout(.*?)^      end/m, 1]

    assert bootout, "launchctl_bootout helper must exist"
    assert_includes bootout, '"launchctl", "bootout", "system"'
    refute_includes bootout, '"launchctl", "unload"'
  end
end

class ServiceInstallFixesTest < Minitest::Test
  # Regression set from live `yamine setup` failures:
  #  1. launchd rejected the plist with error 5 because install chowned it
  #     to the invoking user — system-domain plists must stay root-owned.
  #  2. CA trust should happen under elevation (System keychain, silent),
  #     not as a separate user-level GUI popup.
  #  3. Linux should actually install a systemd unit, not just print one.
  def source
    @source ||= File.read(File.join(__dir__, "..", "lib", "yamine", "cli", "system.rb"))
  end

  def test_install_launchd_keeps_plist_root_owned
    install = source[/def install_launchd(.*?)^      end/m, 1]

    assert_includes install, "launchctl_bootstrap(path)"
    assert_includes install, "File.chown(0, 0, path) if Process.uid.zero?",
      "a stale user-owned plist must be healed to root ownership — File.write keeps an existing file's owner"
    refute_includes install, "chown_service_files",
      "chowning the plist to the invoking user makes launchd bootstrap fail with error 5"
    refute_includes install, "Ownership.",
      "install must not hand the /Library/LaunchDaemons plist to the invoking user"
  end

def test_setup_default_path_has_no_user_level_ca_popup
  setup = source[/def setup\(ctx, args\)(.*?)^      end/m, 1]
  # The default branch (else of --no-service) installs the root service,
  # which trusts the CA under elevation — no separate user-level popup.
  default_branch = setup[/^        else\n(.*?)^        end\n/m, 1]

  assert default_branch, "default setup branch must exist"
  assert_includes default_branch, "ensure_root_service",
    "default setup must install the root service (which trusts CA under elevation)"
  refute_includes default_branch, "Trust.trust",
    "default setup must not trust the CA at user level (that is the GUI popup)"
end

  def test_setup_no_service_still_trusts_ca
    setup = source[/def setup\(ctx, args\)(.*?)^      end/m, 1]
    refute_nil setup[/no-service/]
  end

  def test_install_launchd_trusts_ca_while_elevated
    install = source[/def install_launchd(.*?)^      end/m, 1]

    assert_includes install, "ensure_system_ca_trust",
      "the elevated install must trust the CA system-wide before bootstrap"
  end

  def test_install_reports_stage_progress
    install = source[/def install_launchd(.*?)^      end/m, 1]
    trust = source[/def ensure_system_ca_trust(.*?)^      end/m, 1]

    assert_includes install, "Registering the launchd service on port 443",
      "the root half must print stage lines so the terminal is never silent after the password"
    assert_includes trust, "Trusting the CA into the System keychain...",
      "the slow keychain step must announce itself before running"
  end

  def test_system_ca_trust_uses_system_keychain
    trust_source = File.read(File.join(__dir__, "..", "lib", "yamine", "trust.rb"))
    macos = trust_source[/def trust_macos(.*?)^      end/m, 1]

    assert_includes macos, "Process.uid.zero?"
    assert_includes macos, "/Library/Keychains/System.keychain"
    assert_includes macos, '"-d"'
  end

  def test_linux_installs_systemd_unit
    assert_includes source, "def systemd_unit"
    install = source[/def install_systemd(.*?)^      end/m, 1]

    assert_includes install, "/etc/systemd/system/yamine.service"
    assert_includes install, '"systemctl", "enable", "--now", "yamine"'
    assert_includes install, "File.chown(0, 0, unit_path) if Process.uid.zero?",
      "a stale user-owned unit must be healed to root ownership"
  end

  def test_linux_uninstall_disables_and_removes_unit
    uninstall = source[/def service_uninstall(.*?)^      end/m, 1]
    linux = uninstall[/when \/linux\/(.*?)^        else/m, 1]

    assert_includes linux, '"systemctl", "disable", "--now", "yamine"'
    assert_includes linux, 'rm_f("/etc/systemd/system/yamine.service")'
  end
end


class ElevatePromptSafetyTest < Minitest::Test
  # The elevation re-exec must never prompt for a password in tests or CI.
  # Non-interactive runs use `sudo -n` (fails fast without the NOPASSWD
  # grant), and all privileged execution goes through Command.run so tests
  # stub it instead of shelling out to a real sudo/security/launchctl.
  def setup
    ENV["CI"] = "1"
  end

  def teardown
    ENV.delete("CI")
  end

  def silently
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = StringIO.new, StringIO.new
    code = begin
      yield
      0
    rescue SystemExit => e
      e.status
    end
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def test_non_interactive_elevate_uses_sudo_n
    Yamine::Command.expects(:run)
      .with("sudo", "-n", "env", "X=1", "cmd", "--internal")
      .returns(false)

    ok = nil
    code, _out, err = silently { ok = Yamine::CLI::SystemCommand.elevate(["env", "X=1", "cmd", "--internal"]) }

    assert_equal 0, code
    refute ok, "non-interactive elevation without a grant must fail"
    assert_includes err, "yamine sudoers",
      "the failure hint must name the NOPASSWD grant, not ask for a password"
  end

  def test_interactive_elevate_uses_plain_sudo
    ENV.delete("CI")
    $stdin.stubs(:tty?).returns(true)

    Yamine::Command.expects(:run)
      .with("sudo", "env", "X=1", "cmd", "--internal")
      .returns(true)

    ok = Yamine::CLI::SystemCommand.elevate(["env", "X=1", "cmd", "--internal"])
    assert ok, "interactive elevation with a password available must succeed"
  end

  def test_interactive_elevate_failure_says_rerun_not_sudoers
    ENV.delete("CI")
    $stdin.stubs(:tty?).returns(true)

    Yamine::Command.expects(:run)
      .with("sudo", "env", "X=1", "cmd", "--internal")
      .returns(false)

    ok = nil
    code, _out, err = silently { ok = Yamine::CLI::SystemCommand.elevate(["env", "X=1", "cmd", "--internal"]) }

    assert_equal 0, code
    refute ok
    assert_includes err, "re-run `yamine setup`"
    refute_includes err, "yamine sudoers",
      "the scoped-grant hint is for passwordless runs; an interactive failure is auth or the command's own error"
  end

  def test_service_install_elevates_through_command_not_bare_sudo
    Yamine::ProxyControl.stubs(:root?).returns(false)
    state = "/tmp/yamine-state"
    Yamine::Certs.stubs(:state_dir).returns(state)
    ruby = RbConfig.ruby
    bin = Yamine::ProxyControl.bin_path

    Yamine::Command.expects(:run)
      .with("sudo", "-n", "env", "YAMINE_STATE_DIR=#{state}", ruby, bin,
        "service", "install", "--internal")
      .returns(true)

    code, out, = silently { Yamine::CLI.run(["service", "install"]) }

    assert_equal 0, code, "service install must exit 0 when the elevation succeeds"
    assert_includes out, "Installing system service"
  end
end
