# frozen_string_literal: true

require_relative "test_helper"
require "json"

# `yamine list` / `yamine get --all` have to answer one question: is the
# APP serving. The pid in a route entry is not that — it is the yamine
# process that registered the route, it outlives the app, and asking it
# reported "running" for every backend that had already crashed. The
# app's pid is in the sidecar, and this pins the whole vocabulary that
# reads from it, including the states that must stay honest about not
# knowing.
class RoutesLivenessTest < Minitest::Test
  def setup
    @state = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @state
    @ctx = Yamine::CLI::Context.new
    @store = @ctx.store
    @servers = []
    @pids = []
  end

  def teardown
    @servers.each { |s| s.close rescue nil }
    @pids.each { |p| Process.kill("KILL", p) rescue nil }
    ENV["YAMINE_STATE_DIR"] = @orig
    FileUtils.remove_entry(@state)
  end

  def route(hostname, target, pid: Process.pid, kind: "tcp")
    @store.add_route(hostname, target, pid, kind: kind,
      spec: { "dir" => Dir.pwd, "proc" => "web" })
    @store.load_routes_raw.find { |r| r["hostname"] == hostname }
  end

  # The sidecar is what Runner#write_backend_pid wrote: the app's pid,
  # not the route's.
  def backend_pid!(hostname, pid)
    File.write(File.join(@state, "backend-#{hostname}.pid"), "#{pid}\n")
  end

  def live_pid
    pid = spawn("sleep", "30", out: File::NULL, err: File::NULL)
    Process.detach(pid)
    @pids << pid
    pid
  end

  def dead_pid
    pid = spawn("true")
    Process.wait(pid)
    pid
  end

  def state_for(entry)
    Yamine::CLI::RoutesCommand.alive_state(@ctx, entry)
  end

  def test_live_backend_reads_running
    pid = live_pid
    entry = route("up.localhost", "127.0.0.1:4001")
    backend_pid!("up.localhost", pid)

    assert_equal "running", state_for(entry)
  end

  # The bug: a dead app under a live owner used to read "running",
  # because "running" was a question about the owner.
  def test_dead_backend_reads_backend_gone_while_the_owner_lives
    entry = route("crashed.localhost", "127.0.0.1:4002")
    backend_pid!("crashed.localhost", dead_pid)

    assert_equal "backend-gone", state_for(entry)
  end

  # A route written before sidecars existed, or by a boot that died
  # between add_route and write_backend_pid, has no evidence of a dead
  # app. Reporting it as down would have every pre-existing route on the
  # machine read as broken after an upgrade — so it is "unknown", and
  # only "unknown".
  def test_route_without_a_backend_pid_is_unknown_not_down
    entry = route("legacy.localhost", "127.0.0.1:4003")

    assert_equal "unknown", state_for(entry)
  end

  def test_unrecorded_backend_under_a_dead_owner_is_owner_gone
    entry = route("orphan.localhost", "127.0.0.1:4004", pid: dead_pid)

    assert_equal "owner-gone", state_for(entry)
  end

  # A static alias names no process at all, so it keeps reporting the
  # probe of its target — that is the only evidence there is.
  def test_alias_reports_the_probe_not_a_process
    server = TCPServer.new("127.0.0.1", 0)
    @servers << server
    entry = route("docker.localhost", "127.0.0.1:#{server.addr[1]}", pid: 0)
    assert_equal "reachable", state_for(entry)

    dead = route("gone.localhost", "127.0.0.1:#{server.addr[1]}", pid: 0)
    server.close
    assert_equal "unreachable", state_for(dead)
  end

  # A probe that raises is not a verdict: `list` must not die on one
  # unreadable entry, and must not invent one either.
  def test_unreadable_sidecar_degrades_to_unknown
    entry = route("weird.localhost", "127.0.0.1:4005")
    File.write(File.join(@state, "backend-weird.localhost.pid"), "not-a-pid\n")
    assert_equal "unknown", state_for(entry)

    @ctx.stubs(:backend_pid_for).raises(Errno::EACCES)
    assert_equal "unknown", state_for(entry)
  end

  # The JSON is the agent contract, so the pid the verdict is about
  # travels with it: `pid` is still the route's owner (routes.json, and
  # what `yamine stop` compares), `backend_pid` is the app.
  def test_list_json_carries_the_backend_pid_and_the_apps_state
    pid = live_pid
    route("up.localhost", "127.0.0.1:4006")
    backend_pid!("up.localhost", pid)
    route("crashed.localhost", "127.0.0.1:4007")
    backend_pid!("crashed.localhost", dead_pid)

    out, = capture_stdout { Yamine::CLI::RoutesCommand.list(@ctx, ["--json"]) }
    entries = JSON.parse(out)["routes"].to_h { |e| [e["hostname"], e] }

    assert_equal pid, entries["up.localhost"]["backend_pid"]
    assert_equal "running", entries["up.localhost"]["alive"]
    assert_equal Process.pid, entries["up.localhost"]["pid"]
    assert_equal "backend-gone", entries["crashed.localhost"]["alive"]
  end

  def test_registry_reports_the_apps_state_too
    route("crashed.localhost", "127.0.0.1:4008")
    backend_pid!("crashed.localhost", dead_pid)

    out, = capture_stdout { Yamine::CLI::RoutesCommand.get(@ctx, ["--all", "--json"]) }

    assert_equal "backend-gone", JSON.parse(out)["routes"].first["alive"]
  end

  def capture_stdout
    io = StringIO.new
    orig = $stdout
    $stdout = io
    yield
    [io.string, nil]
  ensure
    $stdout = orig
  end
end
