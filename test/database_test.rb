# frozen_string_literal: true

require_relative "test_helper"

class DatabaseNamingTest < Minitest::Test
  def setup
    @state = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@state)
  end

  def test_dir_basename_becomes_db_name
    dir = Dir.mktmpdir("myapp-fix")
    # Dir.mktmpdir appends randomness; use a fixed path instead.
    FileUtils.remove_entry(dir)
    dir = File.join(Dir.tmpdir, "myapp-fix")
    FileUtils.mkdir_p(dir)
    name = Yamine::Database.name_for(dir, env: "development")
    assert_equal "myapp_fix_development", name
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_main_checkout_keeps_bare_name
    dir = File.join(Dir.tmpdir, "myapp")
    FileUtils.mkdir_p(dir)
    name = Yamine::Database.name_for(dir, env: "development")
    assert_equal "myapp_development", name
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_branch_plays_no_part
    # Same dir, different "branch" — the name must not change. There is
    # no branch input at all; stability comes from the path.
    dir = File.join(Dir.tmpdir, "myapp-fix")
    FileUtils.mkdir_p(dir)
    first = Yamine::Database.name_for(dir, env: "development")
    second = Yamine::Database.name_for(dir, env: "development")
    assert_equal first, second
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_dots_and_dashes_sanitize
    assert_equal "my_app", Yamine::Database.sanitize("My.App!")
    assert_equal "a", Yamine::Database.sanitize("a")
  end

  def test_overlong_names_truncate_with_hash
    long = "a" * 60
    name = Yamine::Database.truncate("#{long}_development")
    assert_operator name.bytesize, :<=, 63
    assert_match(/_[0-9a-f]{6}\z/, name)
    # Distinct long names stay distinct.
    other = Yamine::Database.truncate("#{"b" * 60}_development")
    refute_equal name, other
  end

  def test_collision_gets_hash_suffix
    dir_a = File.join(Dir.tmpdir, "myapp-fix")
    dir_b = File.join(Dir.tmpdir, "myapp_fix")
    FileUtils.mkdir_p(dir_a)
    FileUtils.mkdir_p(dir_b)
    first = Yamine::Database.name_for(dir_a, env: "development", state_dir: @state)
    assert_equal "myapp_fix_development", first
    second = Yamine::Database.name_for(dir_b, env: "development", state_dir: @state)
    refute_equal first, second
    assert_match(/\Amyapp_fix_[0-9a-f]{6}_development\z/, second)
  ensure
    FileUtils.remove_entry(dir_a) if dir_a
    FileUtils.remove_entry(dir_b) if dir_b
  end

  def test_same_dir_reclaims_own_name
    dir = File.join(Dir.tmpdir, "myapp-fix")
    FileUtils.mkdir_p(dir)
    first = Yamine::Database.name_for(dir, env: "development", state_dir: @state)
    second = Yamine::Database.name_for(dir, env: "development", state_dir: @state)
    assert_equal first, second
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_orphaned_lists_gone_worktrees
    gone = File.join(Dir.tmpdir, "gone-wt-xyz")
    Yamine::Database.save_map(@state, { "gone_development" => { "dir" => gone } })
    orphaned = Yamine::Database.orphaned(@state)
    assert_equal ["gone_development"], orphaned.keys
  end
end

class DatabaseAdapterTest < Minitest::Test
  def test_postgres_schemes
    assert_equal :postgres, Yamine::Database.adapter_for("postgres://u@h/db")
    assert_equal :postgres, Yamine::Database.adapter_for("postgresql://u@h/db")
  end

  def test_mysql_schemes
    assert_equal :mysql, Yamine::Database.adapter_for("mysql2://u@h/db")
    assert_equal :mysql, Yamine::Database.adapter_for("mysql://u@h/db")
  end

  def test_sqlite_left_alone
    assert_equal :sqlite, Yamine::Database.adapter_for("sqlite3:db/dev.sqlite3")
    assert_equal :sqlite, Yamine::Database.adapter_for(nil)
    assert_equal :sqlite, Yamine::Database.adapter_for("")
    assert_nil Yamine::Database.url_for("x", nil)
    assert_nil Yamine::Database.url_for("x", "sqlite3:db/dev.sqlite3")
  end

  def test_url_for_replaces_database_segment
    url = Yamine::Database.url_for("myapp_fix_development",
      "postgres://u:pw@127.0.0.1:5432/myapp_development")
    assert_equal "postgres://u:pw@127.0.0.1:5432/myapp_fix_development", url
  end

  def test_url_for_preserves_host_port_user
    url = Yamine::Database.url_for("shop_test",
      "mysql2://root@db.internal:3307/shop_development")
    assert_includes url, "db.internal:3307"
    assert_includes url, "/shop_test"
  end

  def test_ensure_exists_false_without_binaries
    # No server here; must return false, never raise.
    refute Yamine::Database.ensure_exists("nope",
      "postgres://127.0.0.1:1/nope")
  end
end

class DatabaseBootWiringTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig
    FileUtils.remove_entry(@dir)
  end

  def test_child_env_injects_database_url
    store = Yamine::RouteStore.new(@dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, @dir, url: "https://x.localhost",
      port: 4001, database_url: "postgres://127.0.0.1/db_fix")
    assert_equal "postgres://127.0.0.1/db_fix", env["DATABASE_URL"]
  end

  def test_child_env_without_database_url_sets_nothing
    store = Yamine::RouteStore.new(@dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, @dir, url: "https://x.localhost", port: 4001)
    refute env.key?("DATABASE_URL")
  end

  def test_child_env_injects_the_whole_database_env
    store = Yamine::RouteStore.new(@dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, @dir, url: "https://x.localhost", port: 4001,
      database_env: { "DATABASE_URL" => "postgres://u@h/a_fix",
        "CACHE_DATABASE_URL" => "postgres://u@h/a_cache_fix" },
      extra_env: { "DATABASE_URL" => "postgres://stray/injected", "API" => "x" })
    assert_equal "postgres://u@h/a_fix", env["DATABASE_URL"],
      "yamine's own keys win over the config's env, including for DATABASE_URL"
    assert_equal "postgres://u@h/a_cache_fix", env["CACHE_DATABASE_URL"]
    assert_equal "x", env["API"]
  end

  def test_child_env_legacy_database_url_still_works
    store = Yamine::RouteStore.new(@dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, @dir, url: "https://x.localhost", port: 4001,
      database_env: { "DATABASE_URL" => "postgres://u@h/both" },
      database_url: "postgres://u@h/legacy")
    assert_equal "postgres://u@h/both", env["DATABASE_URL"],
      "the whole-set env takes precedence over the single-url argument"
  end

  def test_db_commands_registered
    assert_includes Yamine::CLI::SUBCOMMANDS, "db"
    assert_includes Yamine::CLI::SUBCOMMANDS, "worktree"
  end
end

class DatabaseWarningTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @state = Dir.mktmpdir
    @orig_dir = Dir.pwd
    @orig_env = ENV["DATABASE_URL"]
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @state
    Dir.chdir(@dir)
    FileUtils.mkdir_p(File.join(@dir, "config"))
  end

  def teardown
    Dir.chdir(@orig_dir)
    ENV["DATABASE_URL"] = @orig_env
    ENV["YAMINE_STATE_DIR"] = @orig_state
    FileUtils.remove_entry(@dir) rescue nil
    FileUtils.remove_entry(@state) rescue nil
  end

  def write_config(content)
    File.write(File.join(@dir, "config", "local.yml"), content)
  end

  def test_no_warning_when_no_database_yml_and_no_pg_gem
    # Pure sqlite/static app — silence is correct.
    write_config("service: myapp\nprocesses:\n  web:\n    cmd: bin/rails s\n    proxy: true\n")
    ENV.delete("DATABASE_URL")
    resolved = Yamine::Resolver.resolve(@dir)
    out, err = capture_io { Yamine::CLI::BootCommand.send(:warn_missing_template, resolved) }
    assert_empty err
  end

  def test_warns_when_database_yml_mentions_postgres
    write_config("service: myapp\nprocesses:\n  web:\n    cmd: bin/rails s\n    proxy: true\n")
    File.write(File.join(@dir, "config", "database.yml"), "development:\n  adapter: postgresql\n  database: myapp_development\n")
    ENV.delete("DATABASE_URL")
    resolved = Yamine::Resolver.resolve(@dir)
    _out, err = capture_io { Yamine::CLI::BootCommand.send(:warn_missing_template, resolved) }
    assert_match(/WARNING.*database-backed/, err)
    assert_match(/DATABASE_URL/, err)
  end

  def test_warns_when_gemfile_has_pg
    write_config("service: myapp\nprocesses:\n  web:\n    cmd: bin/rails s\n    proxy: true\n")
    File.write(File.join(@dir, "Gemfile"), "source \"https://rubygems.org\"\ngem \"pg\"\n")
    ENV.delete("DATABASE_URL")
    resolved = Yamine::Resolver.resolve(@dir)
    _out, err = capture_io { Yamine::CLI::BootCommand.send(:warn_missing_template, resolved) }
    assert_match(/WARNING/, err)
  end

  def test_main_checkout_rails_without_template_is_silent
    # The main checkout's databases ARE the app's own databases —
    # nothing to isolate, so the old false-alarm warning must not
    # fire. A .git DIRECTORY marks main (worktrees have a .git file).
    write_config("service: myapp\nprocesses:\n  web:\n    cmd: bin/rails s\n    proxy: true\n")
    File.write(File.join(@dir, "config", "database.yml"), "development:\n  adapter: postgresql\n")
    File.write(File.join(@dir, "config", "application.rb"), "module Myapp; class Application; end; end\n")
    FileUtils.mkdir_p(File.join(@dir, ".git"))
    ENV.delete("DATABASE_URL")
    resolved = Yamine::Resolver.resolve(@dir)
    ctx = Struct.new(:store).new(Struct.new(:dir).new(@state))
    _out, err = capture_io do
      created, env = Yamine::CLI::BootCommand.setup_database(ctx, resolved, "myapp_development")
      refute created
      assert_nil env
    end
    refute_match(/WARNING/, err, "main checkout must not warn about missing templates")
  end

  def test_no_warning_when_template_present_in_env_clear
    write_config("service: myapp\nenv:\n  clear:\n    DATABASE_URL: postgres://u@/myapp_development\nprocesses:\n  web:\n    cmd: bin/rails s\n    proxy: true\n")
    File.write(File.join(@dir, "config", "database.yml"), "development:\n  adapter: postgresql\n")
    resolved = Yamine::Resolver.resolve(@dir)
    assert_equal "postgres://u@/myapp_development", Yamine::CLI::BootCommand.send(:database_template_from_config, resolved)
  end

  def test_db_false_opt_out_suppresses_warning
    write_config("service: myapp\ndb: false\nprocesses:\n  web:\n    cmd: bin/rails s\n    proxy: true\n")
    File.write(File.join(@dir, "config", "database.yml"), "development:\n  adapter: postgresql\n")
    ENV.delete("DATABASE_URL")
    resolved = Yamine::Resolver.resolve(@dir)
    assert_equal false, resolved.db
    _out, err = capture_io { Yamine::CLI::BootCommand.send(:setup_database, Yamine::CLI::Context.new, resolved, "myapp_development") }
    assert_empty err
  end

  def test_top_level_db_false_validates
    File.write(File.join(@dir, "config", "local.yml"), "service: myapp\ndb: false\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n")
    config = Yamine::Config.load(@dir)
    assert_equal false, config.data["db"]
  end

  def test_db_true_rejected
    File.write(File.join(@dir, "config", "local.yml"), "service: myapp\ndb: true\nprocesses:\n  web:\n    cmd: foo\n    proxy: true\n")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  def test_database_exists_splits_from_ensure_exists
    # exists? returns false without a server; ensure_exists also false — but the split means setup_database knows provenance.
    refute Yamine::Database.exists?("nope", "postgres://127.0.0.1:1/nope")
    refute Yamine::Database.ensure_exists("nope", "postgres://127.0.0.1:1/nope")
  end

  def test_wait_flag_parsed
    ctx = Yamine::CLI::Context.new
    opts = ctx.parse_flags(["--wait", "--json"], %i[wait json])
    assert opts[:wait]
    assert opts[:json]
  end

  def test_wait_flag_unknown_rejected
    ctx = Yamine::CLI::Context.new
    assert_raises(Yamine::Error) { ctx.parse_flags(["--bogus"], %i[wait json]) }
  end
end

class DatabaseDropTest < Minitest::Test
  OK = Struct.new(:success?).new(true)
  FAIL = Struct.new(:success?).new(false)

  def test_missing_when_server_reachable_and_db_absent
    Yamine::Database.stubs(:pg_state).returns([true, false])
    # No dropdb call should even happen.
    Open3.expects(:capture2).never
    assert_equal :missing, Yamine::Database.drop("gone", "postgres://u@h/gone")
  end

  def test_dropped_when_dropdb_succeeds
    Yamine::Database.stubs(:pg_state).returns([true, true])
    Open3.stubs(:capture2).returns(["", OK])
    assert_equal :dropped, Yamine::Database.drop("x", "postgres://u@h/x")
  end

  def test_failed_when_dropdb_refused_and_db_still_there
    Yamine::Database.stubs(:pg_state).returns([true, true], [true, true])
    Open3.stubs(:capture2).returns(["dropdb: database removal failed", FAIL])
    assert_equal :failed, Yamine::Database.drop("x", "postgres://u@h/x")
  end

  def test_failed_when_server_unreachable
    Yamine::Database.stubs(:pg_state).returns([false, false])
    Open3.expects(:capture2).never
    assert_equal :failed, Yamine::Database.drop("x", "postgres://127.0.0.1:1/x"),
      "an unreachable server must not be reported as 'did not exist'"
  end

  def test_mysql_missing_and_dropped
    Yamine::Database.stubs(:mysql_state).returns([true, false])
    assert_equal :missing, Yamine::Database.drop("gone", "mysql2://root@h/gone")

    Yamine::Database.stubs(:mysql_state).returns([true, true])
    Open3.stubs(:capture2).returns(["", OK])
    assert_equal :dropped, Yamine::Database.drop("x", "mysql2://root@h/x")
  end

  def test_unknown_adapter_fails
    assert_equal :failed, Yamine::Database.drop("x", nil)
  end
end

class WorktreeCleanTest < Minitest::Test
  def setup
    @orig_dir = Dir.pwd
    @dir = Dir.mktmpdir
    @state = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    @orig_url = ENV["DATABASE_URL"]
    ENV["YAMINE_STATE_DIR"] = @state
    ENV["DATABASE_URL"] = "postgres://u@127.0.0.1:5432/template"
    Dir.chdir(@dir)
  end

  def teardown
    Dir.chdir(@orig_dir)
    ENV["YAMINE_STATE_DIR"] = @orig_state
    ENV["DATABASE_URL"] = @orig_url
    FileUtils.remove_entry(@dir) rescue nil
    FileUtils.remove_entry(@state) rescue nil
  end

  def claim(name, gone_dir)
    map = Yamine::Database.load_map(@state)
    map[name] = { "dir" => File.join(@dir, "nowhere", gone_dir) }
    Yamine::Database.save_map(@state, map)
  end

  def test_clean_reports_each_outcome_and_keeps_failed_claims
    claim("wt_a_development", "a")
    claim("wt_a_test", "a")
    claim("wt_b_development", "b")
    Yamine::Database.stubs(:drop).returns(:dropped, :missing, :failed)

    out, err = capture_io do
      begin
        Yamine::CLI::WorktreeCommand.run(Yamine::CLI::Context.new, ["clean"])
      rescue SystemExit
        nil
      end
    end
    assert_includes out, "dropped wt_a_development"
    assert_includes out, "wt_a_test did not exist — nothing to drop"
    assert_includes err, "could not drop wt_b_development"
    assert_match(/Cleaned 3 item\(s\), 1 failed/, out)

    map = Yamine::Database.load_map(@state)
    refute map.key?("wt_a_development"), "handled claims are forgotten"
    refute map.key?("wt_a_test"), "missing dbs are forgotten too (nothing to retry)"
    assert map.key?("wt_b_development"), "a failed drop keeps its claim for a retry"
  end

  def test_clean_empty_state
    out, = capture_io do
      Yamine::CLI::WorktreeCommand.run(Yamine::CLI::Context.new, ["clean"])
    end
    assert_includes out, "Nothing to clean."
  end

  def test_db_drop_reports_missing_not_error
    claim("ghost_development", "ghost")
    Yamine::Database.stubs(:drop).returns(:missing)
    out, = capture_io do
      Yamine::CLI::SystemCommand.db_drop(Yamine::CLI::Context.new, ["ghost_development"])
    end
    assert_includes out, "did not exist — nothing to drop"
    refute Yamine::Database.load_map(@state).key?("ghost_development")
  end
end

class MultiDatabaseNamingTest < Minitest::Test
  def setup
    @state = Dir.mktmpdir
    @dir = File.join(Dir.tmpdir, "myapp-fix")
    FileUtils.mkdir_p(@dir)
  end

  def teardown
    FileUtils.remove_entry(@state)
    FileUtils.remove_entry(@dir)
  end

  def test_suffix_strips_env
    assert_equal "myapp_fix", Yamine::Database.suffix_for("myapp_fix_development", "development")
  end

  def test_suffix_without_env_match_keeps_whole_claim
    # A dir literally named "feature_development" must not lose part
    # of itself — only an exact "_<env>" tail is stripped.
    assert_equal "feature_development_staging",
      Yamine::Database.suffix_for("feature_development_staging", "development")
  end

  def test_fit_suffix_keeps_short_suffix
    assert_equal "fix", Yamine::Database.fit_suffix("fix", @dir, ["app_development"])
  end

  def test_fit_suffix_shortens_to_longest_base_budget
    base = "b" * 50
    fitted = Yamine::Database.fit_suffix("a" * 30, @dir, [base])
    refute_nil fitted
    assert_operator "#{base}_#{fitted}".bytesize, :<=, 63
    assert_match(/_[0-9a-f]{6}\z/, fitted, "a shortened suffix carries the dir hash")
    # Deterministic: same dir + same budget = same suffix (the marker
    # file and the claim must agree across processes).
    assert_equal fitted, Yamine::Database.fit_suffix("a" * 30, @dir, [base])
  end

  def test_fit_suffix_gives_up_when_base_leaves_no_room
    assert_nil Yamine::Database.fit_suffix("suffix", @dir, ["b" * 60])
  end

  def test_multiname_concatenates
    assert_equal "app_development_fix",
      Yamine::Database.multiname("app_development", "fix")
  end

  def test_multiname_refuses_over_cap_rather_than_truncating
    # Truncation here would diverge from the marker file's plain
    # concatenation inside the app — the disagreement this all exists
    # to prevent. Fail loudly instead.
    assert_raises(ArgumentError) do
      Yamine::Database.multiname("b" * 60, "suffix")
    end
  end

  def test_marker_roundtrip_and_git_exclude
    out, status = Open3.capture2("git", "init", "-q", @dir)
    raise "git init failed: #{out}" unless status.success?

    Yamine::Database.write_marker(@dir, "myapp_fix")
    assert_equal "myapp_fix", Yamine::Database.read_marker(@dir)
    refute Yamine::Database.read_marker(File.join(@dir, "nope"))

    Yamine::Database.exclude_marker(@dir)
    Yamine::Database.exclude_marker(@dir) # idempotent
    exclude = File.join(@dir, ".git", "info", "exclude")
    assert_includes File.readlines(exclude).map(&:strip), Yamine::Database::MARKER_FILE
  end

  def test_state_file_is_private
    Yamine::Database.save_map(@state, { "k" => { "dir" => @dir } })
    mode = File.stat(File.join(@state, Yamine::Database::STATE_FILE)).mode & 0o777
    assert_equal 0o600, mode, "claims carry database URLs — the file must not be world-readable"
  end

  def test_reclaim_preserves_multi_fields
    # Boot re-claims on every run; a fresh hash would erase the set
    # and orphan every database at the next drop.
    Yamine::Database.save_map(@state, {
      "myapp_fix_development" => {
        "dir" => @dir, "claimed_at" => "2026-01-01T00:00:00Z",
        "suffix" => "myapp_fix",
        "names" => { "primary" => "app_development_myapp_fix" },
        "bases" => { "primary" => "postgres://u@h/app_development" }
      }
    })
    Yamine::Database.name_for(@dir, env: "development", state_dir: @state)
    info = Yamine::Database.load_map(@state)["myapp_fix_development"]
    assert_equal "myapp_fix", info["suffix"]
    assert_equal({ "primary" => "app_development_myapp_fix" }, info["names"])
    assert_equal({ "primary" => "postgres://u@h/app_development" }, info["bases"])
  end

  def test_multi_claim_and_pairs
    state = @state
    Yamine::Database.save_map(state, {
      "multi" => {
        "dir" => @dir, "names" => { "primary" => "a", "cache" => "b" },
        "bases" => { "primary" => "postgres://u@h/a", "cache" => "postgres://u@h/b" }
      },
      "single" => { "dir" => @dir }
    })

    claim = Yamine::Database.multi_claim(state, "multi")
    assert_equal({ "primary" => "a", "cache" => "b" }, claim["names"])
    assert_nil Yamine::Database.multi_claim(state, "single")
    assert_nil Yamine::Database.multi_claim(state, "absent")

    pairs = Yamine::Database.claim_pairs(claim).to_h
    assert_equal "postgres://u@h/a", pairs["a"]
    assert_equal "postgres://u@h/b", pairs["b"]
    assert_nil Yamine::Database.claim_pairs({ "dir" => @dir })
    assert_nil Yamine::Database.claim_pairs(nil)
  end

  def test_claim_pairs_base_lag_falls_back_to_first
    claim = { "names" => { "primary" => "a", "cache" => "b" },
              "bases" => { "primary" => "postgres://u@h/a" } }
    pairs = Yamine::Database.claim_pairs(claim).to_h
    assert_equal "postgres://u@h/a", pairs["b"], "all of an app's databases share one server"
  end

  def test_pg_env_omits_host_for_socket_urls
    env = Yamine::Database.pg_env(URI.parse("postgres:///mydb"))
    refute env.key?("PGHOST"), "socket URLs must not be forced onto 127.0.0.1"
    env = Yamine::Database.pg_env(URI.parse("postgres://dbhost/mydb"))
    assert_equal "dbhost", env["PGHOST"]
  end
end

class DbEnvForTest < Minitest::Test
  def test_primary_and_per_config_urls
    env = Yamine::CLI::BootCommand.db_env_for(
      { "primary" => "app_dev_fix", "cache" => "app_dev_cache_fix" },
      { "primary" => "postgres://u@h/app_dev", "cache" => "postgres://u@h/app_dev_cache" }
    )
    assert_equal "postgres://u@h/app_dev_fix", env["DATABASE_URL"]
    assert_equal "postgres://u@h/app_dev_fix", env["PRIMARY_DATABASE_URL"]
    assert_equal "postgres://u@h/app_dev_cache_fix", env["CACHE_DATABASE_URL"]
    refute env.key?("QUEUE_DATABASE_URL")
  end

  def test_missing_base_is_skipped_not_invented
    env = Yamine::CLI::BootCommand.db_env_for({ "primary" => "x" }, {})
    assert_empty env
  end
end
