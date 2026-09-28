# frozen_string_literal: true

require_relative "test_helper"

# The grant must match what the CLI actually invokes. sudo matches the
# command path plus every concatenated argument and strips no `env`
# prefix, so a rule that differs by even one word is decorative: an
# agent's passwordless `hosts sync` ends in "sudo: a password is
# required". This pins both sides to one shared source of truth by
# construction: it parses the command specs out of `yamine sudoers`
# output, captures the real argv handed to sudo on each elevated path,
# and asserts equality. Hermetic: sudo itself is stubbed on the
# Command seam — but the argv equality is asserted on captured values,
# never assumed from the stub.
class GrantArgvParityTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
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

  # Command specs parsed out of `yamine sudoers` output, honoring the
  # backslash-escaped spaces sudoers(5) requires in paths.
  def sudoers_specs
    _code, out, = run_cli("sudoers")
    out.each_line.filter_map do |line|
      next unless line.include?("NOPASSWD:")

      split_sudoers_words(line.split("NOPASSWD:", 2).last.strip)
    end
  end

  def split_sudoers_words(spec)
    words = []
    current = +""
    escaped = false
    spec.each_char do |ch|
      if escaped
        current << ch
        escaped = false
      elsif ch == "\\"
        escaped = true
      elsif ch == " "
        words << current
        current = +""
      else
        current << ch
      end
    end
    words << current
    words
  end

  # The exact argv elevate hands to sudo on a CLI path, captured off
  # the Command seam under non-interactive conditions (sudo -n).
  def elevated_argv_for(*cli_args)
    captured = nil
    Yamine::Command.stubs(:run).with { |*args| captured = args; true }.returns(true)
    ENV["CI"] = "1"
    run_cli(*cli_args)
    captured
  ensure
    ENV.delete("CI")
  end

  def write_route(hostname)
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, "routes.json"),
      JSON.generate([{ "hostname" => hostname, "kind" => "tcp", "target" => "127.0.0.1:3000", "pid" => 0 }]))
  end

  def test_printed_specs_equal_the_shared_argv_truth
    specs = sudoers_specs

    assert_equal 2, specs.length, "the grant is exactly two rules"
    assert_equal Yamine::CLI::SystemCommand.granted_hosts_sync_argv, specs[0]
    assert_equal Yamine::CLI::SystemCommand.granted_uninstall_argv, specs[1]
  end

  def test_shared_truth_is_the_expected_commands
    assert_equal [RbConfig.ruby, Yamine::PrivilegedPayload.bin_path, "hosts", "sync"],
      Yamine::CLI::SystemCommand.granted_hosts_sync_argv
    assert_equal [RbConfig.ruby, Yamine::PrivilegedPayload.bin_path, "service", "uninstall", "--internal"],
      Yamine::CLI::SystemCommand.granted_uninstall_argv
  end

  def test_no_rule_passes_environment_across_sudo
    sudoers_specs.each do |spec|
      refute_includes spec, "env",
        "an `env` prefix makes the command /usr/bin/env, which no rule names"
      refute spec.any? { |w| w.include?("=") },
        "no VAR=value may cross the sudo boundary (SETENV would let RUBYOPT/RUBYLIB smuggle code into root)"
    end
  end

  def test_hosts_sync_invocation_matches_its_rule
    write_route("myapp.localhost")
    Yamine::ProxyControl.stubs(:root?).returns(false)
    Yamine::Hosts.stubs(:synced?).returns(false)
    Yamine::Hosts.stubs(:sync).returns(false)
    Yamine::PrivilegedPayload.stubs(:staged?).returns(true)

    captured = elevated_argv_for("hosts", "sync")

    assert_equal ["sudo", "-n", *sudoers_specs[0]], captured
  end

  def test_uninstall_invocation_matches_its_rule
    Yamine::ProxyControl.stubs(:root?).returns(false)
    Yamine::PrivilegedPayload.stubs(:staged?).returns(true)

    captured = elevated_argv_for("service", "uninstall")

    assert_equal ["sudo", "-n", *sudoers_specs[1]], captured
  end

  def test_spaced_paths_survive_the_sudoers_round_trip
    spaced = "/Library/Application Support/yamine/current/bin/yamine"
    argv = [RbConfig.ruby, spaced, "hosts", "sync"]
    rendered = argv.map { |w| Yamine::CLI::SystemCommand.sudoers_escape(w) }.join(" ")

    assert_includes rendered, "Application\\ Support",
      "sudoers splits specs on unescaped spaces — the staged macOS path must be escaped"
    assert_equal argv, split_sudoers_words(rendered)
  end
end

# The root half derives the invoking user's state dir from SUDO_USER
# (sudo sets it; env_reset makes HOME root's). Nothing crosses the
# sudo boundary, and unprivileged resolution is untouched.
class InvokingStateDirTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @orig_sudo_user = ENV["SUDO_USER"]
    @ctx = Yamine::CLI::Context.new
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
    ENV["SUDO_USER"] = @orig_sudo_user
    FileUtils.remove_entry(@dir)
  end

  def test_root_half_derives_the_invoking_users_state_dir
    me = ENV.fetch("USER", Etc.getlogin)
    ENV["SUDO_USER"] = me
    Yamine::ProxyControl.stubs(:root?).returns(true)

    store = Yamine::CLI::SystemCommand.privileged_store(@ctx)

    assert_equal File.join(Etc.getpwnam(me).dir, ".yamine"), store.dir
    refute_equal @ctx.store.dir, store.dir,
      "the root half must not resolve through root's HOME"
  end

  def test_unprivileged_store_is_untouched
    ENV.delete("SUDO_USER")
    Yamine::ProxyControl.stubs(:root?).returns(false)

    assert_same @ctx.store, Yamine::CLI::SystemCommand.privileged_store(@ctx)
  end

  def test_root_without_sudo_user_falls_back_like_before
    ENV.delete("SUDO_USER")
    Yamine::ProxyControl.stubs(:root?).returns(true)

    store = Yamine::CLI::SystemCommand.privileged_store(@ctx)

    assert_equal File.join(Yamine::Certs.home, ".yamine"), store.dir
  end
end
