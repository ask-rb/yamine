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

  def test_db_commands_registered
    assert_includes Yamine::CLI::SUBCOMMANDS, "db"
    assert_includes Yamine::CLI::SUBCOMMANDS, "worktree"
  end
end
