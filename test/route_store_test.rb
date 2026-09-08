# frozen_string_literal: true

require_relative "test_helper"

class RouteStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_add_and_find
    @store.add_route("myapp.localhost", "/tmp/x.sock", Process.pid, kind: "socket")
    found = @store.find("myapp.localhost")
    assert_equal "/tmp/x.sock", found["target"]
    assert_equal "socket", found["kind"]
  end

  def test_stale_pids_pruned_on_read
    dead_pid = spawn_dead_pid
    @store.add_route("old.localhost", "127.0.0.1:4001", dead_pid, kind: "tcp")
    @store.add_route("live.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp")
    routes = @store.load_routes
    assert_equal ["live.localhost"], routes.map { |r| r["hostname"] }
  end

  def test_conflict_without_force
    other = spawn("sleep", "30", out: File::NULL, err: File::NULL)
    begin
      @store.add_route("clash.localhost", "127.0.0.1:4001", other, kind: "tcp")
      err = assert_raises(Yamine::RouteConflictError) do
        @store.add_route("clash.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp")
      end
      assert_equal "clash.localhost", err.hostname
      assert_equal other, err.existing_pid
    ensure
      Process.kill("KILL", other)
      Process.wait(other)
    end
  end

  def test_force_kills_previous_owner
    other = spawn("sleep", "30", out: File::NULL, err: File::NULL)
    begin
      @store.add_route("take.localhost", "127.0.0.1:4001", other, kind: "tcp")
      killed = @store.add_route("take.localhost", "127.0.0.1:4002", Process.pid,
        kind: "tcp", force: true)
      assert_equal other, killed
      assert_equal "127.0.0.1:4002", @store.find("take.localhost")["target"]
    ensure
      Process.kill("KILL", other)
      Process.wait(other)
    end
  end

  def test_remove_route_owner_guarded
    @store.add_route("gone.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    @store.remove_route("gone.localhost", owner_pid: Process.pid + 999_999)
    assert @store.find("gone.localhost"), "other owner's route must survive"
    @store.remove_route("gone.localhost", owner_pid: Process.pid)
    assert_nil @store.find("gone.localhost")
  end

  def test_corrupt_file_warns_and_returns_empty
    warnings = []
    store = Yamine::RouteStore.new(@dir, on_warning: ->(m) { warnings << m })
    File.write(File.join(@dir, "routes.json"), "{nope")
    assert_equal [], store.load_routes
    assert_match(/invalid JSON/, warnings.first)
  end

  def test_prune_stale_returns_removed
    dead_pid = spawn_dead_pid
    @store.add_route("dead.localhost", "127.0.0.1:4009", dead_pid, kind: "tcp")
    stale = @store.prune_stale
    assert_equal ["dead.localhost"], stale.map { |r| r["hostname"] }
    assert_equal [], @store.load_routes
  end

  private

  def spawn_dead_pid
    pid = spawn("true", out: File::NULL, err: File::NULL)
    Process.wait(pid)
    pid
  end
end
