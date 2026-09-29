# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"
require "tmpdir"

# A child that dies ends the boot, and how that ends is what an agent
# reads. `supervise_tree` used to `exit 0` on the way out — with the
# routes already removed and the rest of the tree being killed — so
# "yamine start exited 0" was a claim of health for an app that was not
# serving anything. These pin the non-zero exit, the three things the
# message has to name (which process, what status, which log), and the
# machine-readable form.
class StartExitCodeTest < Minitest::Test
  def setup
    @orig_dir = Dir.pwd
    @dir = Dir.mktmpdir
    @state = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @state
    Dir.chdir(@dir)
    FileUtils.mkdir_p(File.join(@dir, "log"))
    @pids = []
  end

  def teardown
    @pids.each { |pid| Yamine::ProcessTree.term(pid) }
    Dir.chdir(@orig_dir)
    ENV["YAMINE_STATE_DIR"] = @orig_state
    FileUtils.remove_entry(@dir) rescue nil
    FileUtils.remove_entry(@state) rescue nil
  end

  # A child that is already gone, spawned the way the boot spawns
  # (through ProcessTree.detach) so its exit status is one yamine can
  # still read: the reaper is the only thing allowed to wait for a
  # child, which is why Runner detaches instead of waiting.
  def dead_child(status)
    pid = Yamine::ProcessTree.detach(spawn(RbConfig.ruby, "-e", "exit #{status}"))
    @pids << pid
    wait_until_reaped(pid)
    pid
  end

  # Wait for the reaper to have collected the child. Peeking at the
  # table rather than calling `status`, which is the thing under test
  # and must stay free to answer for itself.
  def wait_until_reaped(pid)
    deadline = Time.now + 5
    until Yamine::ProcessTree::STATUSES.key?(pid) || Time.now > deadline
      sleep 0.05
    end
  end

  def supervise(named_pids, json: false)
    out, err = StringIO.new, StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      Yamine::CLI::BootCommand.supervise_tree(Yamine::CLI::Context.new, [], named_pids,
        json: json)
      0
    rescue SystemExit => e
      e.status
    end
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  def test_a_child_that_dies_ends_the_run_with_a_non_zero_status
    pid = dead_child(1)
    code, _out, err = supervise({ pid => "web" })

    refute_equal 0, code,
      "exit 0 here reads as 'the app came up' for an agent, and the app is not serving"
    assert_equal 1, code, "one meaning for 'the app is not up', shared with the --wait failure"
    assert_includes err, "[web]"
    assert_includes err, "pid #{pid}"
  end

  def test_the_message_names_the_status_and_the_log_tail
    File.write(File.join(@dir, "log", "development.log"), "boot line\nNameError: nope\n")
    pid = dead_child(3)
    _code, _out, err = supervise({ pid => "worker" })

    assert_includes err, "exit 3"
    assert_includes err, "log/development.log"
    assert_includes err, "NameError: nope",
      "the log tail is the answer to 'why did it die' and belongs in the message"
  end

  # A pid with no status to report (never ours, or not yet reaped) must
  # say so rather than print a code nobody observed.
  def test_a_status_we_never_saw_is_said_not_guessed
    pid = dead_child(1)
    Yamine::ProcessTree::STATUSES.delete(pid)
    _code, _out, err = supervise({ pid => "web" })

    assert_includes err, "status unknown"
  end

  def test_json_gets_a_machine_readable_failure
    dead_child(3)
    File.write(File.join(@dir, "log", "development.log"), "NameError: nope\n")
    pid = dead_child(1)
    code, out, = supervise({ pid => "web" }, json: true)

    assert_equal 1, code
    payload = JSON.parse(out)
    assert_equal false, payload["ok"]
    assert_equal "child-exited", payload["error"]
    assert_equal "web", payload["name"]
    assert_equal pid, payload["pid"]
    assert_equal 1, payload["status"]
    assert_includes payload["log_tail"], "NameError: nope"
    assert_includes payload["log_path"], "development.log"
  end

  # A killed child has no exit code, and pretending it exited 0 or 1
  # would be the same lie in a smaller font.
  def test_a_signalled_child_is_reported_as_a_signal
    pid = Yamine::ProcessTree.detach(spawn(RbConfig.ruby, "-e", "sleep 30"))
    @pids << pid
    Process.kill("KILL", pid)
    wait_until_reaped(pid)
    status = Yamine::ProcessTree.status(pid)
    assert status.signaled?, "precondition: the child died by signal"

    _code, _out, err = supervise({ pid => "web" })

    assert_includes err, "signal #{status.termsig}"
  end

  # supervise_tree is only reached with real children; a double that is
  # not a child of ours has no status, and asking the kernel must not
  # raise into the supervision loop.
  def test_status_of_a_pid_we_never_spawned_is_nil
    assert_nil Yamine::ProcessTree.status(Process.pid)
  end

  # A config whose only process is refused still "booted": collect_spawns
  # skips a compound cmd line with an error, the plan comes back empty,
  # and the run printed `ready: ` and then sat in supervise_tree for ever
  # with nothing to watch. It now ends where it actually is — which is
  # also what stops `--detach` from waiting out its whole timeout on a
  # tree that was never going to serve.
  def test_a_boot_that_started_nothing_exits_instead_of_supervising_nothing
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "local.yml"), <<~YAML)
      service: emptytree
      db: false
      processes:
        web:
          cmd: echo one && echo two
          proxy: true
    YAML
    resolved = Yamine::Resolver.resolve(@dir)

    code = nil
    _out, err = capture_io do
      code = exit_code_of { Yamine::CLI::BootCommand.boot_all(Yamine::CLI::Context.new, resolved, {}) }
    end

    assert_equal 1, code
    assert_includes err, "no process was started"
    assert_includes err, "compound line", "and it still names the process it refused"
  end

  def exit_code_of
    yield
    0
  rescue SystemExit => e
    e.status
  end
end
