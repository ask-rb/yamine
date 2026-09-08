# frozen_string_literal: true

require_relative "test_helper"

class AgentIdentityTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_agent = ENV["YAMINE_AGENT"]
    @orig_max = ENV["YAMINE_MAX_ROUTES"]
    ENV.delete("YAMINE_MAX_ROUTES")
  end

  def teardown
    ENV["YAMINE_AGENT"] = @orig_agent if @orig_agent
    ENV.delete("YAMINE_AGENT") unless @orig_agent
    ENV["YAMINE_MAX_ROUTES"] = @orig_max if @orig_max
    FileUtils.remove_entry(@dir)
  end

  def test_agent_name_from_env
    ENV["YAMINE_AGENT"] = "agent-1"
    assert_equal "agent-1", Yamine::Agent.name
  end

  def test_agent_name_strips_whitespace
    ENV["YAMINE_AGENT"] = "  agent-2  "
    assert_equal "agent-2", Yamine::Agent.name
  end

  def test_agent_name_falls_back_to_user_at_host
    ENV.delete("YAMINE_AGENT")
    name = Yamine::Agent.name
    assert_match(/@/, name)
    refute_empty name.split("@").first
  end

  def test_max_routes_default
    ENV.delete("YAMINE_MAX_ROUTES")
    assert_equal 32, Yamine::Agent.max_routes
  end

  def test_max_routes_from_env
    ENV["YAMINE_MAX_ROUTES"] = "8"
    assert_equal 8, Yamine::Agent.max_routes
  end

  def test_max_routes_zero_disables_cap
    ENV["YAMINE_MAX_ROUTES"] = "0"
    assert_equal 0, Yamine::Agent.max_routes
  end

  def test_max_routes_invalid_falls_back
    ENV["YAMINE_MAX_ROUTES"] = "many"
    assert_equal 32, Yamine::Agent.max_routes
  end

  def test_routes_record_owner
    store = Yamine::RouteStore.new(@dir)
    ENV["YAMINE_AGENT"] = "agent-a"
    store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    entry = store.find("a.localhost")
    assert_equal "agent-a", entry["agent"]
  end

  def test_routes_accept_explicit_agent
    store = Yamine::RouteStore.new(@dir)
    store.add_route("b.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp", agent: "agent-b")
    assert_equal "agent-b", store.find("b.localhost")["agent"]
  end

  def test_old_routes_without_agent_still_valid
    store = Yamine::RouteStore.new(@dir)
    File.write(File.join(@dir, "routes.json"),
      JSON.generate([{ "hostname" => "old.localhost", "target" => "127.0.0.1:4003",
                       "kind" => "tcp", "pid" => 0 }]))
    assert_equal 1, store.load_routes.length
    assert_nil store.find("old.localhost")["agent"]
  end

  def test_conflict_error_names_agent_and_dir
    err = Yamine::RouteConflictError.new("x.localhost", 123,
      existing_agent: "agent-a", existing_dir: "/wt/fix")
    assert_includes err.message, '"agent-a"'
    assert_includes err.message, "/wt/fix"
    assert_includes err.message, "--force"
    assert_equal "agent-a", err.existing_agent
  end

  def test_conflict_error_without_agent_falls_back_to_pid
    err = Yamine::RouteConflictError.new("x.localhost", 123)
    assert_includes err.message, "PID 123"
  end

  def test_quota_error_message_names_fix
    err = Yamine::QuotaExceededError.new("agent-a", 4, 4)
    assert_includes err.message, '"agent-a"'
    assert_includes err.message, "4"
    assert_includes err.message, "yamine stop"
    assert_equal 4, err.limit
  end
end

class AgentQuotaTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_agent = ENV["YAMINE_AGENT"]
    @orig_max = ENV["YAMINE_MAX_ROUTES"]
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    ENV["YAMINE_AGENT"] = @orig_agent if @orig_agent
    ENV.delete("YAMINE_AGENT") unless @orig_agent
    ENV["YAMINE_MAX_ROUTES"] = @orig_max if @orig_max
    FileUtils.remove_entry(@dir)
  end

  def test_quota_enforced_per_agent
    ENV["YAMINE_AGENT"] = "agent-a"
    ENV["YAMINE_MAX_ROUTES"] = "2"
    @store.add_route("a1.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    @store.add_route("a2.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp")
    err = assert_raises(Yamine::QuotaExceededError) do
      @store.add_route("a3.localhost", "127.0.0.1:4003", Process.pid, kind: "tcp")
    end
    assert_equal "agent-a", err.agent
  end

  def test_quota_counts_only_same_agent
    ENV["YAMINE_MAX_ROUTES"] = "1"
    @store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp", agent: "agent-a")
    # agent-b is unaffected by agent-a's usage.
    @store.add_route("b.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp", agent: "agent-b")
    assert @store.find("b.localhost")
  end

  def test_quota_ignores_reregistration_of_same_hostname
    ENV["YAMINE_AGENT"] = "agent-a"
    ENV["YAMINE_MAX_ROUTES"] = "1"
    @store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    # Re-registering the same hostname (restart) must not trip the quota.
    @store.add_route("a.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp", force: true)
    assert_equal "127.0.0.1:4002", @store.find("a.localhost")["target"]
  end

  def test_quota_zero_disables
    ENV["YAMINE_AGENT"] = "agent-a"
    ENV["YAMINE_MAX_ROUTES"] = "0"
    5.times { |i| @store.add_route("a#{i}.localhost", "127.0.0.1:#{4001 + i}", Process.pid, kind: "tcp") }
    assert_equal 5, @store.load_routes.length
  end

  def test_routes_for_scopes_by_agent
    @store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp", agent: "agent-a")
    @store.add_route("b.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp", agent: "agent-b")
    assert_equal ["a.localhost"], @store.routes_for("agent-a").map { |r| r["hostname"] }
  end
end

class AgentPruneScopeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Yamine::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def dead_entry(hostname, agent)
    { "hostname" => hostname, "target" => "127.0.0.1:4001",
      "kind" => "tcp", "pid" => 999_999_999, "agent" => agent }
  end

  def write_raw(routes)
    require "json"
    File.write(File.join(@dir, "routes.json"), JSON.generate(routes))
  end

  def test_prune_all_removes_every_agents_stale
    # Written raw: add_route prunes-on-write, which would clean the
    # first stale entry before the second is added.
    write_raw([dead_entry("a.localhost", "agent-a"), dead_entry("b.localhost", "agent-b")])
    stale = @store.prune_stale
    assert_equal 2, stale.length
    assert_empty @store.load_routes
  end

  def test_prune_agent_scopes_to_one_agent
    write_raw([dead_entry("a.localhost", "agent-a"), dead_entry("b.localhost", "agent-b")])
    stale = @store.prune_stale(agent: "agent-a")
    assert_equal ["a.localhost"], stale.map { |r| r["hostname"] }
    # b survives pruning (still on disk, still dead but not ours to reap).
    assert_equal ["b.localhost"], @store.load_routes_raw.map { |r| r["hostname"] }
  end

  def test_prune_agent_keeps_live_routes
    @store.add_route("live.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp", agent: "agent-a")
    assert_empty @store.prune_stale(agent: "agent-a")
    assert @store.find("live.localhost")
  end
end

class WorktreeOwnershipTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @orig_agent = ENV["YAMINE_AGENT"]
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig
    ENV["YAMINE_AGENT"] = @orig_agent if @orig_agent
    ENV.delete("YAMINE_AGENT") unless @orig_agent
    FileUtils.remove_entry(@dir)
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

  def with_config(dir, service: "myapp")
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "local.yml"),
      "service: #{service}\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
  end

  def test_foreign_live_route_refuses_boot_and_names_owner
    wt_a = Dir.mktmpdir
    with_config(wt_a)
    ENV["YAMINE_AGENT"] = "agent-a"
    store = Yamine::RouteStore.new(@dir)
    # agent-a owns a LIVE route (own pid) from another dir.
    store.add_route("myapp.localhost", "127.0.0.1:4001", Process.pid,
      kind: "tcp", agent: "agent-a",
      spec: { "dir" => wt_a })

    ENV["YAMINE_AGENT"] = "agent-b"
    wt_b = Dir.mktmpdir
    with_config(wt_b)
    code, _out, err = nil, nil, nil
    Dir.chdir(wt_b) do
      code, _out, err = capture do
        Yamine::CLI::BootCommand.run_inferred(Yamine::CLI::Context.new, [])
      end
    end
    assert_equal 1, code
    assert_includes err, "agent-a"
    assert_includes err, wt_a
    assert_includes err, "--force"
  ensure
    FileUtils.remove_entry(wt_a) if wt_a
    FileUtils.remove_entry(wt_b) if wt_b
  end

  def test_same_agent_same_dir_may_restart
    wt = Dir.mktmpdir
    with_config(wt)
    ENV["YAMINE_AGENT"] = "agent-a"
    store = Yamine::RouteStore.new(@dir)
    # Same agent, same dir, live pid: the gate passes (no refusal).
    # Test the gate directly: no proxy, no spawn involved.
    resolved = Dir.chdir(wt) { Yamine::Resolver.resolve(wt) }
    code, _o, _e = capture do
      ctx = Yamine::CLI::Context.new
      ctx.define_singleton_method(:store) { store }
      Yamine::CLI::BootCommand.check_worktree_ownership!(
        ctx, resolved, force: nil)
    end
    assert_equal 0, code
  ensure
    FileUtils.remove_entry(wt) if wt
  end
end

class AgentStopScopeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    @orig_agent = ENV["YAMINE_AGENT"]
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "local.yml"),
      "service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig
    ENV["YAMINE_AGENT"] = @orig_agent if @orig_agent
    ENV.delete("YAMINE_AGENT") unless @orig_agent
    FileUtils.remove_entry(@dir)
  end

  def capture
    out = StringIO.new
    orig = $stdout
    $stdout = out
    result = yield
    [result, out.string]
  ensure
    $stdout = orig
  end

  def test_stop_skips_foreign_live_route_with_exit_4
    store = Yamine::RouteStore.new(@dir)
    ENV["YAMINE_AGENT"] = "agent-b"
    store.add_route("myapp.localhost", "127.0.0.1:4001", Process.pid,
      kind: "tcp", agent: "agent-a")
    ENV["YAMINE_AGENT"] = "agent-b"
    code, out = nil, nil
    Dir.chdir(@dir) do
      code, out = capture { Yamine::CLI::RoutesCommand.stop(Yamine::CLI::Context.new, []) }
    end
    assert_equal 4, code
    assert_includes out, "agent-a"
    assert_includes out, "--force"
    # Foreign route untouched.
    assert store.find("myapp.localhost")
  end

  def test_stop_force_takes_over_and_names_owner
    store = Yamine::RouteStore.new(@dir)
    store.add_route("myapp.localhost", "127.0.0.1:4001", Process.pid,
      kind: "tcp", agent: "agent-a")
    ENV["YAMINE_AGENT"] = "agent-b"
    code, out = nil, nil
    Dir.chdir(@dir) do
      code, out = capture { Yamine::CLI::RoutesCommand.stop(Yamine::CLI::Context.new, ["--force"]) }
    end
    assert_includes out, "agent-a"
    assert_nil store.find("myapp.localhost")
    assert_equal 3, code # backend pid was ours but dead sidecar => gone path
  end

  def test_stop_removes_own_routes
    store = Yamine::RouteStore.new(@dir)
    ENV["YAMINE_AGENT"] = "agent-a"
    store.add_route("myapp.localhost", "127.0.0.1:4001", Process.pid,
      kind: "tcp", agent: "agent-a")
    code, _out = nil, nil
    Dir.chdir(@dir) do
      code, _out = capture { Yamine::CLI::RoutesCommand.stop(Yamine::CLI::Context.new, []) }
    end
    assert_equal 3, code # backend gone (our own pid alive but no sidecar) => gone
    assert_nil store.find("myapp.localhost")
  end
end

class AgentDiscoveryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig
    FileUtils.remove_entry(@dir)
  end

  def capture
    out = StringIO.new
    orig = $stdout
    $stdout = out
    yield
    out.string
  ensure
    $stdout = orig
  end

  def test_registry_lists_all_routes_with_owners
    store = Yamine::RouteStore.new(@dir)
    store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp", agent: "agent-a")
    store.add_route("b.localhost", "127.0.0.1:4002", Process.pid, kind: "tcp", agent: "agent-b")
    out = capture { Yamine::CLI::RoutesCommand.registry(Yamine::CLI::Context.new, []) }
    assert_includes out, "agent-a"
    assert_includes out, "agent-b"
  end

  def test_registry_json_stable_keys
    require "json"
    store = Yamine::RouteStore.new(@dir)
    store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp", agent: "agent-a")
    out = capture { Yamine::CLI::RoutesCommand.registry(Yamine::CLI::Context.new, ["--json"]) }
    parsed = JSON.parse(out)
    entry = parsed["routes"].first
    %w[hostname url agent alive].each { |k| assert entry.key?(k), "missing #{k}" }
  end

  def test_list_shows_owner_and_json_includes_agent
    require "json"
    store = Yamine::RouteStore.new(@dir)
    ENV["YAMINE_AGENT"] = "agent-a"
    store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp")
    out = capture { Yamine::CLI::RoutesCommand.list(Yamine::CLI::Context.new, ["--json"]) }
    assert_includes JSON.parse(out)["routes"].first["agent"], "agent-a"
  ensure
    ENV.delete("YAMINE_AGENT")
  end

  def test_get_all_delegates_to_registry
    store = Yamine::RouteStore.new(@dir)
    store.add_route("a.localhost", "127.0.0.1:4001", Process.pid, kind: "tcp", agent: "agent-a")
    out = capture { Yamine::CLI::RoutesCommand.get(Yamine::CLI::Context.new, ["--all"]) }
    assert_includes out, "a.localhost"
  end
end
