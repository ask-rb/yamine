# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"
require "tmpdir"

# `yamine start --detach` exists so an agent can start an app and get its
# prompt (and its exit code) back. The part that is easy to get wrong,
# and the part these tests are mostly about, is the route owner pid: the
# boot happens in the child so that `Process.pid` — the value
# `add_route` records — is a process that stays alive. A parent that
# registered the routes and exited would have its own route pruned by
# RouteStore#load_routes on the very next read, and the proxy would 503
# an app that is running perfectly well.
class StartDetachTest < Minitest::Test
  def setup
    @orig_dir = Dir.pwd
    @dir = Dir.mktmpdir
    @state = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @state
    Dir.chdir(@dir)
    FileUtils.mkdir_p(File.join(@dir, "config"))
    @backend = File.join(@dir, "backend.rb")
    # A real TCP backend, so `--wait`'s readiness poll has something to
    # find and the route that eventually appears points at a live port.
    File.write(@backend, <<~RUBY)
      require "socket"
      s = TCPServer.new("127.0.0.1", ENV["PORT"].to_i)
      loop { c = s.accept; c.write("ok") rescue nil; c.close rescue nil }
    RUBY
    @trees = []
  end

  def teardown
    @trees.each { |pid| Yamine::ProcessTree.term(pid) }
    Dir.chdir(@orig_dir)
    ENV["YAMINE_STATE_DIR"] = @orig_state
    FileUtils.remove_entry(@dir) rescue nil
    FileUtils.remove_entry(@state) rescue nil
  end

  def write_config(cmd: "ruby #{@backend}")
    File.write(File.join(@dir, "config", "local.yml"), <<~YAML)
      service: detachable
      db: false
      processes:
        web:
          cmd: #{cmd}
          proxy: true
    YAML
  end

  # The proxy is not what is under test, and a real one would want port
  # 443. Everything else in the boot runs for real.
  def without_proxy
    Yamine::CLI::BootCommand.stubs(:ensure_proxy!)
    yield
  end

  # The streams are swapped for real files, not StringIO, because the
  # detached child reopens them onto its log: a StringIO cannot be
  # reopened onto a File, and pretending otherwise would mean the test
  # never exercises the redirect that makes a detached tree's output
  # findable after the parent is gone.
  def run_detach(*args)
    out, err = Tempfile.new("yamine-detach-out"), Tempfile.new("yamine-detach-err")
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = begin
      Yamine::CLI::BootCommand.run_inferred(Yamine::CLI::Context.new, ["--detach", *args])
      0
    rescue SystemExit => e
      e.status
    end
    out.flush
    err.flush
    [code, File.read(out.path), File.read(err.path)]
  ensure
    $stdout, $stderr = orig_out, orig_err
    out.close!
    err.close!
  end

  def store
    Yamine::RouteStore.new(@state)
  end

  def entry
    store.load_routes.find { |r| r["hostname"] == "detachable.localhost" }
  end

  def pidfile
    File.join(@state, "start-detachable.localhost.pid")
  end

  def logfile
    File.join(@state, "start-detachable.localhost.log")
  end

  # The whole point: the command returns 0 with the URL, the pid that
  # owns the tree and the log — and the route is registered to THAT pid,
  # which is the one thing that must not be the process that exited.
  def test_detached_start_returns_a_live_tree_with_its_own_pid
    write_config
    code, out, = without_proxy { run_detach }
    assert_equal 0, code, "a healthy detached boot must exit 0"
    assert_includes out, "https://detachable.localhost"
    assert_includes out, "log  #{logfile}"

    tree = File.read(pidfile).strip.to_i
    @trees << tree
    assert_includes out, "pid  #{tree}"
    assert alive?(tree), "the pid handed back must be a running process"

    route = entry
    refute_nil route, "the detached child must have registered the route"
    assert_equal tree, route["pid"],
      "the route's owner pid must be the detached child: a parent's would prune itself on the next read"
    assert Yamine::ProxyControl.pid_alive?(route["pid"])

    backend = File.read(File.join(@state, "backend-detachable.localhost.pid")).to_i
    refute_equal tree, backend, "the sidecar names the app, not the tree that supervises it"
    assert alive?(backend)
  end

  # Pruning is what a parent's pid would have triggered, so assert the
  # consequence rather than the mechanism: with the tree running, a plain
  # read of routes.json (no pruning requested) still returns the route,
  # and a pruned read keeps it too.
  def test_detached_route_survives_a_pruning_read
    write_config
    _code, = without_proxy { run_detach }
    @trees << File.read(pidfile).strip.to_i

    assert_equal 1, store.load_routes(prune: true).length,
      "a live detached tree must not have its own route pruned"
  end

  # Idempotent: asking again says what is already there and starts
  # nothing. Starting a second tree would fight the first one for the
  # hostname and leave the loser to be reported as a boot failure.
  def test_second_detach_reports_the_running_tree_and_starts_nothing
    write_config
    _code, = without_proxy { run_detach }
    @trees << File.read(pidfile).strip.to_i
    existing = File.read(pidfile)

    Yamine::CLI::BootCommand.expects(:boot_all).never
    code, out, = without_proxy { run_detach }

    assert_equal 0, code, "an app that is already up is not a failure"
    assert_includes out, "Already running"
    assert_includes out, "https://detachable.localhost"
    assert_equal existing, File.read(pidfile), "the running tree's pidfile must be left alone"
  end

  # A foreground `yamine start` has no pidfile, so the route is the only
  # record of it. Detaching beside it must report, not race.
  def test_detach_beside_a_live_foreground_boot_reports_it
    write_config
    # spec.dir as a real boot writes it: Dir.pwd, already resolved (a
    # mktmpdir path reaches Ruby through a symlink on macOS, and the
    # ownership gate compares these two strings).
    store.add_route("detachable.localhost", "127.0.0.1:#{Yamine::Ports.find_free}",
      Process.pid, kind: "tcp", spec: { "dir" => File.expand_path(Dir.pwd) })
    Yamine::CLI::BootCommand.expects(:boot_all).never

    code, out, = without_proxy { run_detach }

    assert_equal 0, code
    assert_includes out, "Already running"
    refute File.file?(pidfile), "no tree was started, so no pidfile may be written"
  end

  # --json gets the same three facts, machine-readable: an agent's next
  # move is `yamine list` and `yamine stop`, both of which need a pid.
  def test_detached_json_payload
    write_config
    code, out, = without_proxy { run_detach("--json") }
    assert_equal 0, code

    payload = JSON.parse(out)
    assert payload["ok"]
    assert payload["started"]
    assert_equal "https://detachable.localhost", payload["url"]
    assert_equal logfile, payload["log_path"]
    tree = payload["pid"]
    @trees << tree
    assert alive?(tree)
    assert_equal tree, entry["pid"]
  end

  # The tree supervises itself after the parent is gone, which is what
  # makes `--detach` a background service rather than a fire-and-forget
  # that dies with the shell. The output that proves it is in the log
  # file, under the state dir, and not on a terminal nobody is holding.
  def test_detached_output_goes_to_the_log_under_the_state_dir
    write_config
    _code, out, = without_proxy { run_detach }
    @trees << File.read(pidfile).strip.to_i

    assert File.file?(logfile), "the boot's own output has to land somewhere"
    assert_empty out.lines.grep(/\[deps\]/), "phase narration belongs to the log, not the caller's stdout"
    assert_includes File.read(logfile), "dependencies satisfied"
  end

  # A boot that never becomes healthy must not be reported as a started
  # app: the caller gets a non-zero and the log, which is where the
  # reason is.
  def test_detached_boot_that_dies_reports_failure_not_success
    write_config(cmd: "exit 3")
    code, out, err = without_proxy { run_detach }

    assert_equal 1, code, "a tree that never served must not exit 0"
    refute_includes out, "Detached"
    assert_includes err, "detachable.localhost"
    assert_includes err, logfile
    refute File.file?(pidfile), "a dead tree must not leave a pidfile claiming one is running"
    assert_empty store.load_routes
  end

  def test_detached_boot_that_dies_reports_a_json_failure
    write_config(cmd: "exit 3")
    code, out, = without_proxy { run_detach("--json") }

    assert_equal 1, code
    payload = JSON.parse(out)
    refute payload["ok"]
    assert_equal logfile, payload["log_path"]
    assert_includes payload["reason"], "exited"
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue SystemCallError
    false
  end
end
