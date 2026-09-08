# frozen_string_literal: true

require_relative "test_helper"

# Port-443 provisioning: the `sudoers` command prints the scoped NOPASSWD
# rules that let agents and repeat machines run `service install` without a
# TTY, and the non-interactive boot path points at them instead of hanging.
class SudoersTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["ASK_LOCAL_STATE_DIR"]
    ENV["ASK_LOCAL_STATE_DIR"] = @dir
    Ask::Local::Hosts.stubs(:unresolved).returns([])
  end

  def teardown
    FileUtils.remove_entry(@dir)
    ENV["ASK_LOCAL_STATE_DIR"] = @orig_state
  end

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = begin
      Ask::Local::CLI.run(args)
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
    assert_includes out, Ask::Local::ProxyControl.bin_path
    # The whole point: the grant is the gem's own re-exec, not a bare
    # interpreter an attacker could point anywhere.
    assert_includes out, "not a bare interpreter"
  end

  def test_non_interactive_privileged_boot_points_at_sudoers
    write_local_yml(@dir)

    code, _out, err = nil
    Dir.chdir(@dir) do
      # No proxy state file -> ctx.proxy_port defaults to 443; $stdin is not
      # a TTY under the test runner -> the non-interactive privileged path.
      code, _out, err = run_cli
    end

    assert_equal 1, code
    assert_includes err, "port 443 needs root"
    assert_includes err, "ask-local setup"
    assert_includes err, "ask-local sudoers"
    assert_includes err, "/etc/sudoers.d/ask-local"
  end

  def test_non_interactive_setup_path_points_at_sudoers
    write_local_yml(@dir)
    # A trusted CA is required to reach the proxy step of `setup`; mark it
    # so step 1 is skipped and step 2 runs. --no-service uses the sudo
    # daemon path (the root-service path re-execs sudo via system(), which
    # is not capturable here); with no TTY it must point at the sudoers
    # fix instead of hanging.
    Ask::Local::Certs.stubs(:trusted?).returns(true)

    code, _out, err = nil
    Dir.chdir(@dir) do
      code, _out, err = run_cli("setup", "--no-service")
    end

    assert_equal 1, code
    assert_includes err, "no TTY available for the sudo prompt"
    assert_includes err, "ask-local sudoers"
    assert_includes err, "/etc/sudoers.d/ask-local"
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
    source = File.read(File.join(__dir__, "..", "lib", "ask", "local", "cli", "system.rb"))
    bootstrap = source[/def launchctl_bootstrap(.*?)^        end/m, 1]
    install = source[/def install_launchd(.*?)^        end/m, 1]

    assert bootstrap, "launchctl_bootstrap helper must exist"
    assert_includes bootstrap, '"launchctl", "bootout", "system"'
    assert_includes bootstrap, '"launchctl", "bootstrap", "system"'
    assert_includes bootstrap, '"launchctl", "enable"'
    assert_includes bootstrap, '"launchctl", "kickstart"'
    assert_includes bootstrap, "launchctl bootstrap failed"
    refute_includes bootstrap, '"launchctl", "load"'
    refute_includes install, '"launchctl", "load"'
    refute_includes install, '"launchctl", "unload"'
  end

  def test_uninstall_uses_bootout
    source = File.read(File.join(__dir__, "..", "lib", "ask", "local", "cli", "system.rb"))
    bootout = source[/def launchctl_bootout(.*?)^        end/m, 1]

    assert bootout, "launchctl_bootout helper must exist"
    assert_includes bootout, '"launchctl", "bootout", "system"'
    refute_includes bootout, '"launchctl", "unload"'
  end
end
